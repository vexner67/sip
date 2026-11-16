"""Тесты Sip: лексер, проверка типов, нативный код (через clang) и CLI."""

import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from siplang.compiler import cc_build, compile_source  # noqa: E402
from siplang.errors import SipError  # noqa: E402
from siplang.lexer import tokenize  # noqa: E402

TMP = tempfile.mkdtemp(prefix="siptest")
ENV = {**os.environ, "PYTHONPATH": str(ROOT), "SIP_CACHE": os.path.join(TMP, "cache")}
_n = 0


def build(src: str, name="t") -> str:
    global _n
    _n += 1
    exe = os.path.join(TMP, f"{name}{_n}")
    flags = os.environ.get("SIP_TEST_CFLAGS", "-O1").split()
    cc_build(compile_source(src, f"{name}.sip"), exe, flags)
    return exe


def proc(src: str, args=(), stdin="") -> subprocess.CompletedProcess:
    return subprocess.run([build(src), *args], capture_output=True, text=True, input=stdin, timeout=20)


def run(src: str, *args) -> str:
    r = proc(src, args)
    if r.returncode != 0:
        raise AssertionError(f"exit {r.returncode}: {r.stderr}")
    return r.stdout


def failure(src: str) -> str:
    r = proc(src)
    assert r.returncode == 1, (r.returncode, r.stdout, r.stderr)
    return r.stderr


def errors_of(src: str) -> str:
    try:
        compile_source(src, "t.sip")
    except SipError as e:
        return str(e)
    raise AssertionError("no compile error")


def cli(*args, cwd=ROOT) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-m", "siplang", *args], capture_output=True, text=True,
                          cwd=cwd, env=ENV, timeout=60)


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


