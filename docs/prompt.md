# Sip

Sip is Python with less noise, statically typed, compiled to native code (via C). Differences from Python:

- Blocks by indentation, no `:`. `fn name(a int, b = 1) T` declares a function; its last expression is returned. One-expression body: `fn f(x int) int = x * 2`. Parameter types are required unless the default is a literal; the return type is inferred if omitted.
- Types: `int` (64-bit; overflow raises `OverflowError`) `float str bool`, `[T]` list, `{K: V}` dict, `{T}` set (`{1, 2}`, `set()`), `(A, B)` tuple, `T?` may be nil, `fn(int, str) bool` function. Variables are inferred; an empty collection needs a type: `xs: [int] = []`.
- `nil`: `x == nil`, `x is not nil`, `name or "anon"`, `match x` arm `nil -> ...`. A `T?` used as a `T` is checked at runtime (`NilError`). `d.get(k)` and `xs.first()` give `T?`.
- Lambda: `fn(x) = x * 2`; parameter types come from context or are written: `fn(x int) = x + 1`. Named functions are values too: `xs.map(sq)`. A nested `fn` block is a closure too. A lambda whose line ends after `fn(x)` takes the indented block below as its body (works inside parentheses; `return` allowed).
- `if c then a elif d then b else e` is an expression. Any block body may be one statement on the same line: `if c then return x`.
- Ranges are inclusive: `1..100`. `/` on two ints is floor division; `%` follows Python.
- Strings interpolate: `"Hi {name} {x:.2f} {n:>5}"`; `{{` is a literal brace. `print a, b` needs no parentheses. Strings are UTF-8 bytes.
- `true false nil`. Bare-name dict keys are strings: `{host: "x"}`. `a | b` merges dicts. Dicts keep insertion order.
- `for k, v in d` iterates a dict's items.
- Record: `type User(name str, age int = 0)` with indented `fn` methods; `.age` means `self.age`. Records and lists are references.
- Sum type: `type Tree = Leaf | Node(l Tree, v int, r Tree)`; a fieldless variant is a value: `Leaf`. `match x` with arms `Node(l, v, r) -> expr`, `_ -> expr`, guards `P if cond -> expr`, literals, tuples, `[x, *rest]`, `A | B`.
- Generics: `fn first[T](xs [T]) T`, `type Box[T](v T)`, `type Tree[T] = Leaf | Node(l Tree[T], v T, r Tree[T])`; type args are inferred (`Box(1)`), written in annotations (`t: Tree[int]`) or explicitly (`Stack[int]()`). `<`, `+`, `sum`, dict keys on `T` are checked at each call.
- `interface Shape` with indented `fn area() float` lines; any type with those methods fits. `fn f[T: Shape](xs [T])` calls statically; `shapes: [Shape] = [Circle(1.0), Rect(2.0, 3.0)]` holds mixed types (dynamic calls).
- Errors: `try expr` or a `try` block, then `catch Kind e -> expr` or a block; `catch e` catches all; `e` is the message (str). `fail "msg"` raises `Error`; `fail ValueError("msg")` raises a kind. Kinds: `NotFound`, `ParseError`, `ValueError`, `IndexError`, `KeyError`, `ZeroDivisionError`, `OverflowError`, `AssertionError`, `IOError`, `NilError`, `HttpError`. Typed errors: `fail NotEnough(5, 2)` with any record/sum value; `catch NotEnough e` binds the value (`e.need`), `catch Variant e` one sum variant, `catch mod.Type e` from a module.
- Keyword args: `f(x, reverse: true)`. `sorted(xs, key: f)`, `xs.sort(key: f)`, `min(xs, key: f)`.
- `fn f(*xs int, **kw str)` collects extra args into `[int]` / `{str: str}`; `f(*list)` spreads. `fn main(path str, n = 3)`: parameters become CLI args (`--n 5`); `*files str` takes the rest.
- `with x as y` calls `x.enter()` (if defined) and always `x.exit()` at the end of the block, even on errors.
- Builtins: `print len str int float bool abs min max sum avg any all sorted list count zip enumerate round read write input exit`, `@cache`, `pi`.
- Methods: str `lower upper strip split splitlines find count replace startswith endswith isdigit isalpha join`; list `append pop insert extend sort reverse copy index count join sum avg top map filter sort_by group_by first`; dict `get keys values items copy top pop update clear`; set `add remove discard union intersection difference`. `xs.count()` is a `{T: int}` counter; `.top(n)` gives the n most common `(key, count)`.
- `import geo` / `from lib.geo import area` loads `geo.sip` next to the file (or from the package root / a dependency). Names starting with `_` (functions, types, fields, methods) are private to their module. Built-in modules need no import: `math random time json csv http`.
- Package: `sip.toml` with `[package] name = "app"` and `[deps] util = { path = "../util" }` or `{ git = "...", rev = "v1" }`; `import util.x` loads `x.sip` from the dependency.
- JSON and CSV read straight into the expected type: `users: [User] = json.read(p)`, `fn load(p str) [Row] = csv.read(p)`; `json.stringify(x, indent: 2)`, `json.write(p, x)`, `csv.write(p, rows)`. Plain `csv.read(p)` gives `[{str: str}]`.
- `r = http.get(url, timeout: 5, headers: {...})`: `r.status r.ok r.text r.headers`, `u: User = r.json()`; `http.post(url, json: x)`. 4xx/5xx raise `HttpError`.
- `async fn f(u str) int`; calling it makes a task; `await f(u)`; `await all(f(u) for u in urls)` runs them concurrently, in order. `await` only inside `async fn` (`async fn main` is fine).
- Tests: top-level `test "name"` blocks with `assert a == b` (shows both values); `sip test` runs them, `-k text` filters. `sip fmt` formats.
- Not available: slice steps, decorators other than `@cache`, generic functions as values (wrap in a lambda).
