"""Сравнивает компоненты компилятора на Sip с эталоном на Python.

python3 selfhost/parity.py [ФАЙЛЫ.sip ...]
Без аргументов — все .sip в репозитории и набор трудных случаев.
"""

import glob
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)

from siplang.compiler import build_cached  # noqa: E402
from siplang.errors import SipError  # noqa: E402
from siplang.lexer import tokenize  # noqa: E402
from siplang.parser import parse  # noqa: E402
from siplang.checker import check_program  # noqa: E402
from siplang.modules import STD_DIR, load_program  # noqa: E402
from siplang.types import show  # noqa: E402
from dataclasses import fields, is_dataclass  # noqa: E402

CASES = [
    "x = 1\n",
    "",
    "\n\n# только комментарий\n",
    "fn f(a int) int = a + 1\n",
    "s = \"a {b + \"c\"} {{x}} \\\" d\"\nt = 'q'\n",
    "x = 1..5\ny = 1.5e-3 + 2E10 + 1_000\nz = 3e\n",
    "if a\n    b\n        c\n    d\ne\n",
    "xs.map(fn(x)\n    y = x * 2\n    y + 1\n)\nprint 1\n",
    "f(fn(x)\n    x + 1)\n",
    "g = fn(x)\n    x\nh = 1\n",
    "t fn(int) int\nfn k() fn(int)\n    pass\n",
    "имя = \"привет\" # коммент\nб = имя + \"й\"\n",
    "a = [\n  1,\n    2,\n]\n",
    "x = 1\r\ny = 2\r\n",
    "if x\n  y\n z\n",
    "\tx = 1\n",
    "x = )\n",
    "x = (1\n",
    "s = \"abc\n",
    "x = 1 $ 2\n",
    "@cache\nfn f(n int) int = n\n",
    "x = a // b ** c -> d != e <= f >= g += 1\n",
    "match x\n    A(b) -> 1\n    _ -> 2\n",
    "x = 1   \n\n\n",
    "fn f()\n    xs.each(fn(x)\n        print x\n    )\n    print 2\n",
]


def py_dump(src: str, name: str) -> str:
    try:
        toks = tokenize(src, name)
    except SipError as e:
        return str(e) + "\n"
    out = []
    for t in toks:
        if t.kind == "STRING":
            q, v = t.value
        else:
            q, v = "", str(t.value)
        out.append(f"{t.kind}\t{t.line}\t{t.col}\t{len(v.encode())}\t{q}{v}")
    return "\n".join(out) + "\n"


def ast_lines(v, depth, out, types=False):
    pad = "  " * depth
    if isinstance(v, bool):
        out.append(pad + ("T" if v else "F"))
    elif isinstance(v, str):
        out.append(pad + f"s{len(v.encode())}:" + v)
    elif v is None:
        out.append(pad + "_")
    elif isinstance(v, (list, tuple)):
        out.append(pad + ("[" if isinstance(v, list) else "<") + str(len(v)))
        for x in v:
            ast_lines(x, depth + 1, out, types)
    elif is_dataclass(v):
        line = pad + f"{type(v).__name__}@{v.line}"
        if types and "ty" in v.__dict__:
            line += " :: " + show(v.ty)
        out.append(line)
        for f in fields(v):
            if f.name != "line":
                ast_lines(getattr(v, f.name), depth + 1, out, types)
        if hasattr(v, "extern"):
            out.append(pad + f"  extern@{v.line}")
            for x in (v.extern, v.csym, v.ctypes, v.cret):
                ast_lines(x, depth + 2, out, types)
    else:
        raise TypeError(f"unexpected value in AST: {v!r}")


def py_ast(src: str, name: str) -> str:
    try:
        tree = parse(src, name)
    except SipError as e:
        return str(e) + "\n"
    out = []
    ast_lines(tree, 0, out)
    return "\n".join(out) + "\n"


def py_check(src: str, name: str) -> str:
    try:
        mod, srcmap = load_program(name, src)
        check_program(mod, name, srcmap)
    except SipError as e:
        return str(e) + "\n"
    out = []
    ast_lines(mod, 0, out, types=True)
    return "\n".join(out) + "\n"