class SemanticsTest(unittest.TestCase):
    def test_nested_quotes_in_interpolation(self):
        self.assertEqual(run('d = {k: "v"}\nprint "<{d["k"]}>"'), "<v>\n")

    def test_implicit_return_and_one_line_fn(self):
        src = "fn double(x int) int = x * 2\nfn inc(x int) int\n    y = x + 1\n    y\nprint double(4), inc(4)"
        self.assertEqual(run(src), "8 5\n")

    def test_return_type_is_inferred(self):
        self.assertEqual(run("fn half(x int) = x / 2.0\nprint half(3)"), "1.5\n")

    def test_division_and_modulo_follow_python(self):
        self.assertEqual(run("print 7 / 2, 7.0 / 2, -7 / 2, -7 % 3, 7 % -3, 2 ** 10, -7.5 // 2"),
                         "3 3.5 -4 2 -2 1024 -4.0\n")

    def test_division_by_zero(self):
        self.assertIn("ZeroDivisionError", failure("x = 0\nprint 1 / x"))

    def test_int_is_64_bit_and_wraps(self):
        self.assertEqual(run("x = 9223372036854775807\nprint x, x + 1"),
                         "9223372036854775807 -9223372036854775808\n")

    def test_float_repr_matches_python(self):
        self.assertEqual(run("print 0.1 + 0.2, 1.0, 1e16, 1e-5, 2.5, 1 / 3.0, 100.0 * 3"),
                         "0.30000000000000004 1.0 1e+16 1e-05 2.5 0.3333333333333333 300.0\n")

    def test_inclusive_range(self):
        self.assertEqual(run("print sum(1..100), list(0..2), len(1..0)"), "5050 [0, 1, 2] 0\n")

    def test_range_with_expression_end(self):
        self.assertEqual(run("n = 3\nprint list(1..n + 1), 2 in 1..n, 5 in 1..n"), "[1, 2, 3, 4] True False\n")

    def test_bare_dict_keys_are_strings(self):
        self.assertEqual(run('print {host: "h", port: "1"}'), "{'host': 'h', 'port': '1'}\n")

    def test_dict_keeps_insertion_order_and_grows(self):
        src = ("d: {int: int} = {}\nfor i in 1..1000\n    d[i * 7 % 1009] = i\n"
               "print len(d), d[7], d[14], list(d.keys())[:3]\nd[7] += 1\nprint d[7], 7 in d, -1 in d")
        self.assertEqual(run(src), "1000 1 2 [7, 14, 21]\n2 True False\n")

    def test_missing_key(self):
        self.assertIn("KeyError: 'x'", failure('d = {a: 1}\nprint d["x"]'))

    def test_dict_comprehension_keys_are_variables(self):
        self.assertEqual(run("print {k: k * 2 for k in [1, 2]}"), "{1: 2, 2: 4}\n")

    def test_for_pairs_over_dict(self):
        self.assertEqual(run("for k, v in {a: 1, b: 2}\n    print k, v"), "a 1\nb 2\n")

    def test_if_expression_elif_chain(self):
        src = 'fn sign(x int) str = if x > 0 then "+" elif x < 0 then "-" else "0"\nprint sign(5), sign(-1), sign(0)'
        self.assertEqual(run(src), "+ - 0\n")

    def test_if_expression_mixing_str_and_int(self):
        self.assertEqual(run('for i in 1..3\n    print if i == 2 then "two" else i'), "1\ntwo\n3\n")

    def test_if_block_with_else_if(self):
        src = "x = 5\nif x > 10\n    print 1\nelse if x > 3\n    print 2\nelse\n    print 3"
        self.assertEqual(run(src), "2\n")

    def test_inline_if_then_else(self):
        self.assertEqual(run("x = 1\nif x == 1 then print 'one' else print 'other'"), "one\n")

    def test_implicit_return_through_if(self):
        src = "fn f(x int) str\n    if x > 0\n        'pos'\n    else\n        'neg'\nprint f(1), f(-1)"
        self.assertEqual(run(src), "pos neg\n")

    def test_while_break_continue(self):
        src = "i = 0\nwhile true\n    i += 1\n    if i % 2 == 0 then continue\n    if i > 7 then break\n    print i"
        self.assertEqual(run(src), "1\n3\n5\n7\n")

    def test_short_circuit(self):
        src = "fn boom() bool\n    fail 'evaluated'\nxs: [int] = []\nprint len(xs) > 0 and boom(), len(xs) == 0 or boom()"
        self.assertEqual(run(src), "False True\n")

    def test_record_with_methods(self):
        src = (
            "type Point(x int, y int = 0)\n"
            "    fn norm2() int = .x * .x + .y * .y\n"
            "    fn moved(dx int) Point = Point(.x + dx, .y)\n"
            "p = Point(3, 4)\nprint p.norm2(), p.moved(1), Point(1), p == Point(3, 4)"
        )
        self.assertEqual(run(src), "25 Point(x=4, y=4) Point(x=1, y=0) True\n")

    def test_record_block_style_and_fresh_default(self):
        src = "type Bag\n    items [int] = []\n    fn add(x int)\n        .items.append(x)\nb = Bag()\nb.add(1)\nprint Bag().items, b.items"
        self.assertEqual(run(src), "[] [1]\n")

    def test_records_are_references(self):
        src = "type C(n int)\nfn bump(c C)\n    c.n += 1\nc = C(1)\nbump(c)\nbump(c)\nprint c.n"
        self.assertEqual(run(src), "3\n")

    def test_sum_type_match(self):
        src = (
            "type Color = Red | Green | Rgb(r int, g int, b int)\n"
            "fn name(c Color) str = match c\n"
            "    Red -> 'red'\n"
            "    Rgb(r, _, _) if r > 200 -> 'reddish'\n"
            "    Rgb(r, g, b) -> '#{r}{g}{b}'\n"
            "    _ -> 'other'\n"
            "print name(Red), name(Rgb(250, 0, 0)), name(Rgb(1, 2, 3)), name(Green())\n"
            "print Rgb(1, 2, 3)"
        )
        self.assertEqual(run(src), "red reddish #123 other\nRgb(r=1, g=2, b=3)\n")

    def test_recursive_sum_type(self):
        src = (
            "type Tree = Leaf | Node(l Tree, v int, r Tree)\n"
            "fn insert(t Tree, v int) Tree = match t\n"
            "    Leaf -> Node(Leaf, v, Leaf)\n"
            "    Node(l, x, r) -> if v < x then Node(insert(l, v), x, r) else Node(l, x, insert(r, v))\n"
            "fn walk(t Tree) [int] = match t\n"
            "    Leaf -> []\n"
            "    Node(l, x, r) -> walk(l) + [x] + walk(r)\n"
            "t = Leaf\nfor v in [5, 2, 8, 1, 9]\n    t = insert(t, v)\nprint walk(t)"
        )
        self.assertEqual(run(src), "[1, 2, 5, 8, 9]\n")

    def test_match_literals_tuples_and_lists(self):
        src = (
            "fn fb(i int) str = match (i % 3, i % 5)\n"
            "    (0, 0) -> 'FizzBuzz'\n"
            "    (0, _) -> 'Fizz'\n"
            "    (_, 0) -> 'Buzz'\n"
            "    _ -> str(i)\n"
            "fn shape(xs [int]) str = match xs\n"
            "    [] -> 'empty'\n"
            "    [x] -> 'one {x}'\n"
            "    [x, *rest] -> 'many {x} {rest}'\n"
            "fn word(s str) int = match s\n"
            "    'a' | 'b' -> 1\n"
            "    _ -> 0\n"
            "print fb(3), fb(5), fb(15), fb(7)\n"
            "print shape([]), shape([4]), shape([1, 2, 3])\n"
            "print word('b'), word('z')"
        )
        self.assertEqual(run(src), "Fizz Buzz FizzBuzz 7\nempty one 4 many 1 [2, 3]\n1 0\n")

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

    def test_try_with_return_and_loops(self):
        src = (
            "fn first_bad(xs [str]) int\n"
            "    for i in 0..len(xs) - 1\n"
            "        try\n"
            "            int(xs[i])\n"
            "            if i > 10 then return -2\n"
            "        catch ValueError\n"
            "            return i\n"
            "    -1\n"
            "total = 0\n"
            "for s in ['1', 'x', '3']\n"
            "    try\n"
            "        total += int(s)\n"
            "        continue\n"
            "    catch ValueError\n"
            "        total += 100\n"
            "print first_bad(['1', '2', 'z']), first_bad(['1']), total\n"
            "try\n    fail 'outer'\ncatch e\n    print e"
        )
        self.assertEqual(run(src), "2 -1 104\nouter\n")

    def test_uncaught_kind_is_reraised(self):
        src = "try\n    try\n        xs = [1]\n        print xs[3]\n    catch KeyError\n        print 'no'\ncatch IndexError e\n    print 'outer:', e"
        self.assertEqual(run(src), "outer: list index out of range\n")

    def test_fail_raises_error(self):
        err = failure("fail 'nope {1 + 1}'")
        self.assertEqual(err, "t.sip:1: Error: nope 2\n    fail 'nope {1 + 1}'\n")

    def test_assert(self):
        self.assertIn("AssertionError: bad x", failure("x = 1\nassert x == 2, 'bad x'"))

    def test_not_found(self):
        src = "fn load() str\n    try read('/no/such/file')\n    catch NotFound -> 'missing'\nprint load()"
        self.assertEqual(run(src), "missing\n")

    def test_read_write(self):
        p = os.path.join(TMP, "rw.txt")
        self.assertEqual(run(f"write('{p}', 'a\\nb\\n')\nprint read('{p}').splitlines()"), "['a', 'b']\n")

    def test_string_methods(self):
        src = (
            "s = '  Hello, World  '\n"
            "print s.strip().lower(), s.strip().upper(), len(s), s.find('W'), s.count('l')\n"
            "print 'a,b,,c'.split(','), ' x  y '.split(), 'ab'.replace('b', 'cd') + '!' * 3\n"
            "print 'abc'[1], 'abcdef'[1:3], 'abcdef'[-2:], 'abc'[-1], 'hi' < 'ho', 'ell' in 'hello'\n"
            "print '42'.isdigit(), 'x1'.isalpha(), int(' 7 ') + 1, float('2.5') * 2, str(3) + str(1.5)\n"
            "print 'pre_x'.startswith('pre'), 'x.sip'.endswith('.sip'), '-'.join(['a', 'b'])"
        )
        self.assertEqual(run(src), (
            "hello, world HELLO, WORLD 16 9 3\n"
            "['a', 'b', '', 'c'] ['x', 'y'] acd!!!\n"
            "b bc ef c True True\n"
            "True False 8 5.0 31.5\n"
            "True True a-b\n"
        ))

    def test_list_methods(self):
        src = (
            "xs = [5, 3, 8]\nxs.append(1)\nxs.insert(0, 9)\n"
            "print xs, xs.pop(), xs.pop(0), xs, xs.index(8), 3 in xs\n"
            "ys = xs.copy()\nys.sort()\nxs.reverse()\nprint ys, xs, sorted(xs, reverse: true)\n"
            "print xs[-1], xs[1:], [0] * 3, [1, 2] + [3], [1, 2] == [1, 2], min(xs), max(xs)\n"
            "words = 'a b a c a b'.split()\nprint words.count().top(2), words.count('a')"
        )
        self.assertEqual(run(src), (
            "[9, 5, 3, 8, 1] 1 9 [5, 3, 8] 2 True\n"
            "[3, 5, 8] [8, 3, 5] [8, 5, 3]\n"
            "5 [3, 5] [0, 0, 0] [1, 2, 3] True 3 8\n"
            "[('a', 3), ('b', 2)] 3\n"
        ))

    def test_sort_is_stable_on_tuples_and_strings(self):
        src = "xs = [(2, 'b'), (1, 'z'), (2, 'a'), (1, 'y')]\nprint sorted(xs), sorted(['pear', 'apple', 'fig'])"
        self.assertEqual(run(src), "[(1, 'y'), (1, 'z'), (2, 'a'), (2, 'b')] ['apple', 'fig', 'pear']\n")

    def test_index_out_of_range(self):
        err = failure("xs = [1, 2]\n\nfn get(i int) int = xs[i]\nprint get(5)\n")
        self.assertEqual(err, "t.sip:3: IndexError: list index out of range\n    fn get(i int) int = xs[i]\n")

    def test_reductions_and_comprehensions(self):
        src = (
            "xs = [3, 1, 4, 1, 5, 9, 2, 6]\n"
            "print sum(x * x for x in xs if x % 2 == 1), avg(xs), min(x for x in xs), max(xs)\n"
            "print any(x > 8 for x in xs), all(x > 0 for x in xs), [x * 2 for x in 1..3]\n"
            "print [(a, b) for a in 1..3 for b in 1..3 if a < b]\n"
            "print list(zip([1, 2, 3], ['a', 'b'])), list(enumerate(['x', 'y']))"
        )
        self.assertEqual(run(src), (
            "117 3.875 1 9\n"
            "True True [2, 4, 6]\n"
            "[(1, 2), (1, 3), (2, 3)]\n"
            "[(1, 'a'), (2, 'b')] [(0, 'x'), (1, 'y')]\n"
        ))

    def test_tuples_unpacking_and_swap(self):
        src = "fn divmod2(a int, b int) (int, int) = (a / b, a % b)\nq, r = divmod2(17, 5)\na, b = 1, 2\na, b = b, a\nprint q, r, a, b"
        self.assertEqual(run(src), "3 2 2 1\n")

    def test_kwargs_colon_and_equals(self):
        src = "fn f(a int, b = 1, c = 2) = a + b * c\nprint f(1, b: 10), f(1, c=5), f(1)"
        self.assertEqual(run(src), "21 6 3\n")

    def test_interpolation_specs_and_braces(self):
        src = ("type T(v float)\n    fn show() str = '{.v:.1f} {{ok}}'\n"
               "print T(2.345).show(), '[{7:>4}|{'ab':<4}|{3:03d}|{2.5:8.2f}]'")
        self.assertEqual(run(src), "2.3 {ok} [   7|ab  |003|    2.50]\n")

    def test_python_habits_are_tolerated(self):
        src = (
            "def_ = 1\n"
            "fn f(x: int) -> int:\n"
            "    if x > 0:\n"
            "        return x\n"
            "    return -x\n"
            "type A(v int)\n"
            "    fn get(self) int = self.v\n"
            "print f(2), f(-1), True, A(5).get(), def_"
        )
        self.assertEqual(run(src), "2 1 True 5 1\n")

    def test_cache_memoizes(self):
        self.assertEqual(run("@cache\nfn fib(n int) int = if n < 2 then n else fib(n - 1) + fib(n - 2)\nprint fib(90)"),
                         "2880067194370816120\n")

    def test_globals_are_visible_in_functions(self):
        src = "LIMIT = 3\ncount = 0\nfn tick()\n    count += 1\nfor _ in 1..LIMIT\n    tick()\nprint count"
        self.assertEqual(run(src), "3\n")

    def test_main_becomes_cli(self):
        src = "fn main(name str, times = 1, loud = false, ratio = 0.5)\n    for _ in 1..times\n        print if loud then name.upper() else name, ratio"
        self.assertEqual(run(src, "ann", "--times", "2", "--loud", "--ratio", "2"), "ANN 2.0\nANN 2.0\n")
        r = proc(src, ["--times", "x", "ann"])
        self.assertEqual(r.returncode, 2)
        self.assertIn("--times", r.stderr)

    def test_print_command_forms(self):
        src = "type T(v int)\n    fn show()\n        print .v\nprint [1, 2]\nprint\nprint 'a', 'b'\nT(3).show()"
        self.assertEqual(run(src), "[1, 2]\n\na b\n3\n")

    def test_input(self):
        r = proc("name = input('? ')\nprint 'hi', name", stdin="bob\n")
        self.assertEqual(r.stdout, "? hi bob\n")

    def test_utf8_strings(self):
        self.assertEqual(run("s = 'привет'\nprint s, s.upper() == s, s + '!'"), "привет True привет!\n")


