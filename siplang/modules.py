"""Модули: `import utils`, `from utils import f` и встроенные модули (math, json, ...).

Все модули сливаются в одну программу. Имена верхнего уровня модуля получают
префикс (`utils.f` становится `utils__f`), поэтому одинаковые имена в разных
модулях не конфликтуют. Строки всех файлов нумеруются подряд: строка N
программы — это строка N - offset файла, в котором она лежит (SourceMap).
"""

from __future__ import annotations

import os
from dataclasses import fields

from .errors import SipError
from .lexer import tokenize
from .nodes import *  # noqa: F403
from .parser import Parser

# Встроенные модули и их члены. Вызов `math.sqrt(x)` становится встроенной функцией "math.sqrt".
NATIVE = {
    "math": {"sqrt", "floor", "ceil", "trunc", "log", "log2", "log10", "exp", "sin", "cos", "tan", "asin",
             "acos", "atan", "atan2", "hypot", "pow", "isnan", "isinf", "gcd", "pi", "e", "inf", "nan", "tau"},
    "random": {"random", "randint", "uniform", "choice", "shuffle", "seed"},
    "time": {"time", "sleep", "perf_counter"},
    "json": {"parse", "stringify", "read", "write"},
    "csv": {"read", "write", "parse"},
    "http": {"get", "post", "Response"},
}


class SourceMap:
    def __init__(self):
        self.files: list = []  # [(offset, path, строки)]

    def add(self, path: str, src: str) -> int:
        offset = sum(len(lines) for _, _, lines in self.files)
        self.files.append((offset, path, src.splitlines() or [""]))
        return offset

    def locate(self, line: int):
        """Строка программы -> (файл, строка в файле)."""
        for offset, path, lines in reversed(self.files):
            if line > offset:
                return path, line - offset
        return (self.files[0][1] if self.files else "<input>"), line


def _top_names(body) -> list:
    from .checker import Checker
    names = []
    for s in body:
        if isinstance(s, FnDef):
            names.append(s.name)
        elif isinstance(s, Record):
            names.append(s.name)
        elif isinstance(s, SumType):
            names.append(s.name)
            names += [v.name for v in s.variants]
    names += Checker().assigned([s for s in body if not isinstance(s, (FnDef, Record, SumType))])
    return names


def _fn_locals(fn: FnDef) -> set:
    from .checker import Checker
    names = {p.name for p in fn.params}
    names |= set(Checker().assigned(fn.body))
    return names


class Loader:
    def __init__(self):
        self.srcmap = SourceMap()
        self.modules: dict = {}   # имя модуля -> exports {имя: новое имя}
        self.loading: set = set()
        self.bodies: list = []    # тела модулей-зависимостей в порядке загрузки

    def load_root(self, path: str, src: str) -> Module:
        mod = Parser(tokenize(src, path), path).parse_module()
        offset = self.srcmap.add(path, src)
        body = self.process(mod.body, "", path, offset)
        return Module(self.bodies + body, line=1)

    def load_module(self, name: str, from_path: str, node) -> dict:
        if name in self.modules:
            return self.modules[name]
        if name in self.loading:
            raise SipError(f"circular import of '{name}'", node.line, 0, from_path)
        path = os.path.join(os.path.dirname(os.path.abspath(from_path)), *name.split(".")) + ".sip"
        try:
            with open(path, encoding="utf-8") as f:
                src = f.read()
        except OSError:
            raise SipError(f"module '{name}' not found (looked for {path})", node.line, 0, from_path) from None
        self.loading.add(name)
        mod = Parser(tokenize(src, path), path).parse_module()
        offset = self.srcmap.add(path, src)
        prefix = name.replace(".", "__") + "__"
        exports = {n: prefix + n for n in _top_names(mod.body)}
        body = self.process(mod.body, prefix, path, offset, exports)
        self.bodies += body
        self.loading.discard(name)
        self.modules[name] = exports
        return exports

    def process(self, body, prefix, path, offset, exports=None):
        names = dict(exports or {})
        mods: dict = {}       # псевдоним -> exports модуля .sip
        natives: dict = {}    # псевдоним -> имя встроенного модуля
        rest = []
        for s in body:
            if isinstance(s, Import):
                alias = s.alias or s.module.split(".")[-1]
                if s.module in NATIVE:
                    natives[alias] = s.module
                else:
                    mods[alias] = self.load_module(s.module, path, s)
            elif isinstance(s, FromImport):
                for n, alias in s.names:
                    alias = alias or n
                    if s.module in NATIVE:
                        if n not in NATIVE[s.module]:
                            raise SipError(f"module '{s.module}' has no '{n}'", s.line, 0, path)
                        names[alias] = f"{s.module}.{n}"
                    else:
                        ex = self.load_module(s.module, path, s)
                        if n not in ex:
                            raise SipError(f"module '{s.module}' has no '{n}'", s.line, 0, path)
                        names[alias] = ex[n]
            else:
                rest.append(s)
        r = Renamer(names, mods, natives, path, offset)
        return [r.top(s) for s in rest]


