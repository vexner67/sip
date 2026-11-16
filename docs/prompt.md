# Sip

Sip is Python with less noise. It compiles to Python 3.12: Python's semantics, builtins, comprehensions and libraries (`import x`, `from x import y`) all work. Differences:

- Blocks by indentation, no `:`. `fn name(a int, b = 1) T` declares a function; its last expression is returned. One-expression body: `fn f(x int) int = x * 2`. Lambda: `fn(x) = x * 2`.
- Types follow names: `int str float bool`, `[T]` list, `{K: V}` dict, `(A, B)` tuple, `T?` nullable. Optional.
- `if c then a elif d then b else e` is an expression. Any block body may be one statement on the same line: `if c then return x`, `for x in xs: print x`.
- Ranges are inclusive: `1..100`. `/` on two ints is floor division.
- Strings interpolate: `"Hi {name} {x:.2f}"`; `{{` is a literal brace. `print a, b` needs no parentheses.
- `nil true false`. Dict literal keys that are bare names are strings: `{host: "x"}`. `a | b` merges dicts.
- `for k, v in d` iterates a dict's items.
- Record: `type User(name str, age int = 0)` with indented `fn` methods; `.age` means `self.age`.
- Sum type: `type Shape = Circle(r float) | Rect(w float, h float)`. `match s` with indented arms `Circle(r) -> expr`, `_ -> expr`, guards `P if cond -> expr`.
- Errors: `try expr` or a `try` block, then `catch Kind e -> expr` or a block; `catch e` catches all. `fail "msg"` raises. Kinds: `NotFound`, `ParseError`, `HttpError`, any Python exception.
- Keyword args: `f(x, timeout: 5)`.
- `async fn`; `await all(xs)` awaits concurrently, returns a list.
- `fn main(name str, times = 1)`: parameters become CLI args (`--times 2`).
- Builtins: `read(path)`, `write(path, s)`, `avg(xs)`, `count(xs)`, `@cache`, `pi`; `json.parse/stringify/read/write`; `csv.read(path)` gives rows with `.column`; `http.get(url, timeout:)` and `http.post(url, json:)` give `.status .text .json()`.
- List methods: `xs.count()` (a counter) `.top(n)`, `.group_by(key)`, `.map(f)`, `.filter(f)`, `.sort_by(f)`, `.sum()`, `.avg()`, `.first()`, `.join(sep)`.
