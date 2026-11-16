# Language E: Python with less noise

Semantics, stdlib names and comprehensions are Python's. Differences:

- Blocks by indentation, no `:` at line end. `fn name(a int, b = 1) T` declares a function; the last expression is returned. One-expression body: `fn f(x int) int = x * 2`.
- Types follow names without `:`: `int str float bool`, `[T]` list, `{K: V}` dict, `(A, B)` tuple, `T?` nullable. Inferred if omitted.
- `if c then a elif d then b else e` is an expression; `if c then stmt` works on one line.
- Ranges are inclusive: `1..100`. Integer `/` on ints is floor division.
- Strings interpolate: `"Hi {name}"`. `print x` without parentheses.
- `type User(name str, age int)` is a record; methods are indented `fn`s; `.age` means `self.age`.
- Sum types: `type Shape = Circle(r float) | Rect(w float, h float)`, matched with `match s` and indented `Pattern -> expr` arms.
- Errors: `try expr` / `catch Kind e -> expr` (block or inline); `fail "msg"` raises. `nil` is None. `a | b` merges dicts.
- `async fn`, `await all(xs)` runs awaitables concurrently.
- `fn main(name str, times = 1)` parameters become CLI arguments/flags.
- Builtins: `read(path)`, `count(xs)` → counter with `.top(n)`, `avg`, `http.get(url, timeout:)` → `.json()`, `.status`; `csv.read(path)` → rows with attribute access, `.group_by(col)`; `json.parse`; `@cache`.
