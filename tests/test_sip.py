"""Тесты Sip. Запуск: python3 -m unittest discover -s tests"""

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from siplang import SipError, compile_source, execute  # noqa: E402
from siplang.lexer import tokenize  # noqa: E402

EXAMPLES = ROOT / "examples"


def run(src: str, argv: list[str] | None = None) -> str:
    """Компилирует и выполняет Sip-код, возвращает напечатанное."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        execute(compile_source(src, "<test>"), argv or [])
    return out.getvalue()


def run_file(path, *args) -> str:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        execute(compile_source(Path(path).read_text(), str(path)), list(args))
    return out.getvalue()


def cli(*args, cwd=ROOT) -> subprocess.CompletedProcess:
    env = dict(os.environ, PYTHONPATH=str(ROOT))
    env.pop("SIP_TRACE", None)
    return subprocess.run([sys.executable, "-m", "siplang", *args], cwd=cwd, env=env,
                          capture_output=True, text=True)


def errors_of(src: str) -> str:
    with unittest.TestCase().assertRaises(SipError) as ctx:
        compile_source(src, "t.sip")
    return str(ctx.exception)


class LexerTest(unittest.TestCase):
    def test_range_is_not_a_float(self):
        kinds = [t.kind for t in tokenize("1..100")]
        self.assertEqual(kinds, ["NUMBER", "..", "NUMBER", "NEWLINE", "EOF"])

    def test_indent_dedent(self):
        kinds = [t.kind for t in tokenize("if x\n    y\nz\n")]
        self.assertEqual(kinds, ["if", "NAME", "NEWLINE", "INDENT", "NAME", "NEWLINE", "DEDENT",
                                 "NAME", "NEWLINE", "EOF"])

    def test_newlines_ignored_inside_brackets(self):
        kinds = [t.kind for t in tokenize("x = [\n  1,\n  2,\n]\n")]
        self.assertEqual(kinds.count("NEWLINE"), 1)

    def test_nested_quotes_in_interpolation(self):
        self.assertEqual(run('d = {k: "v"}\nprint "<{d["k"]}>"'), "<v>\n")


class SemanticsTest(unittest.TestCase):
    def test_implicit_return_and_one_line_fn(self):
        src = "fn double(x int) int = x * 2\nfn inc(x int) int\n    y = x + 1\n    y\nprint double(4), inc(4)"
        self.assertEqual(run(src), "8 5\n")

    def test_int_division_is_floor(self):
        self.assertEqual(run("print 7 / 2, 7.0 / 2, -7 / 2"), "3 3.5 -4\n")

    def test_inclusive_range(self):
        self.assertEqual(run("print sum(1..100), list(0..2)"), "5050 [0, 1, 2]\n")

    def test_range_with_expression_end(self):
        self.assertEqual(run("n = 3\nprint list(1..n + 1)"), "[1, 2, 3, 4]\n")

    def test_bare_dict_keys_are_strings(self):
        self.assertEqual(run('print {host: "h", port: 1}'), "{'host': 'h', 'port': 1}\n")

    def test_dict_comprehension_keys_are_variables(self):
        self.assertEqual(run("print {k: k * 2 for k in [1, 2]}"), "{1: 2, 2: 4}\n")

    def test_for_pairs_over_dict(self):
        self.assertEqual(run("for k, v in {a: 1, b: 2}\n    print k, v"), "a 1\nb 2\n")

    def test_if_expression_elif_chain(self):
        src = 'fn sign(x int) str = if x > 0 then "+" elif x < 0 then "-" else "0"\nprint sign(5), sign(-1), sign(0)'
        self.assertEqual(run(src), "+ - 0\n")

    def test_if_block_with_else_if(self):
        src = "x = 5\nif x > 10\n    print 1\nelse if x > 3\n    print 2\nelse\n    print 3"
        self.assertEqual(run(src), "2\n")

    def test_inline_if_then_else(self):
        self.assertEqual(run("x = 1\nif x == 1 then print 'one' else print 'other'"), "one\n")

    def test_implicit_return_through_if(self):
        src = "fn f(x int) str\n    if x > 0\n        'pos'\n    else\n        'neg'\nprint f(1), f(-1)"
        self.assertEqual(run(src), "pos neg\n")

    def test_record_with_methods(self):
        src = (
            "type Point(x int, y int = 0)\n"
            "    fn norm2() int = .x * .x + .y * .y\n"
            "    fn moved(dx int) Point = Point(.x + dx, .y)\n"
            "p = Point(3, 4)\nprint p.norm2(), p.moved(1), Point(1)"
        )
        self.assertEqual(run(src), "25 Point(x=4, y=4) Point(x=1, y=0)\n")

    def test_record_block_style_and_mutable_default(self):
        src = "type Bag\n    items [int] = []\n    fn add(x int)\n        .items.append(x)\nb = Bag()\nb.add(1)\nprint Bag().items, b.items"
        self.assertEqual(run(src), "[] [1]\n")

    def test_sum_type_match(self):
        src = (
            "type Color = Red | Green | Rgb(r int, g int, b int)\n"
            "fn name(c Color) str = match c\n"
            "    Red -> 'red'\n"
            "    Rgb(r, _, _) if r > 200 -> 'reddish'\n"
            "    Rgb(r, g, b) -> '#{r}{g}{b}'\n"
            "    _ -> 'other'\n"
            "print name(Red()), name(Rgb(250, 0, 0)), name(Rgb(1, 2, 3)), name(Green())\n"
            "print isinstance(Red(), Color)"
        )
        self.assertEqual(run(src), "red reddish #123 other\nTrue\n")

    def test_match_literals_and_tuples(self):
        src = (
            "for i in [3, 5, 15, 7]\n"
            "    print match_it(i)\n"
            "fn match_it(i int) str = match (i % 3, i % 5)\n"
            "    (0, 0) -> 'FizzBuzz'\n"
            "    (0, _) -> 'Fizz'\n"
            "    (_, 0) -> 'Buzz'\n"
            "    _ -> str(i)\n"
        )
        # функция объявлена после цикла: как и в Python, это ошибка времени выполнения
        with self.assertRaises(NameError):
            run(src)
        fixed = src.split("fn ", 1)
        self.assertEqual(run("fn " + fixed[1] + fixed[0]), "Fizz\nBuzz\nFizzBuzz\n7\n")

    def test_try_catch_inline_and_block(self):
        src = (
            "fn parse(s str) int\n"
            "    try int(s)\n"
            "    catch ValueError -> -1\n"
            "fn risky()\n"
            "    try\n"
            "        fail 'boom'\n"
            "    catch e\n"
            "        print 'caught', e\n"
            "print parse('12'), parse('x')\n"
            "risky()"
        )
        self.assertEqual(run(src), "12 -1\ncaught boom\n")

    def test_fail_raises_error(self):
        with self.assertRaisesRegex(Exception, "nope"):
            run("fail 'nope {1 + 1}'")

    def test_not_found_alias(self):
        src = "fn load() str\n    try read('/no/such/file')\n    catch NotFound -> 'missing'\nprint load()"
        self.assertEqual(run(src), "missing\n")

    def test_extension_methods(self):
        src = (
            "words = 'a b a c a b'.split()\n"
            "print words.count().top(2)\n"
            "print words.count('a'), 'banana'.count('an')\n"
            "print [3, 1, 2].map(fn(x) = x * 10).filter(fn(x) = x > 10)\n"
            "print [1, 2, 3].join(', '), ', '.join(['x', 'y'])\n"
            "print [{n: 'b', a: 2}, {n: 'a', a: 1}].sort_by(fn(r) = r['a']).first()['n']\n"
            "print [1, 2, 3, 4].group_by(fn(x) = x % 2), [2, 4].avg(), [1, 2].sum()"
        )
        self.assertEqual(run(src), (
            "[('a', 3), ('b', 2)]\n"
            "3 2\n"
            "[30, 20]\n"
            "1, 2, 3 x, y\n"
            "a\n"
            "{1: [1, 3], 0: [2, 4]} 3.0 3\n"
        ))

    def test_extension_methods_defer_to_own_methods(self):
        src = "type Box(n int)\n    fn count() int = .n\nprint Box(7).count()"
        self.assertEqual(run(src), "7\n")

    def test_kwargs_colon_and_equals(self):
        src = "fn f(a int, b = 1, c = 2) = a + b * c\nprint f(1, b: 10), f(1, c=5)"
        self.assertEqual(run(src), "21 6\n")

    def test_interpolation_self_spec_and_braces(self):
        src = "type T(v float)\n    fn show() str = '{.v:.1f} {{ok}}'\nprint T(2.345).show()"
        self.assertEqual(run(src), "2.3 {ok}\n")

    def test_python_habits_are_tolerated(self):
        src = (
            "fn f(x: int) -> int:\n"
            "    if x > 0:\n"
            "        return x\n"
            "    return None\n"
            "type A(v int)\n"
            "    fn get(self) int = self.v\n"
            "print f(2), f(-1), True, A(5).get()"
        )
        self.assertEqual(run(src), "2 None True 5\n")

    def test_python_interop_imports(self):
        src = "import math\nfrom os.path import basename as b\nprint math.floor(2.7), b('/x/y.txt')"
        self.assertEqual(run(src), "2 y.txt\n")

    def test_async_gather(self):
        src = (
            "import asyncio\n"
            "async fn slow(x int) int\n"
            "    await asyncio.sleep(0.05)\n"
            "    x * 2\n"
            "async fn main()\n"
            "    print await all(slow(i) for i in 1..10)\n"
        )
        start = time.perf_counter()
        self.assertEqual(run(src), "[2, 4, 6, 8, 10, 12, 14, 16, 18, 20]\n")
        self.assertLess(time.perf_counter() - start, 0.4)  # параллельно, а не 10 × 0.05

    def test_main_becomes_cli(self):
        src = "fn main(name str, times = 1, loud = false)\n    for _ in 1..times\n        print if loud then name.upper() else name"
        self.assertEqual(run(src, ["ann", "--times", "2", "--loud"]), "ANN\nANN\n")

    def test_print_command_forms(self):
        src = "type T(v int)\n    fn show()\n        print .v\nprint [1, 2]\nprint\nprint 'a', 'b'\nT(3).show()"
        self.assertEqual(run(src), "[1, 2]\n\na b\n3\n")

    def test_keyword_names_are_mangled(self):
        self.assertEqual(run("def = 1\nclass_ = 2\nprint def + class_"), "3\n")


class ErrorTest(unittest.TestCase):
    def test_syntax_error_is_one_line_with_position(self):
        msg = errors_of("x = (1 +\n")
        self.assertEqual(msg.count("\n"), 0)
        self.assertTrue(msg.startswith("t.sip:"), msg)

    def test_missing_then(self):
        self.assertIn("expected 'then'", errors_of("x = if a 1 else 2"))

    def test_def_hint(self):
        self.assertEqual(errors_of("def f(x):\n    return x"), "t.sip:1:1: 'def' is not Sip: use 'fn' to define a function")

    def test_self_attr_outside_method(self):
        self.assertIn("'.x' used outside a method", errors_of("fn f() = .x"))

    def test_await_outside_async(self):
        self.assertEqual(errors_of("fn f()\n    await g()"), "t.sip:2: 'await' outside async function")

    def test_bad_indent(self):
        self.assertIn("indentation does not match", errors_of("if x\n    a\n  b"))

    def test_runtime_error_maps_to_sip_line(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, "prog.sip")
            p.write_text("xs = [1, 2]\n\nfn get(i int) int = xs[i]\nprint get(5)\n")
            r = cli("run", str(p))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stderr, f"{p}:3: IndexError: list index out of range\n    fn get(i int) int = xs[i]\n")

    def test_cli_compile_error(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d, "bad.sip")
            p.write_text("print (1\n")
            r = cli("run", str(p))
        self.assertEqual(r.returncode, 1)
        self.assertIn("bad.sip:", r.stderr)


class JsonHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(0.1)
        if self.path.startswith("/users/"):
            body = json.dumps({"name": f"user{self.path.rsplit('/', 1)[1]}"}).encode()
            self.send_response(200)
        else:
            body = b"{}"
            self.send_response(404)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


class ExamplesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), JsonHandler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_all_examples_compile(self):
        files = sorted(EXAMPLES.glob("*.sip"))
        self.assertGreaterEqual(len(files), 12)
        for f in files:
            with self.subTest(f.name):
                compile_source(f.read_text(), str(f))

    def test_fizzbuzz(self):
        lines = run_file(EXAMPLES / "fizzbuzz.sip").split()
        self.assertEqual(lines[:15], "1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz".split())
        self.assertEqual(len(lines), 100)

    def test_simple_programs(self):
        cases = {
            "sum_even_squares": "56\n",
            "user": "Hello, Ann! True\n",
            "shapes": "Circle(r=1.0): 3.14\nRect(w=2, h=3): 6.00\nTriangle(b=4, h=5): 10.00\n",
            "fib": "23416728348467685\n",
            "binary_search": "3 -1\n",
        }
        for name, expected in cases.items():
            with self.subTest(name):
                self.assertEqual(run_file(EXAMPLES / f"{name}.sip"), expected)

    def test_greet(self):
        self.assertEqual(run_file(EXAMPLES / "greet.sip", "Ann", "--times", "2"), "Hello, Ann!\nHello, Ann!\n")

    def test_word_freq(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("the cat and The dog and THE bird")
        try:
            self.assertEqual(run_file(EXAMPLES / "word_freq.sip", f.name, "--n", "2"), "the: 3\nand: 2\n")
        finally:
            os.unlink(f.name)

    def test_csv_groupby(self):
        with tempfile.NamedTemporaryFile("w", suffix=".csv", delete=False) as f:
            f.write("name,dept,salary\na,dev,100\nb,dev,200\nc,ops,90\n")
        try:
            self.assertEqual(run_file(EXAMPLES / "csv_groupby.sip", f.name), "dev: 150\nops: 90\n")
        finally:
            os.unlink(f.name)

    def test_config(self):
        with tempfile.TemporaryDirectory() as d:
            good = Path(d, "c.json")
            good.write_text('{"port": 9000}')
            self.assertEqual(run_file(EXAMPLES / "config.sip", str(good)),
                             "host = localhost\nport = 9000\ndebug = False\n")
            self.assertIn("port = 8080", run_file(EXAMPLES / "config.sip", str(Path(d, "missing.json"))))
            bad = Path(d, "bad.json")
            bad.write_text("{oops")
            with self.assertRaisesRegex(Exception, "bad config"):
                run_file(EXAMPLES / "config.sip", str(bad))

    def test_http_json(self):
        self.assertEqual(run_file(EXAMPLES / "http_json.sip", "42", "--base", self.base), "user42\n")
        out = run_file(EXAMPLES / "http_json.sip", "1", "--base", self.base + "/nope")
        self.assertEqual(out, f"error: HTTP 404 for {self.base}/nope/users/1\nNone\n")

    def test_fetch_all_is_concurrent(self):
        urls = [f"{self.base}/users/{i}" for i in range(8)]
        # 404 бросает HttpError: ошибка одного запроса доходит до программы
        with self.assertRaises(Exception):
            run_file(EXAMPLES / "fetch_all.sip", *urls, f"{self.base}/missing")
        start = time.perf_counter()
        out = run_file(EXAMPLES / "fetch_all.sip", *urls)
        elapsed = time.perf_counter() - start
        self.assertEqual(out.splitlines()[0], f"200 {urls[0]}")
        self.assertEqual(len(out.splitlines()), 8)
        self.assertLess(elapsed, 0.5)  # подряд 8 запросов × 0.1 с заняли бы 0.8 с

    def test_build_writes_python(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d, "fib.py")
            r = cli("build", str(EXAMPLES / "fib.sip"), "-o", str(out))
            self.assertEqual(r.returncode, 0, r.stderr)
            env = dict(os.environ, PYTHONPATH=str(ROOT))
            res = subprocess.run([sys.executable, str(out)], capture_output=True, text=True, env=env)
            self.assertEqual(res.stdout, "23416728348467685\n")


if __name__ == "__main__":
    unittest.main()
