"""Модули: `import utils`, `from utils import f` и встроенные модули (math, json, ...).

Все модули сливаются в одну программу. Имена верхнего уровня модуля получают
префикс (`utils.f` становится `utils__f`), поэтому одинаковые имена в разных
модулях не конфликтуют. Строки всех файлов нумеруются подряд: строка N
программы — это строка N - offset файла, в котором она лежит (SourceMap).
"""

from __future__ import annotations

import hashlib
import os
import re
import subprocess
import tomllib
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

    BAND = 1 << 20  # строк на файл: номер строки = номер файла * BAND + строка в файле

    def add(self, path: str, src: str) -> int:
        # у каждого файла своя полоса номеров: строки модуля не сдвигаются, когда меняются другие
        offset = len(self.files) * self.BAND
        self.files.append((offset, path, src.splitlines() or [""]))
        return offset

    def sources(self) -> list:
        """Файлы, от которых зависит программа: модули и sip.toml пакетов."""
        return [os.path.abspath(p) for _, p, _ in self.files] + list(getattr(self, "extra", []))

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
        elif isinstance(s, (Record, Interface)):
            names.append(s.name)
        elif isinstance(s, SumType):
            names.append(s.name)
            names += [v.name for v in s.variants]
    names += Checker().assigned([s for s in body if not isinstance(s, (FnDef, Record, SumType, Interface))])
    return names


def _fn_locals(fn: FnDef) -> set:
    from .checker import Checker
    names = {p.name for p in fn.params}
    names |= set(Checker().assigned(fn.body))
    return names


NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*$")


class Package:
    """Папка с sip.toml: имя пакета и его зависимости {имя: папка}."""

    def __init__(self, root: str, name: str, deps: dict, toml: str):
        self.root = root
        self.name = name
        self.deps = deps
        self.toml = toml


