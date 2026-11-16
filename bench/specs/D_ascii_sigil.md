# Language D: terse ASCII sigils

Python-like semantics and stdlib, but core syntax uses sigils:

- `\name(a T, b=1) R = expr` declares a function; a block body follows on indented lines; the last expression is returned. `&\` declares an async function.
- Types are one letter: `i` int, `s` str, `f` float, `b` bool; `[T]` list, `{K:V}` dict, `(A,B)` tuple, `T?` nullable, `{}` any dict. `T`/`F` are true/false, `nil` is None.
- `%Name{field T, ...}` declares a record; indented `\` lines are its methods; `.field` means self.field. `%Name = A(x T) | B(y T)` declares a sum type.
- `@x xs : stmt` is a for-loop over `xs`; `@ cond` (with indented body) is a while-loop. `a..b` is an inclusive range.
- `c ? a : b` is a conditional; `c ? stmt` without `:` runs stmt only if c. `^x` returns x early.
- `x | f | g(n)` pipes: `f(x)`, then `g(result, n)`. `["k"]` in a pipe indexes the value.
- Collection sigils (apply to the left value): `?{pred}` filter, `*{expr}` map, `+/` sum, `group{key}` group by, `mapv{expr}` map dict values. Inside `{}` `_` is the current element.
- `&all` awaits a list of awaitables concurrently.
- `v ~` followed by indented `Pattern -> expr` arms is a match. `!Kind` / `!Kind(e)` matches an error; a bare name matches success.
- `expr !! {handler}` catches any error from expr; inside, `_` is the error. `fail("msg")` raises. `a + b` on dicts merges them.
- Strings interpolate: `"Hi {name}"`. `%` is modulo, `/` on ints is floor division.
- `\main(name s, times=1)` parameters become CLI arguments/flags.
- Builtins: `read(path)`, `lower`, `words`, `count`, `top(n)`, `avg`, `json`, `json.parse`, `http.get(url, timeout=)` with `.status`, `csv.read(path)`, `@cache`.