class NilTest(unittest.TestCase):
    def test_optional_return_and_checks(self):
        src = (
            "fn find(xs [int], x int) int?\n"
            "    for i in 0..len(xs) - 1\n"
            "        if xs[i] == x then return i\n"
            "    nil\n"
            "i = find([5, 7, 9], 7)\nj = find([5, 7, 9], 4)\n"
            "print i, j, i == nil, j == nil, j is nil, i is not nil, i + 10"
        )
        self.assertEqual(run(src), "1 None False True True True 11\n")

    def test_linked_list(self):
        src = (
            "type Node(v int, next Node? = nil)\n"
            "fn length(n Node?) int = if n == nil then 0 else 1 + length(n.next)\n"
            "lst = Node(1, Node(2))\nlst.next.next = Node(3)\n"
            "print length(lst), length(nil), lst.next.v, Node(5)"
        )
        self.assertEqual(run(src), "3 0 2 Node(v=5, next=None)\n")

    def test_or_default_and_truthiness(self):
        src = ("name: str? = nil\nprint name or 'anon', name\nname = ''\nprint name or 'empty'\n"
               "name = 'bob'\nprint name or 'anon', '{name}!'\nif name then print 'set'")
        self.assertEqual(run(src), "anon None\nempty\nbob bob!\nset\n")

    def test_inferred_optional_variable(self):
        src = "best = nil\nfor x in [3, 9, 2]\n    if best == nil or x > best\n        best = x\nprint best"
        self.assertEqual(run(src), "9\n")

    def test_collections_of_optionals(self):
        src = ("xs: [int?] = [1, nil, 3]\nd: {str: int?} = {a: 1, b: nil}\n"
               "print xs, [x for x in xs if x != nil], d, (1, nil), [1, nil] == [1, nil]")
        self.assertEqual(run(src), "[1, None, 3] [1, 3] {'a': 1, 'b': None} (1, None) True\n")

    def test_dict_get_and_first(self):
        src = "d = {a: 1}\ne: [int] = []\nprint d.get('a'), d.get('z'), d.get('z') or 0, e.first(), [4, 5].first()"
        self.assertEqual(run(src), "1 None 0 None 4\n")

    def test_match_nil(self):
        src = ("fn label(x int?) str = match x\n    nil -> 'none'\n    0 -> 'zero'\n    n -> 'n={n}'\n"
               "print label(nil), label(0), label(5)")
        self.assertEqual(run(src), "none zero n=5\n")

    def test_augmented_assignment_on_optional(self):
        self.assertEqual(run("c: int? = 5\nc += 1\nprint c"), "6\n")

    def test_nil_error_at_runtime(self):
        err = failure("x: int? = nil\n\nprint x + 1")
        self.assertEqual(err, "t.sip:3: NilError: value is nil\n    print x + 1\n")
        self.assertIn("t.sip:3: caught", run("type N(next N? = nil)\nn = N()\ntry\n    print n.next.next\n"
                                             "catch NilError e\n    print 't.sip:3: caught', e"))

    def test_main_optional_flags(self):
        src = "fn main(name str? = nil, n int? = nil)\n    print name or 'nobody', n"
        self.assertEqual(run(src), "nobody None\n")
        self.assertEqual(run(src, "--name", "ann", "--n", "3"), "ann 3\n")

    def test_nil_type_errors(self):
        self.assertIn("int cannot be nil", errors_of("x: int = nil"))
        self.assertIn("int cannot be nil", errors_of("fn f(x int) int = x\nprint f(nil)"))
        self.assertIn("int is never nil", errors_of("x = 5\nprint x == nil"))
        self.assertIn("'is' works only with nil", errors_of("x = 1\nprint x is 1"))
        self.assertIn("declare its return type", errors_of("fn f(x int)\n    if x > 0 then return nil\n    1"))