def fetch_git(name: str, url: str, rev: str, where: str, line: int) -> str:
    """git-зависимость: клон нужной ревизии в кэше (один раз)."""
    from .compiler import cache_dir
    dest = cache_dir() / "pkgs" / f"{name}-{hashlib.sha256(f'{url}@{rev}'.encode()).hexdigest()[:12]}"
    if dest.exists():
        return str(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = f"{dest}.tmp{os.getpid()}"
    try:
        for cmd in (["git", "clone", "--quiet", url, tmp], ["git", "-C", tmp, "checkout", "--quiet", rev]):
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                raise SipError(f"dependency '{name}': {' '.join(cmd[:2])} failed: {r.stderr.strip()[:500]}",
                               line, 0, where)
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            subprocess.run(["rm", "-rf", tmp])
    return str(dest)


def read_package(root: str) -> Package:
    toml = os.path.join(root, "sip.toml")
    try:
        with open(toml, "rb") as f:
            data = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise SipError(f"bad sip.toml: {e}", 0, 0, toml) from None
    pkg = data.get("package", {})
    name = pkg.get("name") or os.path.basename(os.path.abspath(root))
    if not NAME_RE.match(name):
        raise SipError(f"package name '{name}' must be a valid identifier", 0, 0, toml)
    deps = {}
    for dname, spec in (data.get("deps") or {}).items():
        if not NAME_RE.match(dname):
            raise SipError(f"dependency name '{dname}' must be a valid identifier", 0, 0, toml)
        if isinstance(spec, str):
            spec = {"path": spec}
        if not isinstance(spec, dict):
            raise SipError(f"dependency '{dname}': write {{ path = \"...\" }} or {{ git = \"...\", rev = \"...\" }}",
                           0, 0, toml)
        if "path" in spec:
            d = os.path.normpath(os.path.join(root, spec["path"]))
            if not os.path.isdir(d):
                raise SipError(f"dependency '{dname}': folder {d} not found", 0, 0, toml)
        elif "git" in spec:
            if not spec.get("rev"):
                raise SipError(f"dependency '{dname}': pin a version with rev = \"<tag or commit>\"", 0, 0, toml)
            d = fetch_git(dname, spec["git"], spec["rev"], toml, 0)
        else:
            raise SipError(f"dependency '{dname}' needs path or git", 0, 0, toml)
        deps[dname] = d
    return Package(os.path.abspath(root), name, deps, toml)


def find_package(start: str) -> Package | None:
    """Ближайший sip.toml в папке файла или выше."""
    d = os.path.abspath(start)
    while True:
        if os.path.isfile(os.path.join(d, "sip.toml")):
            return read_package(d)
        up = os.path.dirname(d)
        if up == d:
            return None
        d = up


class Loader:
    def __init__(self):
        self.srcmap = SourceMap()
        self.srcmap.extra = []
        self.modules: dict = {}   # путь файла -> exports {имя: новое имя}
        self.loading: set = set()
        self.bodies: list = []    # тела модулей-зависимостей в порядке загрузки
        self.packages: dict = {}  # папка -> Package | None
        self.base = "."
        self.tests = False        # sip test: блоки test корневого файла становятся функциями
        self.overlay: dict = {}   # путь -> текст (sip lsp: несохранённые файлы редактора)
        self.root_mods: dict = {}     # псевдонимы import в корневом файле -> exports
        self.root_natives: dict = {}  # псевдонимы встроенных модулей (math, json, ...)

    def package_of(self, path: str) -> Package | None:
        d = os.path.dirname(os.path.abspath(path))
        if d not in self.packages:
            pkg = find_package(d)
            self.packages[d] = pkg
            if pkg is not None and pkg.toml not in self.srcmap.extra:
                self.srcmap.extra.append(pkg.toml)
        return self.packages[d]

    def load_root(self, path: str, src: str) -> Module:
        mod = Parser(tokenize(src, path), path).parse_module()
        tests = []
        if self.tests:
            for i, s in enumerate(mod.body):
                if isinstance(s, TestDef):
                    fname = f"test__{len(tests) + 1}"
                    tests.append((s.name, fname))
                    mod.body[i] = FnDef(fname, [], None, s.body, line=s.line)
        mod.body = [s for s in mod.body if not isinstance(s, TestDef)]
        offset = self.srcmap.add(path, src)
        pkg = self.package_of(path)
        self.base = pkg.root if pkg is not None else os.path.dirname(os.path.abspath(path))
        self.loading.add(os.path.abspath(path))  # import самого себя — циклический импорт
        body = self.process(mod.body, "", path, offset)
        out = Module(self.bodies + body, line=1)
        out.tests = tests if self.tests else None
        return out

    def resolve(self, name: str, from_path: str, node) -> tuple[str, str]:
        """import a.b -> (путь файла, префикс имён).

        Ищется: рядом с импортирующим файлом; в зависимости пакета (import dep, import dep.x);
        от корня пакета (папки с sip.toml).
        """
        parts = name.split(".")
        here = os.path.dirname(os.path.abspath(from_path))
        tried = [os.path.join(here, *parts) + ".sip"]
        pkg = self.package_of(from_path)
        if pkg is not None and parts[0] in pkg.deps:
            droot = pkg.deps[parts[0]]
            tried.append(os.path.join(droot, *(parts[1:] or parts[:1])) + ".sip")
        if pkg is not None:
            tried.append(os.path.join(pkg.root, *parts) + ".sip")
        for path in tried:
            if os.path.isfile(path):
                return os.path.abspath(path), self.prefix(path)
        raise SipError(f"module '{name}' not found (looked for {', '.join(tried)})", node.line, 0, from_path)

    def prefix(self, path: str) -> str:
        """Префикс имён модуля: из пакета и пути внутри него, чтобы модули разных пакетов не путались."""
        pkg = self.package_of(path)
        if pkg is not None and pkg.root != self.base:
            label = [pkg.name] + os.path.relpath(path, pkg.root)[:-4].split(os.sep)
        else:
            rel = os.path.relpath(path, self.base)[:-4]
            label = [p if p != ".." else "up" for p in rel.split(os.sep)]
        return "__".join(re.sub(r"\W", "_", p) for p in label) + "__"

    def load_module(self, name: str, from_path: str, node) -> dict:
        path, prefix = self.resolve(name, from_path, node)
        if path in self.loading:
            raise SipError(f"circular import of '{name}'", node.line, 0, from_path)
        if path in self.modules:
            return self.modules[path]
        if path in self.overlay:
            src = self.overlay[path]
        else:
            with open(path, encoding="utf-8") as f:
                src = f.read()
        self.loading.add(path)
        mod = Parser(tokenize(src, path), path).parse_module()
        mod.body = [s for s in mod.body if not isinstance(s, TestDef)]  # тесты модуля — только для sip test его самого
        offset = self.srcmap.add(path, src)
        exports = {n: prefix + n for n in _top_names(mod.body)}
        body = self.process(mod.body, prefix, path, offset, exports)
        self.bodies += body
        self.loading.discard(path)
        self.modules[path] = exports
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
                        if n.startswith("_"):
                            raise SipError(f"'{n}' is private to module '{s.module}' (names starting with _ "
                                           f"are not exported)", s.line, 0, path)
                        names[alias] = ex[n]
            else:
                rest.append(s)
        if not prefix:
            self.root_mods, self.root_natives = mods, natives
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
            if attr.startswith("_"):
                self.err(f"'{attr}' is private to module '{alias}' (names starting with _ are not exported)", node)
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
        s.mod = self.path  # файл, которому принадлежит инструкция верхнего уровня
        if isinstance(s, (FnDef, Record, SumType, Interface)):
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
        if isinstance(node, Handler):
            if node.kind:
                node.kind = self.dotted(node.kind, node, local)
            if node.name:
                node.name = self.new(node.name, local) or node.name
        if isinstance(node, Variant) and node.name in self.names:
            node.display = node.name
            node.name = self.names[node.name]
        if isinstance(node, (Record, SumType)) and node.tparams:
            local = local | {tp.name for tp in node.tparams}  # T в полях — не имя модуля
        if isinstance(node, FnDef):
            node.tparams = self.rn(node.tparams, local)
            local = local | {tp.name for tp in node.tparams}
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


def load_program(path: str, src: str, tests: bool = False, overlay: dict | None = None):
    loader = Loader()
    loader.tests = tests
    loader.overlay = overlay or {}
    mod = loader.load_root(path, src)
    loader.srcmap.loader = loader
    return mod, loader.srcmap