# программы из нескольких файлов: {путь: текст}, корень — main.sip
PROJECTS = [
    {"main.sip": "import utils\nfrom utils import twice as tw, Point\nimport utils as u\n"
                 "p = Point(1, 2)\nprint utils.twice(3), tw(4), u.twice(p.x), utils.LIMIT\n"
                 "fn main()\n    q: utils.Point = utils.origin()\n    print q.y\n",
     "utils.sip": "LIMIT = 10\ntype Point(x int, y int)\nfn twice(n int) int = n * 2\n"
                  "fn origin() Point = Point(0, 0)\n"},
    {"main.sip": "import a.b\nprint b.f()\n", "a/b.sip": "import c\nfn f() int = c.g() + 1\n",
     "a/c.sip": "fn g() int = 41\n"},
    {"main.sip": "import x\n", "x.sip": "import y\n", "y.sip": "import x\n"},
    {"main.sip": "import nope\n"},
    {"main.sip": "from utils import missing\n", "utils.sip": "fn f() = 1\n"},
    {"main.sip": "from utils import _hidden\n", "utils.sip": "fn _hidden() int = 1\n"},
    {"main.sip": "import utils\nprint utils._hidden()\n", "utils.sip": "fn _hidden() int = 1\n"},
    {"main.sip": "import utils\nprint utils.nothing\n", "utils.sip": "x = 1\n"},
    {"main.sip": "import utils\nprint utils\n", "utils.sip": "x = 1\n"},
    {"main.sip": "import acct\na = acct.open(5)\nprint a._bal\n",
     "acct.sip": "type Acct(name str, _bal int = 0)\nfn open(n int) Acct = Acct(\"x\", n)\n"},
    {"main.sip": "import acct\na = acct.Acct(\"bob\")\nprint a.name, a.balance()\nb = acct.Acct(\"c\", 5)\n",
     "acct.sip": "type Acct(name str, _bal int = 0)\n    fn balance() int = ._bal\n    fn _secret() int = 1\n"},
    {"main.sip": "import acct\na = acct.Acct(\"bob\")\nprint a._secret()\n",
     "acct.sip": "type Acct(name str, _bal int = 0)\n    fn _secret() int = 1\n"},
    {"main.sip": "import acct\nmatch acct.Acct(\"b\")\n    acct.Acct(n, b) -> print n, b\n",
     "acct.sip": "type Acct(name str, _bal int = 0)\n"},
    {"main.sip": "import shapes\nfn area(s shapes.Shape) float = match s\n"
                 "    shapes.Circle(r) -> 3.0 * r * r\n    shapes.Sq(a) -> a * a\nprint area(shapes.Sq(2.0))\n"
                 "print shapes.biggest([shapes.Circle(1.0)])\n",
     "shapes.sip": "type Shape = Circle(r float) | Sq(a float)\nfn biggest(xs [Shape]) Shape = xs[0]\n"},
    {"main.sip": "import box\nb = box.Box[int](3)\nprint b.get(), box.first([1, 2])\nprint box.Box(\"s\").get()\n",
     "box.sip": "type Box[T](v T)\n    fn get() T = .v\nfn first[T](xs [T]) T = xs[0]\n"},
    {"main.sip": "import util\nprint util.f(\"a\")\n", "util.sip": "fn f(n int) int = n\n"},
    {"main.sip": "import util\nprint util.f(1, 2)\n", "util.sip": "fn f(n int) int = n\n"},
    {"main.sip": "import util\n", "util.sip": "type T = A | B\ntype A(x int)\n"},
    {"main.sip": "import util\n", "util.sip": "fn f(\n"},
    {"main.sip": "import util\n", "util.sip": "x = 1\ny = \"a\" + 1\n"},
    {"main.sip": "import re\nimport path\nimport os\nm = re.search(\"(\\\\d+)\", \"ab12\")\n"
                 "if m != nil then print m.groups\nprint path.join(\"a\", \"b\"), os.cwd() != \"\"\n"},
    {"main.sip": "import math\nfrom json import parse\nimport random as r\nx: [int] = parse(\"[1]\")\n"
                 "print math.sqrt(2), r.randint(1, 2), x\n"},
    {"main.sip": "import math as m\nprint m\n"},
    {"main.sip": "from math import nope\n"},
    {"main.sip": "import kit\nfrom kit.fmt import pad\nprint kit.shout(\"a\"), pad(\"b\")\n",
     "sip.toml": "[package]\nname = \"app\"\n\n[deps]\nkit = { path = \"../kit\" }\n",
     "../kit/sip.toml": "[package]\nname = \"kit\"\n",
     "../kit/kit.sip": "import fmt\nfn shout(s str) str = fmt.pad(s.upper())\n",
     "../kit/fmt.sip": "fn pad(s str) str = \" \" + s\n"},
    {"main.sip": "import lib.geo\nfrom lib.geo import dist\nprint dist(1.0, 2.0), geo.ORIGIN\n",
     "lib/geo.sip": "import lib.helpers\nORIGIN = 0.0\nfn dist(a float, b float) float = helpers.sq(a - b)\n",
     "lib/helpers.sip": "fn sq(x float) float = x * x\n"},
    {"main.sip": "import a\nimport b\nprint a.Item(1), b.Item(\"x\")\n",
     "a.sip": "type Item(n int)\n", "b.sip": "type Item(s str)\n"},
    {"main.sip": "import a\nx: a.Item = a.Item(\"no\")\n", "a.sip": "type Item(n int)\n"},
]