class LambdaTest(unittest.TestCase):
    def test_map_filter_with_capture(self):
        src = "xs = [3, 1, 4]\nk = 10\nprint xs.map(fn(x) = x * k), xs.filter(fn(x) = x % 2 == 1), xs.map(fn(x) = '{x}!')"
        self.assertEqual(run(src), "[30, 10, 40] [3, 1] ['3!', '1!', '4!']\n")

    def test_function_types_and_closures(self):
        src = (
            "fn apply(f fn(int) int, x int) int = f(x)\n"
            "fn twice(f fn(int) int) fn(int) int = fn(x) = f(f(x))\n"
            "fn adder(n int) fn(int) int = fn(x) = x + n\n"
            "fn sq(x int) int = x * x\n"
            "inc = fn(x int) = x + 1\n"
            "fs = [adder(1), adder(2), sq]\n"
            "print apply(fn(x) = x + 1, 5), twice(adder(3))(10), apply(sq, 7), inc(41), [f(10) for f in fs]"
        )
        self.assertEqual(run(src), "6 16 49 42 [11, 12, 100]\n")

    def test_sorting_with_key_is_stable(self):
        src = (
            "words = ['pear', 'fig', 'banana', 'kiwi']\n"
            "print words.sort_by(fn(w) = len(w)), sorted(words, key: fn(w) = w[-1])\n"
            "print sorted(words, key: fn(w) = len(w), reverse: true), words\n"
            "ws = words.copy()\nws.sort(key: fn(w) = len(w))\n"
            "print ws, max(words, key: fn(w) = len(w)), min(words, key: fn(w) = len(w))"
        )
        self.assertEqual(run(src), (
            "['fig', 'pear', 'kiwi', 'banana'] ['banana', 'fig', 'kiwi', 'pear']\n"
            "['banana', 'pear', 'kiwi', 'fig'] ['pear', 'fig', 'banana', 'kiwi']\n"
            "['fig', 'pear', 'kiwi', 'banana'] banana fig\n"
        ))

    def test_group_by(self):
        self.assertEqual(run("print [3, 1, 4, 1, 5].group_by(fn(x) = x % 3)"), "{0: [3], 1: [1, 4, 1], 2: [5]}\n")

    def test_lambdas_in_records_methods_and_try(self):
        src = (
            "type Counter(step int)\n"
            "    fn adder() fn(int) int = fn(x) = x + .step\n"
            "    fn run(xs [int]) [int] = xs.map(.adder())\n"
            "type Btn(label str, on_click fn(str) str)\n"
            "fn safe(xs [str]) [int]\n"
            "    try\n"
            "        xs.map(fn(s) = int(s) * 2)\n"
            "    catch ValueError\n"
            "        [-1]\n"
            "b = Btn('ok', fn(s) = 'clicked ' + s)\n"
            "print Counter(5).run([1, 2]), b.on_click(b.label), safe(['1', '2']), safe(['x'])"
        )
        self.assertEqual(run(src), "[6, 7] clicked ok [2, 4] [-1]\n")

    def test_nested_lambdas_and_comprehensions(self):
        src = ("k = 100\nprint [1, 2].map(fn(a) = [10, 20].map(fn(b) = a + b + k))\n"
               "print [[1, 2], [3]].map(fn(r) = sum(x * x for x in r))")
        self.assertEqual(run(src), "[[111, 121], [112, 122]]\n[5, 9]\n")

    def test_locals_are_captured_by_value_globals_by_reference(self):
        src = ("n = 1\nf = fn(x int) = x + n\nn = 100\n"
               "fn g() int\n    m = 1\n    h = fn(x int) = x + m\n    m = 100\n    h(1)\nprint f(1), g()")
        self.assertEqual(run(src), "101 2\n")

    def test_lambda_type_errors(self):
        self.assertIn("write fn(x int) = ...", errors_of("f = fn(x) = x"))
        self.assertIn("takes 1 argument(s), got 2", errors_of("f = fn(x int) = x\nprint f(1, 2)"))
        self.assertIn("is not a function", errors_of("x = 1\nprint x(2)"))
        self.assertIn("wrap it", errors_of("print [1].map(str)"))


class TypeErrorTest(unittest.TestCase):
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

    def test_bad_indent(self):
        self.assertIn("indentation does not match", errors_of("if x\n    a\n  b"))

    def test_type_mismatch(self):
        self.assertIn("t.sip:2", errors_of("fn f(x int) int = x\nprint f('a')"))

    def test_mixed_list(self):
        self.assertIn("t.sip:1", errors_of("xs = [1, 'a']"))

    def test_unknown_name(self):
        self.assertIn("unknown name 'y'", errors_of("x = 1\nprint y"))

    def test_empty_list_needs_type(self):
        self.assertEqual(run("xs = []\nprint len(xs), [], {}"), "0 [] {}\n")  # пустое без контекста — [int]

    def test_unsupported_feature_is_named(self):
        self.assertIn("not supported by the native compiler", errors_of("xs = [1, 2]\nprint xs[::2]"))

    def test_method_calls_another_method(self):
        src = "type T(v int)\n    fn a() int = .v + 1\n    fn b() int = .a() * 2\nprint T(1).b()"
        self.assertEqual(run(src), "4\n")


def run_files(files: dict, main="main.sip", *args) -> subprocess.CompletedProcess:
    """Программа из нескольких файлов: {путь: текст}."""
    d = tempfile.mkdtemp(dir=TMP)
    for name, text in files.items():
        path = Path(d) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return cli("run", str(Path(d) / main), *args, cwd=d)


class ModuleTest(unittest.TestCase):
    def test_import_and_from_import(self):
        r = run_files({
            "geo.sip": "import math\ntype P(x float, y float)\n    fn len() float = math.hypot(.x, .y)\n"
                       "fn helper(x int) int = x * 2\nORIGIN = P(0, 0)\nfn main()\n    print \"no\"\n",
            "lib/strs.sip": "fn shout(s str) str = s.upper() + \"!\"\n",
            "main.sip": "import geo\nfrom geo import P as Point\nimport lib.strs as S\nfrom lib.strs import shout\n"
                        "fn helper(x int) int = x + 1\n"
                        "print geo.P(3, 4).len(), Point(6, 8).len(), geo.ORIGIN, geo.helper(5), helper(5)\n"
                        "print S.shout(\"a\"), shout(\"b\")\n",
        })
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "5.0 10.0 P(x=0.0, y=0.0) 10 6\nA! B!\n")

    def test_errors_point_into_module(self):
        r = run_files({"m.sip": "fn ok() int = 1\nfn bad(xs [int]) int = xs[5]\n",
                       "main.sip": "import m\nprint m.ok()\nprint m.bad([1])\n"})
        self.assertEqual(r.returncode, 1)
        self.assertIn("m.sip:2: IndexError", r.stderr)
        r = run_files({"m.sip": "fn f() int = \"x\"\n", "main.sip": "import m\nprint m.f()\n"})
        self.assertIn("m.sip:1", r.stderr)

    def test_import_errors(self):
        self.assertIn("module 'nope' not found", run_files({"main.sip": "import nope\n"}).stderr)
        r = run_files({"a.sip": "import b\n", "b.sip": "import a\n", "main.sip": "import a\n"})
        self.assertIn("circular import", r.stderr)
        r = run_files({"m.sip": "x = 1\n", "main.sip": "from m import y\n"})
        self.assertIn("module 'm' has no 'y'", r.stderr)
        self.assertIn("module 'math' has no 'foo'", errors_of("print math.foo(1)"))


class StdlibTest(unittest.TestCase):
    def test_math(self):
        src = ("from math import sqrt, floor\nprint sqrt(16), floor(2.7), math.ceil(2.1), math.gcd(12, 18), "
               "math.inf, math.log(8, 2), math.pi > 3, math.pow(2, 10), math.isnan(math.nan)")
        self.assertEqual(run(src), "4.0 2 3 6 inf 3.0 True 1024.0 True\n")
        self.assertIn("ValueError: math domain error", failure("print math.sqrt(-1)"))
        self.assertIn("needs a number", errors_of('print math.sqrt("x")'))

    def test_random_and_time(self):
        src = ("random.seed(1)\na = [random.randint(1, 6) for _ in 1..20]\nrandom.seed(1)\n"
               "b = [random.randint(1, 6) for _ in 1..20]\nprint a == b, all(1 <= x and x <= 6 for x in a)\n"
               "xs = [1, 2, 3]\nrandom.shuffle(xs)\nprint sorted(xs), random.choice([7]), 0.0 <= random.random() < 1.0\n"
               "t = time.perf_counter()\ntime.sleep(0.01)\nprint time.perf_counter() - t >= 0.01, time.time() > 1e9")
        self.assertEqual(run(src), "True True\n[1, 2, 3] 7 True\nTrue True\n")