class Renamer:
    def __init__(self, names, mods, natives, path, offset):
        self.names = names
        self.mods = mods
        self.natives = natives
        self.path = path
        self.offset = offset

    def err(self, msg, node):
        raise SipError(msg, node.line, 0, self.path)

    def new(self, name: str, local: set):
        if name in local:
            return None
        return self.names.get(name)

    def member(self, alias: str, attr: str, node, local: set):
        """`alias.attr` -> новое имя, если alias — модуль (а не переменная)."""
        if alias in local or alias in self.names:
            return None
        if alias in self.mods:
            ex = self.mods[alias]
            if attr not in ex:
                self.err(f"module '{alias}' has no '{attr}'", node)
            return ex[attr]
        mod = self.natives.get(alias, alias if alias in NATIVE else None)
        if mod is not None:
            if attr not in NATIVE[mod]:
                self.err(f"module '{mod}' has no '{attr}'", node)
            return f"{mod}.{attr}"
        return None

    def dotted(self, name: str, node, local: set) -> str:
        if "." in name:
            alias, attr = name.split(".", 1)
            got = self.member(alias, attr, node, local)
            return got or name
        return self.new(name, local) or name

    def top(self, s):
        if isinstance(s, (FnDef, Record, SumType)):
            if s.name in self.names:
                s.display = s.name
                s.name = self.names[s.name]
        return self.rn(s, set())

    def rn(self, node, local: set):
        if isinstance(node, list):
            return [self.rn(x, local) for x in node]
        if isinstance(node, tuple):
            return tuple(self.rn(x, local) for x in node)
        if not isinstance(node, Node):
            return node
        if node.line:
            node.line += self.offset
        if isinstance(node, Name):
            n = self.new(node.id, local)
            if n is not None:
                node.id = n
            elif node.id not in local and (node.id in self.mods or node.id in self.natives):
                self.err(f"module '{node.id}' cannot be used as a value", node)
            return node
        if isinstance(node, Attr) and isinstance(node.obj, Name):
            got = self.member(node.obj.id, node.name, node, local)
            if got is not None:
                return Name(got, line=node.line)
        if isinstance(node, (TName, PClass)):
            node.name = self.dotted(node.name, node, local)
        if isinstance(node, PValue):
            name = self.dotted(node.dotted, node, local)
            return PClass(name, [], [], line=node.line)
        if isinstance(node, (PCapture, PStar)):
            node.name = self.new(node.name, local) or node.name
            return node
        if isinstance(node, Handler) and node.name:
            node.name = self.new(node.name, local) or node.name
        if isinstance(node, Variant) and node.name in self.names:
            node.display = node.name
            node.name = self.names[node.name]
        if isinstance(node, FnDef):
            inner = local | _fn_locals(node)
            if node.is_method:
                inner = inner | {"self"}
            for p in node.params:
                self.rn(p, local)  # тип и значение по умолчанию — снаружи
            node.ret = self.rn(node.ret, local)
            node.body = self.rn(node.body, inner)
            return node
        if isinstance(node, Lambda):
            node.types = self.rn(node.types, local)
            inner = local | set(node.params)
            if node.block is not None:
                from .checker import Checker
                inner = inner | set(Checker().assigned(node.block))
                node.block = self.rn(node.block, inner)
            else:
                node.body = self.rn(node.body, inner)
            return node
        if isinstance(node, Comp):
            bound = set()
            for c in node.clauses:
                bound |= _target_names(c.target)
            inner = local | bound
            for c in node.clauses:
                c.iter = self.rn(c.iter, local if c is node.clauses[0] else inner)
                c.target = self.rn(c.target, inner)
                c.conds = self.rn(c.conds, inner)
            node.elt = self.rn(node.elt, inner)
            node.key = self.rn(node.key, inner)
            return node
        for f in fields(node):
            if f.name == "line":
                continue
            setattr(node, f.name, self.rn(getattr(node, f.name), local))
        return node


def _target_names(t) -> set:
    if isinstance(t, Name):
        return {t.id}
    if isinstance(t, TupleLit):
        out = set()
        for i in t.items:
            out |= _target_names(i)
        return out
    return set()


def load_program(path: str, src: str):
    loader = Loader()
    mod = loader.load_root(path, src)
    return mod, loader.srcmap
