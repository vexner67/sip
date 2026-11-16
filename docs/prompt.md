# Sip

Sip is Python with less noise, statically typed, compiled to native code (via C). Differences from Python:

- Blocks by indentation, no `:`. `fn name(a int, b = 1) T` declares a function; its last expression is returned. One-expression body: `fn f(x int) int = x * 2`. Parameter types are required unless the default is a literal; the return type is inferred if omitted.
- Types: `int` (64-bit) `float str bool`, `[T]` list, `{K: V}` dict, `{T}` set (`{1, 2}`, `set()`), `(A, B)` tuple, `T?` may be nil, `fn(int, str) bool` function. Variables are inferred; an empty collection needs a type: `xs: [int] = []`.
- `nil`: `x == nil`, `x is not nil`, `name or "anon"`, `match x` arm `nil -> ...`. A `T?` used as a `T` is checked at runtime (`NilError`). `d.get(k)` and `xs.first()` give `T?`.
- Lambda: `fn(x) = x * 2`; parameter types come from context or are written: `fn(x int) = x + 1`. Named functions are values too: `xs.map(sq)`. A nested `fn` block is a closure too.
- `if c then a elif d then b else e` is an expression. Any block body may be one statement on the same line: `if c then return x`.
- Ranges are inclusive: `1..100`. `/` on two ints is floor division; `%` follows Python.
- Strings interpolate: `"Hi {name} {x:.2f} {n:>5}"`; `{{` is a literal brace. `print a, b` needs no parentheses. Strings are UTF-8 bytes.
- `true false nil`. Bare-name dict keys are strings: `{host: "x"}`. `a | b` merges dicts. Dicts keep insertion order.
- `for k, v in d` iterates a dict's items.
- Record: `type User(name str, age int = 0)` with indented `fn` methods; `.age` means `self.age`. Records and lists are references.
- Sum type: `type Tree = Leaf | Node(l Tree, v int, r Tree)`; a fieldless variant is a value: `Leaf`. `match x` with arms `Node(l, v, r) -> expr`, `_ -> expr`, guards `P if cond -> expr`, literals, tuples, `[x, *rest]`, `A | B`.
- Errors: `try expr` or a `try` block, then `catch Kind e -> expr` or a block; `catch e` catches all; `e` is the message (str). `fail "msg"` raises. Kinds: `NotFound`, `ParseError`, `ValueError`, `IndexError`, `KeyError`, `ZeroDivisionError`, `AssertionError`, `IOError`, `NilError`, `HttpError`.
- Keyword args: `f(x, reverse: true)`. `sorted(xs, key: f)`, `xs.sort(key: f)`, `min(xs, key: f)`.
- `fn main(path str, n = 3)`: parameters become CLI args (`--n 5`).
- Builtins: `print len str int float bool abs min max sum avg any all sorted list count zip enumerate round read write input exit`, `@cache`, `pi`.
- Methods: str `lower upper strip split splitlines find count replace startswith endswith isdigit isalpha join`; list `append pop insert extend sort reverse copy index count join sum avg top map filter sort_by group_by first`; dict `get keys values items copy top pop update clear`; set `add remove discard union intersection difference`. `xs.count()` is a `{T: int}` counter; `.top(n)` gives the n most common `(key, count)`.
- `import geo` / `from lib.geo import area` loads `geo.sip` next to the file. Built-in modules need no import: `math random time json csv http`.
- JSON and CSV read straight into the expected type: `users: [User] = json.read(p)`, `fn load(p str) [Row] = csv.read(p)`; `json.stringify(x, indent: 2)`, `json.write(p, x)`, `csv.write(p, rows)`. Plain `csv.read(p)` gives `[{str: str}]`.
- `r = http.get(url, timeout: 5, headers: {...})`: `r.status r.ok r.text r.headers`, `u: User = r.json()`; `http.post(url, json: x)`. 4xx/5xx raise `HttpError`.
- `async fn f(u str) int`; calling it makes a task; `await f(u)`; `await all(f(u) for u in urls)` runs them concurrently, in order. `await` only inside `async fn` (`async fn main` is fine).
- Not available: multi-line lambdas, `with`, `*args`.