def write_projects(tmp):
    roots = []
    for i, files in enumerate(PROJECTS):
        d = os.path.join(tmp, f"proj{i}", "app")
        for rel, text in files.items():
            p = os.path.normpath(os.path.join(d, rel))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as f:
                f.write(text)
        roots.append(os.path.join(d, "main.sip"))
    return roots


CORPUS = os.path.join(os.path.expanduser("~"), ".cache", "sip", "selfhost-corpus")


def collect_corpus():
    """Программы, которые компилирует набор тестов: материал для сравнения проверки типов."""
    import hashlib
    import unittest
    from siplang import modules
    os.makedirs(CORPUS, exist_ok=True)
    orig = modules.Loader.load_root

    def load_root(self, path, src):
        h = hashlib.sha1(src.encode()).hexdigest()[:16]
        with open(os.path.join(CORPUS, h + ".sip"), "w", encoding="utf-8", newline="") as f:
            f.write(src)
        return orig(self, path, src)
    modules.Loader.load_root = load_root
    sys.path.insert(0, os.path.join(ROOT, "tests"))
    suite = unittest.defaultTestLoader.loadTestsFromName("test_sip")
    suite = unittest.TestSuite(t for t in _flat(suite) if "Selfhost" not in type(t).__name__)
    unittest.TextTestRunner(stream=open(os.devnull, "w")).run(suite)
    modules.Loader.load_root = orig
    print(f"corpus: {len(os.listdir(CORPUS))} programs in {CORPUS}")


def _flat(suite):
    for t in suite:
        if isinstance(t, unittest_suite()):
            yield from _flat(t)
        else:
            yield t


def unittest_suite():
    import unittest
    return unittest.TestSuite


