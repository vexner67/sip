# Sip

Sip is Python with less noise, statically typed, compiled to native code (via C). Differences from Python:

- Blocks by indentation, no `:`. `fn name(a int, b = 1) T` declares a function; its last expression is returned. One-expression body: `fn f(x int) int = x * 2`. Parameter types are required unless the default is a literal; the return type is inferred if omitted.
- Types: `int` (64-bit) `float str bool`, `[T]` list, `{K: V}` dict, `(A, B)` tuple. Variables are inferred; an empty collection needs a type: `xs: [int] = []`.
- `if c then a elif d then b else e` is an expression. Any block body may be one statement on the same line: `if c then return x`.
- Ranges are inclusive: `1..100`. `/` on two ints is floor division; `%` follows Python.
- Strings interpolate: `"Hi {name} {x:.2f} {n:>5}"`; `{{` is a literal brace. `print a, b` needs no parentheses. Strings are UTF-8 bytes.
- `true false`. Bare-name dict keys are strings: `{host: "x"}`. `a | b` merges dicts. Dicts keep insertion order.
- `for k, v in d` iterates a dict's items.
- Record: `type User(name str, age int = 0)` with indented `fn` methods; `.age` means `self.age`. Records and lists are references.
- Sum type: `type Tree = Leaf | Node(l Tree, v int, r Tree)`; a fieldless variant is a value: `Leaf`. `match x` with arms `Node(l, v, r) -> expr`, `_ -> expr`, guards `P if cond -> expr`, literals, tuples, `[x, *rest]`, `A | B`.
- Errors: `try expr` or a `try` block, then `catch Kind e -> expr` or a block; `catch e` catches all; `e` is the message (str). `fail "msg"` raises. Kinds: `NotFound`, `ParseError`, `ValueError`, `IndexError`, `KeyError`, `ZeroDivisionError`, `AssertionError`, `IOError`.
- Keyword args: `f(x, reverse: true)`.
- `fn main(path str, n = 3)`: parameters become CLI args (`--n 5`).
- Builtins: `print len str int float bool abs min max sum avg any all sorted list count zip enumerate round read write input exit`, `@cache`, `pi`.
- Methods: str `lower upper strip split splitlines find count replace startswith endswith isdigit isalpha join`; list `append pop insert extend sort reverse copy index count join sum avg top`; dict `get keys values items copy top`. `xs.count()` is a `{T: int}` counter; `.top(n)` gives the n most common `(key, count)`.
- Not available: `nil`/optional types, lambdas, nested functions, async, imports, sets.
