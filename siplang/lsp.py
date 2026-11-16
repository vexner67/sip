"""sip lsp: языковой сервер (Language Server Protocol) через stdin/stdout.

Умеет: ошибки при наборе (весь компилятор до проверки типов, с несохранёнными
файлами редактора), тип под курсором, переход к определению, дополнение после
`.` и по словам, форматирование (sip fmt) и список определений файла.

Ошибка компилятора одна (первая), как и в sip check. Пока файл не разбирается,
подсказки берутся из последнего удачного разбора.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import fields as dc_fields
from urllib.parse import unquote, urlparse
from urllib.request import pathname2url

from .errors import SipError
from .lexer import KEYWORDS
from .nodes import (Attr, Call, FnDef, For, Interface, Module, Name, Node, Record, SelfAttr, SumType, TName,
                    Variant)
from .types import (DictT, FnT, Generic, ListT, OptT, RecordT, SetT, SumT, prune, show)
from . import types as T_

WORD = re.compile(r"[A-Za-z_]\w*")


def uri_to_path(uri: str) -> str:
    return os.path.abspath(unquote(urlparse(uri).path))


def path_to_uri(path: str) -> str:
    return "file://" + pathname2url(os.path.abspath(path))


def word_at(line: str, col: int):
    """Слово под курсором (col с 0): (слово, начало) или (None, col)."""
    for m in WORD.finditer(line):
        if m.start() <= col <= m.end():
            return m.group(), m.start()
    return None, col


def walk(node, out: list):
    if isinstance(node, Node):
        out.append(node)
        for f in dc_fields(node):
            walk(getattr(node, f.name), out)
    elif isinstance(node, (list, tuple)):
        for x in node:
            walk(x, out)


def display(name: str) -> str:
    """bank__NotEnough -> NotEnough: имена модулей переименованы при загрузке."""
    return name.rsplit("__", 1)[-1] if "__" in name else name


def matches(name: str, word: str) -> bool:
    return name == word or name.endswith("__" + word)


class Analysis:
    """Результат удачной проверки одного файла (корня программы)."""

    def __init__(self, path: str, text: str, prog, srcmap, module: Module):
        self.path = path
        self.text = text
        self.prog = prog
        self.srcmap = srcmap
        self.loader = getattr(srcmap, "loader", None)
        self.nodes: list = []
        walk(module.body, self.nodes)
        self.by_line: dict = {}
        for n in self.nodes:
            if n.line:
                self.by_line.setdefault(n.line, []).append(n)
        self.defs: dict = {}      # имя (переименованное) -> строка программы
        self.members: dict = {}   # (имя типа, поле или метод) -> строка программы
        for n in self.nodes:
            if isinstance(n, (FnDef, Record, SumType, Interface, Variant)) and not getattr(n, "is_method", False):
                self.defs.setdefault(n.name, n.line)
            if isinstance(n, (Record, SumType)):
                for m in n.methods:
                    self.members[(n.name, m.name)] = m.line
            if isinstance(n, Record):
                for p in n.fields:
                    self.members[(n.name, p.name)] = getattr(p, "line", 0) or n.line

    # ---------- описания ----------

    def fn_sig(self, fi) -> str:
        ps = []
        for name, t, d in fi.params:
            ps.append(f"{name} {show(t)}" + (" = ..." if d is not None else ""))
        ret = prune(fi.ret)
        head = "async fn" if getattr(fi.node, "is_async", False) else "fn"
        r = "" if ret is T_.UNIT else " " + show(ret)
        return f"{head} {display(getattr(fi.node, 'display', fi.name))}({', '.join(ps)}){r}"

    def type_sig(self, t) -> str:
        t = prune(t)
        name = display(getattr(t, "display", t.name))
        if isinstance(t, RecordT):
            fs = ", ".join(f"{f} {show(ft)}" for f, ft in t.fields.items())
            return f"type {name}({fs})"
        if isinstance(t, SumT):
            vs = []
            for v, fs in t.variants.items():
                vd = display(getattr(t, "vdisplay", {}).get(v, v))
                vs.append(vd + (f"({', '.join(f'{f} {show(ft)}' for f, ft in fs)})" if fs else ""))
            return f"type {name} = {' | '.join(vs)}"
        return show(t)

    def named(self, word: str) -> str | None:
        """Описание функции или типа верхнего уровня по имени."""
        p = self.prog
        for table in (p.fns,):
            for k, fi in table.items():
                if matches(k, word) and not k.startswith("test__"):
                    return self.fn_sig(fi)
        for table in (p.records, p.sums):
            for k, t in table.items():
                if matches(k, word):
                    return self.type_sig(t)
        for k, st in p.variants.items():
            if matches(k, word):
                return self.type_sig(st)
        for k, it in p.ifaces.items():
            if matches(k, word):
                ms = "; ".join(f"fn {m}" for m in getattr(it, "methods", {}))
                return f"interface {display(k)}" + (f": {ms}" if ms else "")
        return None

    def method_of(self, t, name: str):
        t = prune(t)
        if isinstance(t, OptT):
            t = prune(t.inner)
        base = t.base if isinstance(t, Generic) and getattr(t, "base", None) is not None else t
        methods = getattr(base, "methods", None) or {}
        return methods.get(name), base

    # ---------- поиск под курсором ----------

    def nodes_at(self, line: int, word: str) -> list:
        out = []
        for n in self.by_line.get(line, []):
            if isinstance(n, Name) and matches(n.id, word):
                out.append(n)
            elif isinstance(n, (Attr, SelfAttr)) and n.name == word:
                out.append(n)
            elif isinstance(n, TName) and matches(n.name.split(".")[-1], word):
                out.append(n)
        return out

    def hover(self, line: int, word: str) -> str | None:
        for n in self.nodes_at(line, word):
            if isinstance(n, Name):
                fi = self.prog.fns.get(n.id)
                if fi is not None:
                    return self.fn_sig(fi)
                desc = self.named(word) if n.id in self.defs else None
                if desc:
                    return desc
                t = getattr(n, "ty", None)
                if t is None and getattr(n, "var", None) is not None:
                    t = n.var.ty
                if t is not None:
                    return f"{word} {show(prune(t))}"
            if isinstance(n, (Attr, SelfAttr)):
                obj_t = getattr(n.obj, "ty", None) if isinstance(n, Attr) else None
                if obj_t is not None:
                    fi, _ = self.method_of(obj_t, word)
                    if fi is not None:
                        return self.fn_sig(fi)
                t = getattr(n, "ty", None)
                if t is not None:
                    return f"{word} {show(prune(t))}"
            if isinstance(n, TName):
                desc = self.named(word)
                if desc:
                    return desc
        return self.named(word)

    def definition(self, line: int, word: str):
        """-> (строка программы) или None."""
        for n in self.nodes_at(line, word):
            if isinstance(n, Name):
                if n.id in self.defs:
                    return self.defs[n.id]
                var = getattr(n, "var", None)
                if var is not None:
                    if var.kind == "param":
                        best = None
                        for f in self.nodes:
                            if isinstance(f, FnDef) and f.line <= line and any(p.name == word for p in f.params):
                                if best is None or f.line > best:
                                    best = f.line
                        if best:
                            return best
                    first = min((m.line for m in self.nodes
                                 if isinstance(m, Name) and getattr(m, "var", None) is var and m.line), default=None)
                    if first:
                        return first
            if isinstance(n, (Attr, SelfAttr)):
                if isinstance(n, Attr) and getattr(n.obj, "ty", None) is not None:
                    _, base = self.method_of(n.obj.ty, word)
                    key = (getattr(base, "name", None), word)
                    if key in self.members:
                        return self.members[key]
                hits = [ln for (tn, m), ln in self.members.items() if m == word]
                if len(hits) == 1:
                    return hits[0]
            if isinstance(n, TName):
                for k, ln in self.defs.items():
                    if matches(k, word):
                        return ln
        for k, ln in self.defs.items():
            if matches(k, word):
                return ln
        return None

    def fn_at(self, line: int):
        """Функция корневого файла, внутри которой строка (ближайшая выше)."""
        best = None
        for fi in list(self.prog.fns.values()) + self.prog.methods:
            ln = fi.node.line
            if 0 < ln <= line < SourceBand and (best is None or ln > best.node.line):
                best = fi
        return best

    def members_of(self, t) -> list:
        from .checker import DICT_METHODS, LIST_METHODS, SET_METHODS, STR_METHODS
        t = prune(t)
        if isinstance(t, OptT):
            t = prune(t.inner)
        if t is T_.STR:
            return [(m, 2) for m in STR_METHODS]
        if isinstance(t, ListT):
            return [(m, 2) for m in LIST_METHODS]
        if isinstance(t, DictT):
            return [(m, 2) for m in DICT_METHODS]
        if isinstance(t, SetT):
            return [(m, 2) for m in SET_METHODS]
        out = []
        if isinstance(t, RecordT):
            out += [(f, 5) for f in t.fields if not f.startswith("_")]
        base = t.base if isinstance(t, Generic) and getattr(t, "base", None) is not None else t
        out += [(m, 2) for m in (getattr(base, "methods", None) or {})]
        return out

    def complete(self, line_text: str, line: int) -> list:
        """[(текст, вид LSP)]: 2 метод, 3 функция, 5 поле, 6 переменная, 7 тип, 9 модуль, 14 слово."""
        from .modules import NATIVE
        m = re.search(r"([A-Za-z_]\w*)\.(\w*)$", line_text)
        if m:
            w = m.group(1)
            ld = self.loader
            if ld is not None and w in ld.root_mods:
                p = self.prog
                types = set(p.records) | set(p.sums) | set(p.variants) | set(p.ifaces)
                return [(k, 7 if full in types else 6 if full in p.globals else 3)
                        for k, full in ld.root_mods[w].items() if not k.startswith("_")]
            if ld is not None and w in ld.root_natives:
                return [(k, 3) for k in NATIVE[ld.root_natives[w]]]
            if w in NATIVE:
                return [(k, 3) for k in NATIVE[w]]
            best = None
            for ln in range(line, 0, -1):
                for n in self.by_line.get(ln, []):
                    if isinstance(n, Name) and n.id == w and getattr(n, "ty", None) is not None:
                        best = n
                        break
                if best is not None:
                    break
            return self.members_of(best.ty) if best is not None else []
        if re.search(r"(^|[^\w.)\]])\.(\w*)$", line_text):  # .field внутри метода
            fi = self.fn_at(line)
            if fi is not None and fi.owner is not None:
                own = self.members_of(fi.owner)
                if isinstance(prune(fi.owner), RecordT):
                    own += [(f, 5) for f in prune(fi.owner).fields if f.startswith("_")]
                return own
            return []
        out = [(k, 14) for k in sorted(KEYWORDS | {"type", "interface", "print", "test"})]
        out += [(b, 3) for b in BUILTINS]
        p = self.prog
        out += [(display(k), 3) for k in p.fns if not k.startswith("test__") and k != "main"]
        out += [(display(k), 7) for k in list(p.records) + list(p.sums) + list(p.ifaces)]
        out += [(display(k), 7) for k in p.variants]
        out += [(display(k), 6) for k in p.globals]
        if self.loader is not None:
            out += [(k, 9) for k in list(self.loader.root_mods) + list(self.loader.root_natives)]
        fi = self.fn_at(line)
        if fi is not None:
            out += [(name, 6) for name, _, _ in fi.params]
            out += [(k, 6) for k in fi.locals if k != "self"]
        seen, res = set(), []
        for k, kind in out:
            if k not in seen:
                seen.add(k)
                res.append((k, kind))
        return res


SourceBand = 1 << 20  # строки корневого файла меньше этого числа (см. SourceMap.BAND)


def _builtins() -> list:
    from .cgen import CGen
    return sorted({n[2:] for n in dir(CGen) if n.startswith("b_") and "_" not in n[2:]})


BUILTINS: list = []


class Server:
    def __init__(self, inp=None, out=None):
        self.inp = inp or sys.stdin.buffer
        self.out = out or sys.stdout.buffer
        self.docs: dict = {}        # путь -> текст
        self.good: dict = {}        # путь -> Analysis
        self.flagged: dict = {}     # путь открытого файла -> пути, где показаны его ошибки
        self.running = True

    # ---------- протокол ----------

    def read(self):
        length = None
        while True:
            line = self.inp.readline()
            if not line:
                return None
            line = line.strip()
            if not line:
                break
            k, _, v = line.decode().partition(":")
            if k.lower() == "content-length":
                length = int(v)
        if length is None:
            return None
        return json.loads(self.inp.read(length))

    def send(self, msg: dict):
        data = json.dumps(msg, ensure_ascii=False).encode()
        self.out.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
        self.out.flush()

    def notify(self, method: str, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def serve(self) -> int:
        global BUILTINS
        BUILTINS = _builtins()
        while self.running:
            msg = self.read()
            if msg is None:
                break
            method, mid = msg.get("method"), msg.get("id")
            try:
                result = self.dispatch(method, msg.get("params") or {})
                if mid is not None and method is not None:
                    self.send({"jsonrpc": "2.0", "id": mid, "result": result})
            except Exception as e:  # ошибка сервера не должна ронять редактор
                print(f"sip lsp: {method}: {type(e).__name__}: {e}", file=sys.stderr)
                if mid is not None:
                    self.send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}})
        return 0

    def dispatch(self, method, params):
        if method == "initialize":
            return {"capabilities": {
                "textDocumentSync": 1, "hoverProvider": True, "definitionProvider": True,
                "completionProvider": {"triggerCharacters": ["."]},
                "documentFormattingProvider": True, "documentSymbolProvider": True},
                "serverInfo": {"name": "sip"}}
        if method == "shutdown":
            return None
        if method == "exit":
            self.running = False
            return None
        td = params.get("textDocument") or {}
        path = uri_to_path(td["uri"]) if "uri" in td else None
        if method == "textDocument/didOpen":
            self.docs[path] = td.get("text", "")
            self.analyze(path)
        elif method == "textDocument/didChange":
            changes = params.get("contentChanges") or []
            if changes:
                self.docs[path] = changes[-1]["text"]
            self.analyze(path)
        elif method == "textDocument/didSave":
            if params.get("text") is not None:
                self.docs[path] = params["text"]
            self.analyze(path)
        elif method == "textDocument/didClose":
            self.docs.pop(path, None)
            for p in self.flagged.pop(path, set()):
                self.publish(p, [])
        elif method == "textDocument/hover":
            return self.hover(path, params["position"])
        elif method == "textDocument/definition":
            return self.definition(path, params["position"])
        elif method == "textDocument/completion":
            return self.completion(path, params["position"])
        elif method == "textDocument/formatting":
            return self.formatting(path)
        elif method == "textDocument/documentSymbol":
            return self.symbols(path)
        return None

    # ---------- проверка ----------

    def publish(self, path: str, diags: list):
        self.notify("textDocument/publishDiagnostics", {"uri": path_to_uri(path), "diagnostics": diags})

    def analyze(self, path: str):
        from .checker import check_program
        from .modules import load_program
        text = self.docs.get(path, "")
        diags: dict = {}
        try:
            module, srcmap = load_program(path, text, tests=True, overlay=dict(self.docs))
            prog = check_program(module, path, srcmap)
            self.good[path] = Analysis(path, text, prog, srcmap, module)
        except SipError as e:
            where = os.path.abspath(e.file) if e.file and e.file not in ("<input>", "sip") else path
            line = max(e.line - 1, 0)
            col = max(e.col - 1, 0)
            src_lines = (self.docs.get(where) if where in self.docs else _read(where)).splitlines()
            end = len(src_lines[line]) if line < len(src_lines) else col + 1
            if e.col:
                w, s = word_at(src_lines[line] if line < len(src_lines) else "", col)
                if w and s == col:
                    end = col + len(w)
            else:
                ind = src_lines[line] if line < len(src_lines) else ""
                col = len(ind) - len(ind.lstrip())
            msg = e.msg
            if where != path:
                msg = f"{msg} (while checking {os.path.basename(path)})"
            diags.setdefault(where, []).append({
                "range": {"start": {"line": line, "character": col}, "end": {"line": line, "character": max(end, col + 1)}},
                "severity": 1, "source": "sip", "message": msg})
        prev = self.flagged.get(path, set())
        now = set(diags) | {path}
        for p in prev - now:
            self.publish(p, [])
        for p in now:
            self.publish(p, diags.get(p, []))
        self.flagged[path] = set(diags)

    # ---------- запросы ----------

    def where(self, path, pos):
        text = self.docs.get(path, "")
        lines = text.splitlines()
        ln = pos["line"]
        line = lines[ln] if ln < len(lines) else ""
        return line, ln + 1, pos["character"]

    def hover(self, path, pos):
        a = self.good.get(path)
        if a is None:
            return None
        line, ln, col = self.where(path, pos)
        word, start = word_at(line, col)
        if not word or word in KEYWORDS:
            return None
        desc = a.hover(ln, word)
        if not desc:
            return None
        return {"contents": {"kind": "markdown", "value": f"```sip\n{desc}\n```"},
                "range": {"start": {"line": ln - 1, "character": start},
                          "end": {"line": ln - 1, "character": start + len(word)}}}

    def definition(self, path, pos):
        a = self.good.get(path)
        if a is None:
            return None
        line, ln, col = self.where(path, pos)
        word, _ = word_at(line, col)
        if not word:
            return None
        target = a.definition(ln, word)
        if not target:
            return None
        file, local = a.srcmap.locate(target)
        file = os.path.abspath(file)
        lines = (self.docs.get(file) if file in self.docs else _read(file)).splitlines()
        text = lines[local - 1] if 0 < local <= len(lines) else ""
        m = re.search(rf"\b{re.escape(word)}\b", text)
        c = m.start() if m else 0
        return {"uri": path_to_uri(file),
                "range": {"start": {"line": local - 1, "character": c},
                          "end": {"line": local - 1, "character": c + (len(word) if m else 0)}}}

    def completion(self, path, pos):
        a = self.good.get(path)
        if a is None:
            return []
        line, ln, col = self.where(path, pos)
        return [{"label": k, "kind": kind} for k, kind in a.complete(line[:col], ln)]

    def formatting(self, path):
        from .fmt import format_source
        text = self.docs.get(path, "")
        try:
            out = format_source(text, path)
        except SipError:
            return []
        if out == text:
            return []
        n = len(text.splitlines()) + 1
        return [{"range": {"start": {"line": 0, "character": 0}, "end": {"line": n, "character": 0}},
                 "newText": out}]

    def symbols(self, path):
        a = self.good.get(path)
        if a is None:
            return []
        out = []
        kinds = {FnDef: 12, Record: 23, SumType: 10, Interface: 11}
        lines = self.docs.get(path, "").splitlines()
        for n in a.nodes:
            if type(n) in kinds and 0 < n.line < SourceBand and not getattr(n, "is_method", False):
                name = display(getattr(n, "display", n.name))
                if name.startswith("test__"):
                    continue
                text = lines[n.line - 1] if n.line <= len(lines) else ""
                r = {"start": {"line": n.line - 1, "character": 0}, "end": {"line": n.line - 1, "character": len(text)}}
                out.append({"name": name, "kind": kinds[type(n)], "range": r, "selectionRange": r})
        return out


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def serve() -> int:
    return Server().serve()
