# Регулярные выражения: POSIX ERE (как grep -E) и сокращения \d \w \s \D \W \S.
# Нет ленивых *? и просмотра вперёд/назад. Позиции — в байтах.

extern "sip" fn _compile(posix str, pattern str) ptr = sip_re_compile
extern "sip" fn _subject(s str) ptr = sip_re_subject
extern "sip" fn _exec(r ptr, subj ptr, start int) ptr? = sip_re_exec
extern "sip" fn _ngroups(m ptr) int = sip_re_ngroups
extern "sip" fn _start(m ptr, i int) int = sip_re_start
extern "sip" fn _end(m ptr, i int) int = sip_re_end

# совпадение: текст, начало и конец, группы в скобках ("" — группа не участвовала)
type Match(text str, start int, end int, groups [str])

_cache: {str: ptr} = {}

# шаблон -> POSIX ERE: \d \w \s и \D \W \S (в том числе внутри [...]), \n \t \r; [\]] внутри класса — символ
fn _posix(p str) str
    out: [str] = []
    in_class = false
    n = len(p)
    i = 0
    while i < n
        c = p[i]
        if c == "\\" and i + 1 < n
            i += 1
            d = p[i]
            cls = if d == "d" then "0-9" elif d == "w" then "[:alnum:]_" elif d == "s" then "[:space:]" else ""
            neg = if d == "D" then "0-9" elif d == "W" then "[:alnum:]_" elif d == "S" then "[:space:]" else ""
            if cls != ""
                out.append(if in_class then cls else "[" + cls + "]")
            elif neg != "" and not in_class
                out.append("[^" + neg + "]")
            elif d == "n"
                out.append("\n")
            elif d == "t"
                out.append("\t")
            elif d == "r"
                out.append("\r")
            elif in_class
                out.append(d)
            else
                out.append("\\" + d)
            i += 1
            continue
        if not in_class and c == "["
            in_class = true
            out.append(c)
            if i + 1 < n and p[i + 1] == "^"
                i += 1
                out.append("^")
            if i + 1 < n and p[i + 1] == "]"
                i += 1
                out.append("]")
            i += 1
            continue
        if in_class and c == "[" and i + 1 < n and p[i + 1] == ":"  # [:alpha:]
            k = i + 2
            while k < n and p[k] != "]"
                k += 1
            if k < n
                out.append(p[i:k + 1])
                i = k + 1
                continue
        if in_class and c == "]" then in_class = false
        out.append(c)
        i += 1
    "".join(out)

fn _re(pattern str) ptr
    r = _cache.get(pattern)
    if r != nil then return r
    c = _compile(_posix(pattern), pattern)
    _cache[pattern] = c
    c

fn _match(s str, m ptr) Match
    groups: [str] = []
    for i in 1.._ngroups(m)
        a = _start(m, i)
        groups.append(if a < 0 then "" else s[a:_end(m, i)])
    Match(s[_start(m, 0):_end(m, 0)], _start(m, 0), _end(m, 0), groups)

# первое совпадение или nil
fn search(pattern str, s str) Match?
    m = _exec(_re(pattern), _subject(s), 0)
    if m == nil then return nil
    _match(s, m)

# есть ли совпадение
fn test(pattern str, s str) bool = _exec(_re(pattern), _subject(s), 0) != nil

# совпадает ли вся строка
fn full(pattern str, s str) bool = test("^(" + pattern + ")$", s)

# текст первого совпадения или nil
fn find(pattern str, s str) str?
    m = search(pattern, s)
    if m == nil then nil else m.text

# все совпадения, не пересекаясь, слева направо
fn matches(pattern str, s str) [Match]
    r = _re(pattern)
    subj = _subject(s)
    out: [Match] = []
    pos = 0
    while pos <= len(s)
        m = _exec(r, subj, pos)
        if m == nil then break
        mt = _match(s, m)
        out.append(mt)
        pos = if mt.end > mt.start then mt.end else mt.end + 1
    out

# тексты всех совпадений
fn find_all(pattern str, s str) [str] = [m.text for m in matches(pattern, s)]

# заменяет совпадения на repl: $0 — всё совпадение, $1..$9 — группы, $$ — знак $
fn replace(pattern str, s str, repl str) str = replace_fn(pattern, s, fn(m Match) = _expand(repl, m))

# заменяет каждое совпадение на f(совпадение)
fn replace_fn(pattern str, s str, f fn(Match) str) str
    out = ""
    last = 0
    for m in matches(pattern, s)
        out = out + s[last:m.start] + f(m)
        last = m.end
    out + s[last:]

fn _expand(repl str, m Match) str
    out = ""
    i = 0
    while i < len(repl)
        c = repl[i]
        if c == "$" and i + 1 < len(repl)
            d = repl[i + 1]
            if d == "$"
                out = out + "$"
                i += 2
                continue
            if d.isdigit()
                k = int(d)
                if k == 0
                    out = out + m.text
                elif k <= len(m.groups)
                    out = out + m.groups[k - 1]
                i += 2
                continue
        out = out + c
        i += 1
    out

# части строки между совпадениями
fn split(pattern str, s str) [str]
    out: [str] = []
    last = 0
    for m in matches(pattern, s)
        if m.end == m.start then continue
        out.append(s[last:m.start])
        last = m.end
    out.append(s[last:])
    out
