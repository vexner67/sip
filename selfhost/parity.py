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


def ast_lines(v, depth, out):
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
            ast_lines(x, depth + 1, out)
    elif is_dataclass(v):
        out.append(pad + f"{type(v).__name__}@{v.line}")
        for f in fields(v):
            if f.name != "line":
                ast_lines(getattr(v, f.name), depth + 1, out)
        if hasattr(v, "extern"):
            out.append(pad + f"  extern@{v.line}")
            for x in (v.extern, v.csym, v.ctypes, v.cret):
                ast_lines(x, depth + 2, out)
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


def compare(exe, inputs, want_fn, what):
    bad = 0
    for p in inputs:
        with open(p, encoding="utf-8", newline="") as f:
            src = f.read()
        want = want_fn(src, p)
        got = subprocess.run([exe, p], capture_output=True, text=True).stdout
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
    files = argv or sorted(set(glob.glob(os.path.join(ROOT, "**", "*.sip"), recursive=True)))
    tmp = tempfile.mkdtemp()
    lex_in = (write_cases(tmp, "case", CASES) if not argv else []) + files
    par_in = (write_cases(tmp, "pcase", PARSER_CASES + CASES) if not argv else []) + files
    bad = compare(build_cached(os.path.join(ROOT, "selfhost", "lexer.sip")), lex_in, py_dump, "lexer")
    bad += compare(build_cached(os.path.join(ROOT, "selfhost", "parser.sip")), par_in, py_ast, "parser")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