PARSER_CASES = [
    "fn f[T: Shape](xs [T], *rest int, k = 2) T?\n    return xs[0]\n",
    "type P(x int, y int = 0)\n    z float\n    fn norm() float = .x * .x\n",
    "type Sh = Circle(r float) | Sq(s float) | Empty\n",
    "interface Shape\n    fn area() float\n",
    "extern \"m\" fn cos(x f64) f64\nextern fn abs(n i32) i32 = labs\n",
    "x = {a: 1, \"b\": 2, **d}\ny = {1, 2}\nz = {k: v for k, v in d}\n",
    "s = \"a {x + 1:.2f} {{b}} {f(\"c\")}\"\n",
    "match v\n    Circle(r) if r > 0 -> 1\n    [a, *b] -> 2\n    (1 | 2) -> 3\n    -1 -> 4\n    m.K -> 5\n    _ -> 0\n",
    "try\n    f()\ncatch ValueError e -> print e\ncatch bank.NotEnough as e\n    pass\ncatch e -> 1\n",
    "if a then b elif c then d else e\nx = if a then 1 else 2\n",
    "for (a, b), c in xs\n    print a, b\nwhile x: x -= 1\n",
    "a, b = b, a\nx: [int] = []\ny = z = 3\nobj.f[1:2:3] += 4\n",
    "g = [x * 2 for x in xs if x > 0 for y in ys]\nh = sum(x for x in xs)\n",
    "f = fn(x, y int) = x + y\nxs.map(fn(x)\n    y = x\n    y\n)\n",
    "from a.b import (c, d as e)\nimport os as o\n",
    "@cache\nasync fn f() = await g()\n",
    "with open(p) as f, lock\n    pass\n",
    "x = not a in b and c is not d or e not in f\ny = -x ** 2 & 3 | 4 ^ ~5 // 6 % 7\n",
    "test \"adds\"\n    assert 1 + 1 == 2, \"math\"\n",
    "print\nprint a, b\nprint(x)\nfail Err(1)\n",
    "def f(x):\n    pass\n",
    "1 = x\n",
    "x = (1 +)\n",
    "s = \"{}\"\n",
    "s = \"a } b\"\n",
    "fn f() = match x\n    1 -> 2\n",
    "t: fn(int, str) bool? = nil\nu: {str: [int]} = {}\nv: (int, str) = (1, \"a\")\n",
]


def compare(exe, inputs, want_fn, what, extra=()):
    bad = 0
    for p in inputs:
        with open(p, encoding="utf-8", newline="") as f:
            src = f.read()
        want = want_fn(src, p)
        got = subprocess.run([exe, p, *extra], capture_output=True, text=True).stdout
        if got != want:
            bad += 1
            wl, gl = want.splitlines(), got.splitlines()
            k = next((i for i in range(max(len(wl), len(gl))) if (wl[i:i + 1] != gl[i:i + 1])), 0)
            print(f"MISMATCH {what} {os.path.relpath(p, ROOT)} at line {k}:\n  python: {wl[k:k + 1]}\n  sip:    {gl[k:k + 1]}")
    print(f"{what}: {len(inputs) - bad} of {len(inputs)} inputs match")
    return bad


def write_cases(tmp, prefix, cases):
    out = []
    for i, src in enumerate(cases):
        p = os.path.join(tmp, f"{prefix}{i}.sip")
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(src)
        out.append(p)
    return out


def main(argv):
    if argv[:1] == ["--corpus"]:
        collect_corpus()
        return 0
    only = None
    if argv[:2] and argv[0] == "--only":
        only, argv = argv[1], argv[2:]
    files = argv or sorted(set(glob.glob(os.path.join(ROOT, "**", "*.sip"), recursive=True)))
    tmp = tempfile.mkdtemp()
    lex_in = (write_cases(tmp, "case", CASES) if not argv else []) + files
    par_in = (write_cases(tmp, "pcase", PARSER_CASES + CASES) if not argv else []) + files
    corpus = sorted(glob.glob(os.path.join(CORPUS, "*.sip"))) if not argv else []
    chk_in = par_in + corpus + (write_projects(tmp) if not argv else [])
    bad = 0
    if only in (None, "lexer"):
        bad += compare(build_cached(os.path.join(ROOT, "selfhost", "lexer.sip")), lex_in, py_dump, "lexer")
    if only in (None, "parser"):
        bad += compare(build_cached(os.path.join(ROOT, "selfhost", "parser.sip")), par_in, py_ast, "parser")
    if only in (None, "checker"):
        bad += compare(build_cached(os.path.join(ROOT, "selfhost", "checker.sip")), chk_in, py_check, "checker",
                       ["--std", STD_DIR])
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