class JsonTest(unittest.TestCase):
    TYPES = ("type Addr(city str, zip str? = nil)\n"
             "type User(name str, age int, tags [str] = [], addr Addr? = nil)\n"
             "type Shape = Circle(r float) | Dot\n")

    def test_parse_into_types(self):
        src = self.TYPES + (
            'us: [User] = json.parse("[{{\\"name\\": \\"Ann\\", \\"age\\": 3, \\"addr\\": {{\\"city\\": \\"Rome\\"}}, '
            '\\"x\\": [1, {{}}]}}]")\n'
            'print us\n'
            'm: {str: [int]} = json.parse(" {{\\"a\\": [1, 2]}} ")\n'
            's: [Shape] = json.parse("[{{\\"type\\": \\"Circle\\", \\"r\\": 2}}, {{\\"type\\": \\"Dot\\"}}]")\n'
            'u: str = json.parse("\\"\\\\u00e9\\\\ud83d\\\\ude00\\"")\n'
            'print m, s, u')
        self.assertEqual(run(src), "[User(name='Ann', age=3, tags=[], addr=Addr(city='Rome', zip=None))]\n"
                                   "{'a': [1, 2]} [Circle(r=2.0), Dot()] é😀\n")

    def test_stringify_like_python(self):
        src = self.TYPES + (
            'print json.stringify([User("Ann", 3, ["x"]), User("Bob", 4, addr: Addr("Рим"))])\n'
            'print json.stringify({1: [1.5, 1e20]}), json.stringify("q\\"\\n\\u0001"), json.stringify([nil, 1])\n'
            'print json.stringify({"a": [1, 2], "b": []}, indent: 2)\n'
            'print json.stringify([Circle(1), Dot()])')
        self.assertEqual(run(src), '[{"name": "Ann", "age": 3, "tags": ["x"], "addr": null}, '
                                   '{"name": "Bob", "age": 4, "tags": [], "addr": {"city": "Рим", "zip": null}}]\n'
                                   '{"1": [1.5, 1e+20]} "q\\"\\n\\u0001" [null, 1]\n'
                                   '{\n  "a": [\n    1,\n    2\n  ],\n  "b": []\n}\n'
                                   '[{"type": "Circle", "r": 1.0}, {"type": "Dot"}]\n')

    def test_read_write_roundtrip(self):
        path = os.path.join(TMP, "u.json")
        src = self.TYPES + (
            f'us = [User("Ann", 3, ["a", "b"], Addr("X", "1"))]\njson.write("{path}", us)\n'
            f'fn load(p str) [User] = json.read(p)\nprint load("{path}") == us')
        self.assertEqual(run(src), "True\n")
        self.assertTrue(Path(path).read_text().startswith('[\n  {\n    "name": "Ann"'))

    def test_errors(self):
        def err(text):
            src = self.TYPES + f'try\n    us: [User] = json.parse("{text}")\n    print us\ncatch ParseError e\n    print e'
            return run(src).strip()
        self.assertEqual(err('[{{\\"name\\": 1, \\"age\\": 2}}]'),
                         "JSON $[0].name: expected string, got number (line 1, column 11)")
        self.assertEqual(err('[{{\\"name\\": \\"a\\"}}]'), "JSON $[0]: missing field 'age'")
        self.assertEqual(err('[{{\\"name\\": \\"a\\", \\"age\\": 1.5}}]'),
                         "JSON $[0].age: expected int, got float (line 1, column 22)")
        self.assertEqual(err("[1, 2"), "JSON $[0]: expected object, got number (line 1, column 2)")
        self.assertEqual(err("[] x"), "invalid JSON: extra data after the value (line 1, column 4)")
        self.assertIn("cannot infer the result type", errors_of('x = json.parse("1")\nprint x'))
        self.assertIn("needs the type from the context", errors_of('c = json.parse("1")\nprint c["a"]'))
        self.assertIn("cannot be read from JSON", errors_of('f: fn(int) int = json.parse("1")'))


class CsvTest(unittest.TestCase):
    def setUp(self):
        self.path = os.path.join(TMP, "emp.csv")
        Path(self.path).write_bytes(b'name,dept,salary,age\nAnn,dev,100.5,31\n"Smith, Bob",ops,80,\n\n'
                                    b'"Multi\nline ""q""",dev,120,40\r\n')

    def test_read_as_dicts_and_records(self):
        src = (f'rows = csv.read("{self.path}")\nprint rows[1], len(rows)\n'
               "type Emp(name str, dept str, salary float, age int? = nil, team str = \"core\")\n"
               f'emps: [Emp] = csv.read("{self.path}")\nfor e in emps\n    print e\n'
               'raw: [[str]] = csv.parse("a;b\\n1;\\"x;y\\"\\n", delimiter: ";")\nprint raw')
        self.assertEqual(run(src),
                         "{'name': 'Smith, Bob', 'dept': 'ops', 'salary': '80', 'age': ''} 3\n"
                         "Emp(name='Ann', dept='dev', salary=100.5, age=31, team='core')\n"
                         "Emp(name='Smith, Bob', dept='ops', salary=80.0, age=None, team='core')\n"
                         "Emp(name='Multi\\nline \"q\"', dept='dev', salary=120.0, age=40, team='core')\n"
                         "[['a', 'b'], ['1', 'x;y']]\n")

    def test_write(self):
        out = os.path.join(TMP, "out.csv")
        src = ("type Emp(name str, salary float, age int?)\n"
               f'csv.write("{out}", [Emp("A, B", 1.5, nil), Emp("C\\"", 2.0, 30)])\nprint read("{out}") == '
               '"name,salary,age\\r\\n\\"A, B\\",1.5,\\r\\n\\"C\\"\\"\\",2.0,30\\r\\n"\n'
               f'csv.write("{out}", [[1, 2], [3, 4]], delimiter: "\\t")\nprint read("{out}") == "1\\t2\\r\\n3\\t4\\r\\n"')
        self.assertEqual(run(src), "True\nTrue\n")

    def test_errors(self):
        src = 'type E(name str, n int)\ntry\n    es: [E] = csv.parse("name,n\\nx,abc\\n")\ncatch ParseError e\n    print e'
        self.assertEqual(run(src), "CSV line 2, column 'n': invalid int: 'abc'\n")
        src = 'type E(name str, n int)\ntry\n    es: [E] = csv.parse("name\\nx\\n")\ncatch ParseError e\n    print e'
        self.assertEqual(run(src), "CSV has no column 'n' (needed for E)\n")


