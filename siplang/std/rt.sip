# Рантайм Sip, написанный на Sip: функции, которые вызывает сгенерированный C (s.lower(), s.replace(),
# s.ljust(), int(s), s * n, ...). Модуль подключается к каждой программе сам; его имена получают
# префикс std__rt__ и коду пользователя не видны.
#
# Ниже — примитивы из siplang/native/sip_rt.h: байт строки, кусок без копии, сырая память. Границы они
# не проверяют, поэтому индексы здесь всегда в пределах строки.

extern "sip" fn _byte(s str, i int) int = sip_rt_byte
extern "sip" fn _sub(s str, lo int, hi int) str = sip_rt_sub
extern "sip" fn _eq_at(s str, i int, t str) bool = sip_rt_eq_at
extern "sip" fn _find(s str, sub str, start int) int = sip_rt_find
extern "sip" fn _alloc(n int) ptr = sip_rt_alloc
extern "sip" fn _set(p ptr, i int, b int) = sip_rt_set
extern "sip" fn _fill(p ptr, i int, n int, b int) = sip_rt_fill
extern "sip" fn _copy(p ptr, i int, s str) = sip_rt_copy
extern "sip" fn _str(p ptr, n int) str = sip_rt_str
extern "sip" fn _sb() ptr = sip_rt_sb
extern "sip" fn _put(b ptr, s str) = sip_rt_put
extern "sip" fn _done(b ptr) str = sip_rt_done
# ParseError и OverflowError на строке вызова; через C, потому что программа может назвать так свой тип
extern "sip" fn _parse_error(msg str) = sip_rt_parse_error
extern "sip" fn _overflow(msg str) = sip_rt_overflow

fn _space(c int) bool = c == 32 or (c >= 9 and c <= 13)

fn _alpha(c int) bool = (c | 32) >= 97 and (c | 32) <= 122

fn _digit(c int) bool = c >= 48 and c <= 57

# lower (upper = false) и upper; только ASCII, остальные байты как есть. c ^ 32 меняет регистр буквы
fn str_map(s str, upper bool) str
    n = len(s)
    p = _alloc(n)
    lo = if upper then 97 else 65
    hi = lo + 25
    for i in 0..n - 1
        c = _byte(s, i)
        _set(p, i, if c >= lo and c <= hi then c ^ 32 else c)
    _str(p, n)

# isdigit (kind 0), isalpha (1), isspace (2), isalnum (3): строка не пуста, и все байты подходят
fn str_all(s str, kind int) bool
    n = len(s)
    if n == 0 then return false
    if kind == 0
        for i in 0..n - 1
            if not _digit(_byte(s, i)) then return false
    elif kind == 1
        for i in 0..n - 1
            if not _alpha(_byte(s, i)) then return false
    elif kind == 3
        for i in 0..n - 1
            c = _byte(s, i)
            if not (_digit(c) or _alpha(c)) then return false
    else
        for i in 0..n - 1
            if not _space(_byte(s, i)) then return false
    true

# isupper / islower как в Python: есть буквы, и все они в этом регистре
fn str_cased(s str, upper bool) bool
    any = false
    for i in 0..len(s) - 1
        c = _byte(s, i)
        if c >= 97 and c <= 122
            if upper then return false
            any = true
        elif c >= 65 and c <= 90
            if not upper then return false
            any = true
    any

# capitalize (words = false) и title (words = true)
fn str_title(s str, words bool) str
    n = len(s)
    p = _alloc(n)
    start = true
    for i in 0..n - 1
        c = _byte(s, i)
        alpha = _alpha(c)
        if alpha
            c = if start then c & 223 else c | 32
        _set(p, i, c)
        start = words and not alpha
    _str(p, n)

# число непересекающихся вхождений; пустая подстрока — len(s) + 1, как в Python
fn str_count(s str, sub str) int
    if len(sub) == 0 then return len(s) + 1
    if len(sub) == 1  # частый случай: подсчёт единиц без проверки переполнения, clang его векторизует
        b = _byte(sub, 0)
        return sum(1 for i in 0..len(s) - 1 if _byte(s, i) == b)
    k = 0
    i = _find(s, sub, 0)
    while i >= 0
        k += 1
        i = _find(s, sub, i + len(sub))
    k

fn str_rfind(s str, sub str) int
    i = len(s) - len(sub)
    while i >= 0
        if _eq_at(s, i, sub) then return i
        i -= 1
    -1

# removeprefix (suffix = false) и removesuffix
fn str_remove_affix(s str, a str, suffix bool) str
    n = len(s)
    m = len(a)
    if m > n then return s
    if not suffix and _eq_at(s, 0, a) then return _sub(s, m, n)
    if suffix and _eq_at(s, n - m, a) then return _sub(s, 0, n - m)
    s

# ljust (mode 0), rjust (1), zfill (2: нули после знака)
fn str_pad(s str, width int, mode int) str
    n = len(s)
    if width <= n then return s
    if width > 1099511627776 then _overflow("width is too large")
    p = _alloc(width)
    fill = width - n
    if mode == 0
        _copy(p, 0, s)
        _fill(p, n, fill, 32)
    elif mode == 1
        _fill(p, 0, fill, 32)
        _copy(p, fill, s)
    else
        sign = 0
        if n > 0 and (_byte(s, 0) == 45 or _byte(s, 0) == 43)
            sign = 1
            _set(p, 0, _byte(s, 0))
        _fill(p, sign, fill, 48)
        _copy(p, sign + fill, _sub(s, sign, n))
    _str(p, width)

fn str_replace(s str, old str, rep str) str
    if len(old) == 0 then return s
    b = _sb()
    i = 0
    j = _find(s, old, 0)
    while j >= 0
        _put(b, _sub(s, i, j))
        _put(b, rep)
        i = j + len(old)
        j = _find(s, old, i)
    _put(b, _sub(s, i, len(s)))
    _done(b)

# s * k
fn str_repeat(s str, k int) str
    n = len(s)
    if k <= 0 or n == 0 then return ""
    if k > 281474976710656 // n then _overflow("repeated string is too long")
    p = _alloc(n * k)
    for i in 0..k - 1
        _copy(p, i * n, s)
    _str(p, n * k)

fn _head(s str) str = if len(s) > 40 then _sub(s, 0, 40) else s

# int(s): пробелы по краям, знак, цифры; "_" пропускаются
fn parse_int(s str) int
    n = len(s)
    lo = 0
    hi = n
    while lo < hi and _space(_byte(s, lo))
        lo += 1
    while hi > lo and _space(_byte(s, hi - 1))
        hi -= 1
    if hi == lo or hi - lo >= 64 then _parse_error("invalid int: '{_head(s)}'")
    i = lo
    neg = false
    c = _byte(s, i)
    if c == 45 or c == 43
        neg = c == 45
        i += 1
    v = 0  # копится со знаком минус: так помещается и -9223372036854775808
    digits = 0
    big = false
    while i < hi
        c = _byte(s, i)
        i += 1
        if c == 95 then continue
        if not _digit(c) then _parse_error("invalid int: '{_head(s)}'")
        digits += 1
        d = c - 48
        if big or v < -922337203685477580 or (v == -922337203685477580 and d > 8)
            big = true
        else
            v = v * 10 - d
    if digits == 0 then _parse_error("invalid int: '{_head(s)}'")
    if big or (not neg and v == -9223372036854775807 - 1) then _overflow("int out of range: '{_head(s)}'")
    if neg then v else -v