class _Handler(__import__("http.server").server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, body, ctype="application/json"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("X-Test", "yes")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        import json
        import time
        if self.path.startswith("/users/"):
            i = int(self.path.split("/")[2])
            self.reply(200, json.dumps({"id": i, "name": f"user{i}"}))
        elif self.path.startswith("/slow"):
            time.sleep(0.3)
            self.reply(200, '"ok"')
        elif self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/users/7")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/auth":
            self.reply(200, self.headers.get("Authorization", ""), "text/plain")
        else:
            self.reply(404, "no", "text/plain")

    def do_POST(self):
        import json
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        self.reply(201, json.dumps({"got": body, "ctype": self.headers.get("Content-Type", "")}))


class HttpTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import threading
        from http.server import ThreadingHTTPServer
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_get_post(self):
        b = self.base
        src = (f'type User(id int, name str)\nBASE = "{b}"\nr = http.get("{{BASE}}/users/3")\n'
               'print r.status, r.ok, r.headers["content-type"], r.text\nu: User = r.json()\nprint u\n'
               'print http.get("{BASE}/redirect").url.endswith("/users/7")\n'
               'print http.post("{BASE}/p", json: User(1, "A")).text\n'
               'print http.post("{BASE}/p", body: "raw", headers: {"Content-Type": "text/plain"}).text\n'
               'print http.get("{BASE}/auth", headers: {"Authorization": "Bearer t"}, timeout: 5).text')
        self.assertEqual(run(src), '200 True application/json {"id": 3, "name": "user3"}\nUser(id=3, name=\'user3\')\n'
                                   'True\n{"got": "{\\"id\\": 1, \\"name\\": \\"A\\"}", "ctype": "application/json"}\n'
                                   '{"got": "raw", "ctype": "text/plain"}\nBearer t\n')

    def test_errors(self):
        b = self.base
        src = (f'try\n    http.get("{b}/nope")\ncatch HttpError e\n    print e\n'
               f'try\n    http.get("{b}/slow", timeout: 0.05)\ncatch IOError e\n    print "timeout"\n'
               'try\n    http.get("http://127.0.0.1:1/")\ncatch IOError e\n    print "refused"')
        self.assertEqual(run(src), f"HTTP 404 for {b}/nope\ntimeout\nrefused\n")

    def test_parallel_requests(self):
        src = (f'async fn get(u str) int = http.get(u).status\n'
               f'async fn main()\n    t = time.perf_counter()\n'
               f'    rs = await all(get("{self.base}/slow") for _ in 1..10)\n'
               f'    print rs.count(200), time.perf_counter() - t < 2.0')
        self.assertEqual(run(src), "10 True\n")


class AsyncTest(unittest.TestCase):
    def test_tasks(self):
        src = ("async fn slow(i int) int\n    time.sleep(0.2)\n    i * 10\n"
               "async fn twice(i int) int = (await slow(i)) + 1\n"
               "async fn add(xs [int])\n    xs.append(len(xs))\n"
               "async fn main()\n    t0 = time.perf_counter()\n    rs = await all(slow(i) for i in 0..7)\n"
               "    print rs, time.perf_counter() - t0 < 1.0\n"
               "    t = slow(1)\n    print await t, await t, t\n"
               "    print await all([twice(i) for i in 0..2]), await all(i * i for i in 0..3)\n"
               "    xs = []\n    await all(add(xs) for _ in 1..50)\n    print sorted(xs) == list(0..49)")
        self.assertEqual(run(src), "[0, 10, 20, 30, 40, 50, 60, 70] True\n10 10 <task>\n[1, 11, 21] [0, 1, 4, 9]\nTrue\n")

    def test_errors(self):
        src = ('async fn boom(i int) int\n    if i == 3 then fail "task {i} failed"\n    i\n'
               'async fn main()\n    try\n        await all(boom(i) for i in 0..5)\n    catch e\n        print e\n'
               '    print await boom(3)')
        r = proc(src)
        self.assertEqual(r.stdout, "task 3 failed\n")
        self.assertIn("t.sip:2: Error: task 3 failed", r.stderr)
        self.assertIn("await is only allowed inside an async fn", errors_of("async fn f() int = 1\nprint await f()"))
        self.assertIn("'g' is not async", errors_of("async fn f() int = 1\nfn g() int = await f()"))
        self.assertIn("needs a list of tasks", errors_of("async fn main()\n    print await all(5)"))


class BlockLambdaTest(unittest.TestCase):
    def test_multiline_lambdas(self):
        src = ("xs = [3, 1, 2]\nys = xs.map(fn(x)\n    y = x * 2\n    if y > 4 then return 0\n    y + 1\n)\nprint ys\n"
               "f = fn(a int, b int)\n    s = a + b\n    s * s\nprint f(1, 2)\n"
               "print sorted([\"bb\", \"a\", \"ccc\"], key: fn(w)\n    n = len(w)\n    -n\n)\n"
               "fn apply(g fn(int) int, x int) int = g(x)\n"
               "print apply(fn(v)\n    try\n        [1, 2][v]\n    catch IndexError\n        -1\n, 5)\n"
               "fn mk(n int) fn(int) int = fn(x)\n    if x > n then return n\n    x\nprint mk(3)(5), mk(3)(1)\n"
               "print [[1, 2], [3]].map(fn(row)\n    row.map(fn(v)\n        w = v * 10\n        w + 1\n    )\n)\n"
               "fn run()\n    k = 10\n    h = fn(x int)\n        print \"got\", x + k\n    h(1)\nrun()")
        self.assertEqual(run(src), "[0, 3, 5]\n9\n['ccc', 'bb', 'a']\n-1\n3 1\n[[11, 21], [31]]\ngot 11\n")

    def test_errors(self):
        self.assertIn("cannot change the outer variable 'k'",
                      errors_of("fn g()\n    k = 1\n    h = fn()\n        k += 1\n    h()"))
        self.assertIn("named fn cannot be declared inside a lambda",
                      errors_of("xs = [1]\nxs.map(fn(x)\n    fn inner() int = 1\n    inner()\n)"))
        self.assertIn("the lambda ended without returning a value",
                      failure("f = fn(x int)\n    if x > 0 then return x\nprint f(0)"))


class StarArgsTest(unittest.TestCase):
    def test_args_kwargs(self):
        src = ('fn total(*xs int) int = sum(xs)\nfn fmt(sep str, *parts str, end = "!") str = parts.join(sep) + end\n'
               'fn opts(name str, **kw int) str = "{name} {kw}"\n'
               'print total(), total(1), total(1, 2, 3), total(*[4, 5])\n'
               'print fmt("-", "a", "b"), fmt(", ", "x", end: "."), fmt("+")\n'
               'print opts("a"), opts("b", x: 1, y: 2), opts("c", **{"z": 9})\n'
               'type Bag(items [str])\n    fn add(*xs str)\n        .items.extend(xs)\n'
               'b = Bag([])\nb.add("p", "q")\nprint b')
        self.assertEqual(run(src), "0 1 6 9\na-b! x. !\na {} b {'x': 1, 'y': 2} c {'z': 9}\nBag(items=['p', 'q'])\n")

    def test_main_rest_args(self):
        src = 'fn main(prefix str, *nums int, twice = false)\n    for n in nums\n        print "{prefix}{if twice then n * 2 else n}"'
        self.assertEqual(run(src, ">", "1", "2", "--twice"), ">2\n>4\n")
        self.assertEqual(run(src, "-"), "")
        self.assertIn("usage: t PREFIX [NUMS...] [--twice]", run(src, "--help"))

    def test_errors(self):
        self.assertIn("needs the type of its items", errors_of("fn f(*xs) int = 1"))
        self.assertIn("no *args parameter", errors_of("fn f(x int) int = x\nprint f(*[1])"))
        self.assertIn("int and str do not match", errors_of('fn f(*xs int) int = len(xs)\nprint f(1, "a")'))


class WithTest(unittest.TestCase):
    SRC = ('log: [str] = []\ntype Res(name str, open bool = false)\n    fn enter() Res\n'
           '        log.append("enter {.name}")\n        .open = true\n        self\n'
           '    fn exit()\n        log.append("exit {.name}")\n        .open = false\n'
           'type Lock(n int)\n    fn exit()\n        log.append("unlock {.n}")\n')

    def test_enter_exit(self):
        src = self.SRC + (
            'fn find(xs [int]) int\n    with Res("f") as r\n        for x in xs\n'
            '            if x > 2 then return x * 10\n    -1\n'
            'with Res("a") as a, Lock(1)\n    log.append("body {a.open}")\nprint log\nlog.clear()\n'
            'try\n    with Res("b")\n        fail "boom"\ncatch e\n    log.append("caught {e}")\nprint log\nlog.clear()\n'
            'print find([1, 5]), find([1]), log\nlog.clear()\n'
            'for i in 1..3\n    with Lock(i)\n        if i == 2 then break\nprint log')
        self.assertEqual(run(src), "['enter a', 'body True', 'unlock 1', 'exit a']\n"
                                   "['enter b', 'exit b', 'caught boom']\n"
                                   "50 -1 ['enter f', 'exit f', 'enter f', 'exit f']\n['unlock 1', 'unlock 2']\n")

    def test_errors(self):
        self.assertIn("with needs a record with exit()", errors_of("with 5 as x\n    pass"))
        self.assertIn("must take no arguments",
                      errors_of("type T(n int)\n    fn exit(x int)\n        pass\nwith T(1)\n    pass"))


class GenericsTest(unittest.TestCase):
    PROGRAM = """\
fn first[T](xs [T]) T = xs[0]

fn biggest[T](xs [T]) T
    best = xs[0]
    for x in xs
        if x > best then best = x
    best

fn pair[A, B](a A, b B) (B, A) = (b, a)

fn total[T](xs [T]) T = sum(xs)

type Box[T](v T)
    fn get() T = .v
    fn map[U](f fn(T) U) Box[U] = Box(f(.v))

type Opt[T] = Empty | Some(v T)
    fn or_else(d T) T = match self
        Some(v) -> v
        Empty -> d

type Tree[T] = Leaf | Node(l Tree[T], v T, r Tree[T])

fn insert[T](t Tree[T], x T) Tree[T] = match t
    Leaf -> Node(Leaf, x, Leaf)
    Node(l, v, r) -> if x < v then Node(insert(l, x), v, r) else Node(l, v, insert(r, x))

fn items[T](t Tree[T]) [T] = match t
    Leaf -> []
    Node(l, v, r) -> items(l) + [v] + items(r)

interface Shape
    fn area() float
    fn name() str

type Circle(r float)
    fn area() float = 3.0 * .r * .r
    fn name() str = "circle"

type Rect(w float, h float)
    fn area() float = .w * .h
    fn name() str = "rect"

fn sum_area[T: Shape](xs [T]) float = sum(x.area() for x in xs)

print first([3, 4]), first(["a", "b"]), biggest([3, 9, 2]), biggest(["x", "yy"])
print pair(1, "one"), total([1.5, 2.5]), total([1, 2, 3])
b = Box(41)
print b.get() + 1, b.map(fn(x) = "n{x}").get(), b
o: Opt[str] = Empty
print o.or_else("none"), Some(5).or_else(0)
t: Tree[int] = Leaf
for x in [5, 2, 8, 1]
    t = insert(t, x)
print items(t)
ws: Tree[str] = Leaf
for w in "pear apple fig".split()
    ws = insert(ws, w)
print items(ws)
shapes: [Shape] = [Circle(1.0), Rect(2.0, 3.0)]
for s in shapes
    print s.name(), s.area(), s
print sum_area([Circle(1.0), Circle(2.0)]), sum_area(shapes)
"""

    def test_generic_functions_types_and_interfaces(self):
        self.assertEqual(run(self.PROGRAM), (
            "3 a 9 yy\n('one', 1) 4.0 6\n42 n41 Box(v=41)\nnone 5\n[1, 2, 5, 8]\n['apple', 'fig', 'pear']\n"
            "circle 3.0 Circle(r=1.0)\nrect 6.0 Rect(w=2.0, h=3.0)\n15.0 9.0\n"))

    def test_explicit_args_json_equality(self):
        self.assertEqual(run("""\
type Box[T](v T)
type Opt[T] = Empty | Some(v T)

interface Shape
    fn area() float
    fn bigger(o Shape) bool

type Sq(s float)
    fn area() float = .s * .s
    fn bigger(o Shape) bool = .area() > o.area()

fn first[T](xs [T]) T? = if xs then xs[0] else nil

print Empty, Some(Box(Box(2))), Box(1) == Box(1), Box("a") == Box("b")
bs: [Box[int]] = json.parse("[{{\\"v\\": 1}}, {{\\"v\\": 5}}]")
print bs, json.stringify(Box([1, 2]))
a: Shape = Sq(2.0)
b: Shape = Sq(1.0)
print a.bigger(b), b.bigger(a), a == a, a == b
print first[int]([]), first(["z"]), first([1.5])
d = {k: Box(k) for k in ["x", "y"]}
print d["y"].v
"""), "Empty() Some(v=Box(v=Box(v=2))) True False\n[Box(v=1), Box(v=5)] {\"v\": [1, 2]}\n"
      "True False True False\nNone z 1.5\ny\n")

    def test_instances_get_own_lambdas_and_nested_fns(self):
        src = """\
@cache
fn ident[T](x T) T = x

fn apply_all[T](xs [T], f fn(T) T) [T]
    fn twice(x T) T = f(f(x))
    ys = xs.map(fn(x) = twice(x))
    ys.map(fn(y)
        z = f(y)
        return z
    )

type Stack[T](items [T] = [])
    fn push(x T)
        .items.append(x)
    fn pop() T = .items.pop()

fn group[K, V](xs [V], key fn(V) K) {K: [V]}
    out: {K: [V]} = {}
    for x in xs
        k = key(x)
        if k not in out then out[k] = []
        out[k].append(x)
    out

print apply_all([1, 2], fn(x) = x * 10), apply_all(["a"], fn(s) = s + "!"), ident(5), ident("x")
st = Stack[int]()
st.push(7)
ss: Stack[str] = Stack()
ss.push("q")
print st.pop(), ss.pop(), group([1, 2, 3, 4], fn(x) = x % 2 == 0)
"""
        self.assertEqual(run(src), "[1000, 2000] ['a!!!'] 5 x\n7 q {False: [1, 3], True: [2, 4]}\n")

    def test_dynamic_interface_values(self):
        src = """\
interface Named
    fn name() str
    fn greet(other str, n int) str

type Dog(nick str)
    fn name() str = "dog " + .nick
    fn greet(other str, n int) str = "woof " * n + other

type Animal = Cat(lives int) | Fish
    fn name() str = match self
        Cat(l) -> "cat {l}"
        Fish -> "fish"
    fn greet(other str, n int) str = "{self.name()} ignores {other}"

type Wrap[T](v T)
    fn name() str = "wrap {.v}"
    fn greet(other str, n int) str = "{.v}-{other}-{n}"

fn names[T: Named](xs [T]) [str] = [x.name() for x in xs]

zoo: [Named] = [Dog("rex"), Cat(9), Fish, Wrap(3)]
for a in zoo
    print a.greet("bob", 2)
print names(zoo), names([Cat(1), Fish])
maybe: Named? = nil
print maybe == nil
maybe = Dog("z")
d: {str: Named} = {a: Dog("x"), b: Fish}
print maybe.name(), d["b"].name(), d
"""
        self.assertEqual(run(src), (
            "woof woof bob\ncat 9 ignores bob\nfish ignores bob\n3-bob-2\n"
            "['dog rex', 'cat 9', 'fish', 'wrap 3'] ['cat 1', 'fish']\nTrue\n"
            "dog z fish {'a': Dog(nick='x'), 'b': Fish()}\n"))

    def test_errors(self):
        big = "fn big[T](xs [T]) T\n    b = xs[0]\n    for x in xs\n        if x > b then b = x\n    b\n"
        shape = "interface Shape\n    fn area() float\n"
        cases = [
            ("type P(x int)\n" + big + "print big([P(1)])", "T = P does not support comparison with <"),
            ("fn f[T](xs [T]) T = sum(xs)\nprint f([\"a\"])", "T = str does not support arithmetic"),
            ("fn f[T](xs [T]) {T: int} = xs.count()\nprint f([[1]])", "does not support use as a dict key"),
            ("fn o[T](xs [T]) T = i(xs)\nfn i[U](xs [U]) U = sorted(xs)[0]\ntype P(x int)\nprint o([P(1)])",
             "o(): T = P does not support comparison"),
            (shape + "type Sq(s float)\nfn f[T: Shape](xs [T]) float = 1.0\nprint f([Sq(1.0)])",
             "T = Sq is not a Shape: Sq has no method area()"),
            (shape + "type Sq(s float)\n    fn area() int = 1\nx: Shape = Sq(1.0)",
             "Sq.area() int does not match Shape.area() float"),
            ("fn f[T](x T) T = x + 1", "cannot apply '+' to T and int"),
            ("fn f[T](x T) T = x\nprint [1].map(f)", "generic function 'f' cannot be used as a value"),
            ("type Box[T](v T)\nfn g(b Box) int = 1", "type 'Box' needs 1 type argument(s), e.g. Box[int]"),
            ("type Box(v int)\nfn g(b Box[int]) int = 1", "type 'Box' takes no type arguments"),
            ("fn f[T](x T) float = x.area()", "T has no method 'area': give it a bound"),
            ("fn f[int](x int) int = x", "hides the type int"),
            ("fn f(x int) int = x\nprint f[int](1)", "f() has no type parameters"),
            ("interface I\n", "an interface needs at least one method"),
        ]
        for src, want in cases:
            with self.subTest(want=want):
                self.assertIn(want, errors_of(src))


class GcTest(unittest.TestCase):
    """Сборщик мусора: SIP_GC_MIN=0 собирает мусор на каждом новом блоке памяти."""

    def gc_run(self, src: str, gc: str = "0"):
        env = {**os.environ, "SIP_GC_MIN": gc, "SIP_GC_STATS": "1"}
        r = subprocess.run([build(src, "gc")], capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        m = re.search(r"sip gc: (\d+) collections, [\d.]+ s, peak heap ([\d.]+) MB", r.stderr)
        self.assertIsNotNone(m, r.stderr)
        return r.stdout, int(m.group(1)), float(m.group(2))

    STRESS = """\
type Node = Leaf(v int) | Pair(l Node, r Node)

type Person
    name str
    tags [str]

fn build(d int, v int) Node = if d == 0 then Leaf(v) else Pair(build(d - 1, v * 2), build(d - 1, v * 2 + 1))

fn total(n Node) int = match n
    Leaf(v) -> v
    Pair(l, r) -> total(l) + total(r)

keep = build(12, 1)
people = {}
for i in 0..2000 - 1
    people["p{i}"] = Person("name {i}", ["t{i}", "u{i}"])
words = []
check = 0
for round in 0..300 - 1
    junk = build(8, round)
    check += total(junk)
    s = ""
    for j in 0..50 - 1
        s = s + "{j},"
    parts = s.split(",")
    words.append(parts[round % 50])
    m = {}
    for j in 0..200 - 1
        m["k{j}"] = [j, j * 2]
    check += m["k7"][1]
    add = fn(x int) = x + round
    check += add(1)
print total(keep), check, len(words), words[299]
ok = 0
for i in 0..2000 - 1
    p = people["p{i}"]
    if p.name == "name {i}" and p.tags[1] == "u{i}" then ok += 1
print ok
"""

    def test_live_data_survives_collections(self):
        out, n, peak = self.gc_run(self.STRESS)
        self.assertEqual(out, "25163776 2949130950 300 49\n2000\n")
        self.assertGreater(n, 10)
        self.assertLess(peak, 12)

    def test_off_keeps_everything(self):
        out, n, peak = self.gc_run(self.STRESS, gc="100000")
        self.assertEqual(out, "25163776 2949130950 300 49\n2000\n")
        self.assertEqual(n, 0)
        self.assertGreater(peak, 15)

    def test_threads(self):
        out, n, _ = self.gc_run("""\
import time
async fn work(i int) int
    total = 0
    for r in 0..200
        parts = []
        for j in 0..20
            parts.append("w{i}-{j}")
        s = ",".join(parts)
        time.sleep(0.0001)
        total += len(s.split(","))
    total

async fn main()
    rs = await all(work(i) for i in 0..15)
    print sum(rs), len(rs)
""")
        self.assertEqual(out, "67536 16\n")
        self.assertGreater(n, 10)

    def test_errors_and_sort_under_gc(self):
        out, n, _ = self.gc_run("""\
fn risky(i int) str
    if i % 7 == 0 then fail "bad {i}"
    "ok {i}"

msgs = []
for i in 0..3000
    try
        msgs.append(risky(i))
    catch e
        msgs.append(e)
xs = [["{i * 37 % 1001}"] for i in 0..20000]
ys = sorted(xs, key: fn(x [str]) = x[0] + "!")
print len(msgs), msgs[7], msgs[8], ys[0][0], ys[-1][0]
""")
        self.assertEqual(out, "3001 bad 7 ok 8 0 999\n")
        self.assertGreater(n, 0)


class ExamplesTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def ex(self, name, *args):
        r = cli("run", str(ROOT / "examples" / f"{name}.sip"), *args)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_all_examples_check(self):
        files = sorted(str(p) for p in (ROOT / "examples").glob("*.sip"))
        r = cli("check", *files)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_fizzbuzz(self):
        out = self.ex("fizzbuzz").split()
        self.assertEqual(out[:5], ["1", "2", "Fizz", "4", "Buzz"])
        self.assertEqual(out[14], "FizzBuzz")

    def test_simple_programs(self):
        self.assertEqual(self.ex("sum_even_squares"), "56\n")
        self.assertEqual(self.ex("fib"), "23416728348467685\n")
        self.assertEqual(self.ex("binary_search"), "3 -1\n")
        self.assertEqual(self.ex("user"), "Hello, Ann! True\n")
        self.assertEqual(self.ex("shapes"), "Circle(r=1.0): 3.14\nRect(w=2.0, h=3.0): 6.00\nTriangle(b=4.0, h=5.0): 10.00\n")

    def test_people(self):
        self.assertEqual(self.ex("people"), "Ann, Cid\nCid\nBob: no email\n")
        self.assertEqual(self.ex("people", "--who", "Ann").splitlines()[-1], "Ann: ann@example.com")
        self.assertEqual(self.ex("people", "--who", "Zed").splitlines()[-1], "Zed: not found")

    def test_greet(self):
        self.assertEqual(self.ex("greet", "Bob", "--times", "2"), "Hello, Bob!\nHello, Bob!\n")

    def test_word_freq(self):
        p = self.d / "w.txt"
        p.write_text("the cat the dog the end cat")
        self.assertEqual(self.ex("word_freq", str(p), "--n", "2"), "the: 3\ncat: 2\n")

    def test_csv_groupby(self):
        p = self.d / "s.csv"
        p.write_text("name,dept,salary\nann,eng,100\nbob,eng,120\ncat,ops,90\n")
        self.assertEqual(self.ex("csv_groupby", str(p)), "eng: 110\nops: 90\n")

    def test_todo_json(self):
        p = str(self.d / "todo.json")
        self.ex("todo", p, "--add", "a")
        self.assertEqual(self.ex("todo", p, "--add", "b", "--done", "1"), "1. [x] a\n2. [ ] b\n")

    def test_report_imports_module(self):
        self.assertEqual(self.ex("report"), "Circle(r=1.0): 3.14\nRect(w=2.0, h=3.0): 6.00\nCircle(r=0.5): 0.79\n"
                                            "total: 9.93\n")

    def test_config(self):
        p = self.d / "c.conf"
        p.write_text("# test\nport = 9000\n")
        self.assertEqual(self.ex("config", str(p)), "host = localhost\nport = 9000\ndebug = false\n")
        self.assertEqual(self.ex("config", str(self.d / "none")), "host = localhost\nport = 8080\ndebug = false\n")

    def test_build_writes_executable(self):
        out = self.d / "fb"
        r = cli("build", str(ROOT / "examples" / "fizzbuzz.sip"), "-o", str(out))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(subprocess.run([str(out)], capture_output=True, text=True).stdout.split()[2], "Fizz")

    def test_cli_compile_error(self):
        p = self.d / "bad.sip"
        p.write_text("print (1\n")
        r = cli("run", str(p))
        self.assertEqual(r.returncode, 1)
        self.assertIn("bad.sip:", r.stderr)

    def test_runtime_error_exit_code(self):
        p = self.d / "boom.sip"
        p.write_text("xs = [1]\nprint xs[2]\n")
        r = cli("run", str(p))
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stderr, f"{p}:2: IndexError: list index out of range\n    print xs[2]\n")


if __name__ == "__main__":
    unittest.main()
