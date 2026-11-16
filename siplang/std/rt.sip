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
extern "sip" fn _putc(b ptr, c int) = sip_rt_putc
extern "sip" fn _fmt(x float, prec int, exp bool) str = sip_rt_fmt
extern "sip" fn _done(b ptr) str = sip_rt_done
extern "sip" fn _atof(s str) float = sip_rt_atof
extern "sip" fn _tofloat(s str) float = sip_rt_tofloat  # потом _fbad(): не число ли
extern "sip" fn _fbad() bool = sip_rt_fbad_get

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
    if width > 1099511627776 then fail OverflowError("width is too large")
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
    if k > 281474976710656 // n then fail OverflowError("repeated string is too long")
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
    if hi == lo or hi - lo >= 64 then fail ParseError("invalid int: '{_head(s)}'")
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
        if not _digit(c) then fail ParseError("invalid int: '{_head(s)}'")
        digits += 1
        d = c - 48
        if big or v < -922337203685477580 or (v == -922337203685477580 and d > 8)
            big = true
        else
            v = v * 10 - d
    if digits == 0 then fail ParseError("invalid int: '{_head(s)}'")
    if big or (not neg and v == -9223372036854775807 - 1) then fail OverflowError("int out of range: '{_head(s)}'")
    if neg then v else -v

# ---------- числа ----------

# float как в Python: кратчайшая запись, которая читается обратно; экспонента, если порядок < -4 или >= 16.
# Если 15 значащих цифр читаются обратно, кратчайшая запись — они же без нулей в конце (более короткая
# запись D, читаемая обратно, отличается от x меньше чем на 2**-53 и при округлении до 15 цифр даёт D);
# иначе хватает 16 или 17 цифр (у субнормальных чисел точность ниже — для них перебор). Так нужно 1-3 вызова printf вместо перебора всех точностей.
fn fmt_float(b ptr, x float)
    if x != x
        _put(b, "nan")
        return
    if x > 1.7976931348623157e308 or x < -1.7976931348623157e308
        _put(b, if x > 0.0 then "inf" else "-inf")
        return
    e = _fmt(x, 14, true)
    if x < 2.2250738585072014e-308 and x > -2.2250738585072014e-308  # субнормальные: точность ниже, перебор
        p = 0
        e = _fmt(x, 0, true)
        while p < 16 and _atof(e) != x
            p += 1
            e = _fmt(x, p, true)
    elif _atof(e) != x
        e = _fmt(x, 15, true)
        if _atof(e) != x then e = _fmt(x, 16, true)
    ep = _find(e, "e", 0)
    m = ep  # мантисса без нулей в конце: e[:m]
    if _find(e, ".", 0) >= 0
        while _byte(e, m - 1) == 48
            m -= 1
        if _byte(e, m - 1) == 46 then m -= 1
    mant = _sub(e, 0, m)
    exp = parse_int(_sub(e, ep + 1, len(e)))
    if exp < -4 or exp >= 16
        _put(b, mant)
        _put(b, _sub(e, ep, len(e)))
        return
    # без экспоненты: те же цифры, точка на своём месте (округление на той же позиции даёт те же цифры)
    neg = _byte(e, 0) == 45
    if neg then _putc(b, 45)
    d = _sb()  # цифры мантиссы без знака и точки
    for k in (if neg then 1 else 0)..m - 1
        if _byte(e, k) != 46 then _putc(d, _byte(e, k))
    ds = _done(d)
    n = len(ds)
    if exp < 0
        _put(b, "0.")
        _fill_put(b, 48, -exp - 1)
        _put(b, ds)
    elif n <= exp + 1
        _put(b, ds)
        _fill_put(b, 48, exp + 1 - n)
        _put(b, ".0")
    else
        _put(b, _sub(ds, 0, exp + 1))
        _putc(b, 46)
        _put(b, _sub(ds, exp + 1, n))

fn _fill_put(b ptr, c int, n int)
    for k in 0..n - 1
        _putc(b, c)

# ---------- JSON ----------
# Для каждого типа компилятор генерирует на C функцию разбора (jdec_K) и вывода (jenc_K); они читают
# и пишут текст функциями ниже. Путь до значения ($.users[0].age) копится в keys и idx (у ключа idx = -1)
# только ради сообщений об ошибках. jp_obj_next кладёт ключ в key, _jp_num — признак целого в isint.

type Jp(s str, i int, keys [str], idx [int], key str, isint bool)

fn jp_new(s str) Jp = Jp(s, 0, [], [], "", false)

fn _jp_where(p Jp) str
    ln = 1
    col = 1
    for k in 0..min(p.i, len(p.s)) - 1
        if _byte(p.s, k) == 10
            ln += 1
            col = 1
        else
            col += 1
    "line {ln}, column {col}"

fn _jp_path(p Jp) str
    b = _sb()
    _putc(b, 36)
    for j in 0..len(p.keys) - 1
        if p.idx[j] < 0
            _putc(b, 46)
            _put(b, p.keys[j])
        else
            _put(b, "[{p.idx[j]}]")
    _done(b)

fn _jp_syn(p Jp, what str) str = "invalid JSON: {what} ({_jp_where(p)})"

fn jp_fail(p Jp, msg str)
    fail ParseError("JSON {_jp_path(p)}: {msg}")

fn _jp_ws(p Jp)
    s = p.s
    n = len(s)
    i = p.i
    while i < n
        c = _byte(s, i)
        if c != 32 and c != 10 and c != 13 and c != 9 then break
        i += 1
    p.i = i

# следующий байт после пробелов; 0 — конец текста
fn _jp_peek(p Jp) int
    _jp_ws(p)
    if p.i < len(p.s) then _byte(p.s, p.i) else 0

fn _jp_kind(p Jp) str
    c = _jp_peek(p)
    if c == 34 then return "string"
    if c == 123 then return "object"
    if c == 91 then return "array"
    if c == 116 or c == 102 then return "bool"
    if c == 110 then return "null"
    if c == 0 then return "end of input"
    if c == 45 or _digit(c) then "number" else "invalid value"

# «ожидали X, а пришло Y» с путём до значения
fn _jp_type(p Jp, want str) str
    got = _jp_kind(p)
    if got == "invalid value" then return _jp_syn(p, "unexpected character")
    "JSON {_jp_path(p)}: expected {want}, got {got} ({_jp_where(p)})"

fn jp_want(p Jp, c int, what str)
    if _jp_peek(p) != c then fail ParseError(_jp_type(p, what))
    p.i += 1

fn _jp_word(p Jp, w str) bool
    if len(p.s) - p.i >= len(w) and _eq_at(p.s, p.i, w)
        p.i += len(w)
        return true
    false

fn jp_null(p Jp) bool = _jp_peek(p) == 110 and _jp_word(p, "null")

fn jp_bool(p Jp) bool
    c = _jp_peek(p)
    if c == 116 and _jp_word(p, "true") then return true
    if c == 102 and _jp_word(p, "false") then return false
    fail ParseError(_jp_type(p, "bool"))

fn _hexval(c int) int
    if _digit(c) then return c - 48
    if c >= 97 and c <= 102 then return c - 87
    if c >= 65 and c <= 70 then return c - 55
    -1

fn _jp_hex4(p Jp) int
    if len(p.s) - p.i < 4 then fail ParseError(_jp_syn(p, "bad \\u escape"))
    v = 0
    for k in 0..3
        d = _hexval(_byte(p.s, p.i))
        if d < 0 then fail ParseError(_jp_syn(p, "bad \\u escape"))
        p.i += 1
        v = v * 16 + d
    v

fn _utf8(b ptr, cp int)
    if cp < 128
        _putc(b, cp)
    elif cp < 2048
        _putc(b, 192 | (cp // 64))
        _putc(b, 128 | (cp & 63))
    elif cp < 65536
        _putc(b, 224 | (cp // 4096))
        _putc(b, 128 | ((cp // 64) & 63))
        _putc(b, 128 | (cp & 63))
    else
        _putc(b, 240 | (cp // 262144))
        _putc(b, 128 | ((cp // 4096) & 63))
        _putc(b, 128 | ((cp // 64) & 63))
        _putc(b, 128 | (cp & 63))

# конец куска без кавычек, обратных косых и управляющих байтов
fn _plain_end(s str, i int) int
    n = len(s)
    j = i
    while j < n
        c = _byte(s, j)
        if c == 34 or c == 92 or c < 32 then break
        j += 1
    j

fn jp_str(p Jp) str
    jp_want(p, 34, "string")
    s = p.s
    n = len(s)
    start = p.i
    i = _plain_end(s, start)
    if i < n and _byte(s, i) == 34  # без экранирования — кусок исходного текста, без копии
        p.i = i + 1
        return _sub(s, start, i)
    b = _sb()
    _put(b, _sub(s, start, i))
    while true
        if i >= n
            p.i = i
            fail ParseError(_jp_syn(p, "unterminated string"))
        c = _byte(s, i)
        if c == 34 then break
        if c < 32
            p.i = i
            fail ParseError(_jp_syn(p, "control character in string"))
        if c != 92
            j = _plain_end(s, i)
            _put(b, _sub(s, i, j))
            i = j
            continue
        i += 1
        if i >= n
            p.i = i
            fail ParseError(_jp_syn(p, "unterminated string"))
        c = _byte(s, i)
        i += 1
        if c == 34 or c == 92 or c == 47
            _putc(b, c)
        elif c == 98
            _putc(b, 8)
        elif c == 102
            _putc(b, 12)
        elif c == 110
            _putc(b, 10)
        elif c == 114
            _putc(b, 13)
        elif c == 116
            _putc(b, 9)
        elif c == 117
            p.i = i
            cp = _jp_hex4(p)
            if cp >= 55296 and cp < 56320 and len(s) - p.i >= 6 and _byte(s, p.i) == 92 and _byte(s, p.i + 1) == 117
                save = p.i
                p.i += 2
                lo = _jp_hex4(p)
                if lo >= 56320 and lo < 57344
                    cp = 65536 + ((cp - 55296) * 1024) + (lo - 56320)
                else
                    p.i = save
            _utf8(b, cp)
            i = p.i
        else
            p.i = i - 1
            fail ParseError(_jp_syn(p, "bad escape"))
    p.i = i + 1
    _done(b)

fn _jp_digits(p Jp)
    s = p.s
    i = p.i
    while i < len(s) and _digit(_byte(s, i))
        i += 1
    p.i = i

fn _jp_need_digit(p Jp)
    if p.i >= len(p.s) or not _digit(_byte(p.s, p.i)) then fail ParseError(_jp_syn(p, "bad number"))

# число: начало токена, isint — без дробной части и экспоненты; -1 NaN, -2 Infinity, -3 -Infinity
fn _jp_num(p Jp) int
    c = _jp_peek(p)
    p.isint = false
    if c != 45 and not _digit(c)
        if c == 78 and _jp_word(p, "NaN") then return -1
        if c == 73 and _jp_word(p, "Infinity") then return -2
        fail ParseError(_jp_type(p, "number"))
    s = p.s
    start = p.i
    if c == 45
        p.i += 1
        if _jp_word(p, "Infinity") then return -3
    _jp_need_digit(p)
    if _byte(s, p.i) == 48 then p.i += 1 else _jp_digits(p)
    isint = true
    if p.i < len(s) and _byte(s, p.i) == 46
        isint = false
        p.i += 1
        _jp_need_digit(p)
        _jp_digits(p)
    if p.i < len(s) and (_byte(s, p.i) | 32) == 101
        isint = false
        p.i += 1
        if p.i < len(s) and (_byte(s, p.i) == 43 or _byte(s, p.i) == 45) then p.i += 1
        _jp_need_digit(p)
        _jp_digits(p)
    p.isint = isint
    start

# цифры s[lo:hi] (может быть минус) -> int; копится со знаком минус, чтобы поместилось и -2**63
fn _jp_dec(p Jp, s str, lo int, hi int) int
    neg = _byte(s, lo) == 45
    j = if neg then lo + 1 else lo
    v = 0
    while j < hi
        d = _byte(s, j) - 48
        if v < -922337203685477580 or (v == -922337203685477580 and d > 8) then fail ParseError("JSON {_jp_path(p)}: integer out of range")
        v = v * 10 - d
        j += 1
    if neg then return v
    if v == -9223372036854775807 - 1 then fail ParseError("JSON {_jp_path(p)}: integer out of range")
    -v

fn jp_int(p Jp) int
    save = p.i
    start = _jp_num(p)
    if not p.isint
        p.i = save
        fail ParseError("JSON {_jp_path(p)}: expected int, got float ({_jp_where(p)})")
    _jp_dec(p, p.s, start, p.i)

fn jp_float(p Jp) float
    start = _jp_num(p)
    if start == -1 then return _atof("nan")
    if start == -2 then return _atof("inf")
    if start == -3 then return _atof("-inf")
    _atof(_sub(p.s, start, p.i))

# обход массива после '[': i — номер элемента
fn jp_arr_next(p Jp, i int) bool
    c = _jp_peek(p)
    if c == 93
        p.i += 1
        return false
    if i > 0
        if c != 44 then fail ParseError(_jp_syn(p, "expected ',' or ']'"))
        p.i += 1
    elif c == 0
        fail ParseError(_jp_syn(p, "expected ']'"))
    true

# обход объекта после '{': ключ — в p.key
fn jp_obj_next(p Jp, i int) bool
    c = _jp_peek(p)
    if c == 125
        p.i += 1
        return false
    if i > 0
        if c != 44 then fail ParseError(_jp_syn(p, "expected ',' or '}}'"))
        p.i += 1
    if _jp_peek(p) != 34 then fail ParseError(_jp_syn(p, "expected a string key"))
    p.key = jp_str(p)
    if _jp_peek(p) != 58 then fail ParseError(_jp_syn(p, "expected ':'"))
    p.i += 1
    true

fn jp_skip(p Jp)
    c = _jp_peek(p)
    if c == 34
        jp_str(p)
    elif c == 123
        p.i += 1
        i = 0
        while jp_obj_next(p, i)
            jp_skip(p)
            i += 1
    elif c == 91
        p.i += 1
        i = 0
        while jp_arr_next(p, i)
            jp_skip(p)
            i += 1
    elif c == 116 or c == 102
        jp_bool(p)
    elif jp_null(p)
        pass
    elif c == 45 or _digit(c) or c == 78 or c == 73
        _jp_num(p)
    else
        fail ParseError(_jp_syn(p, if c != 0 then "unexpected character" else "unexpected end of input"))
    pass

fn jp_key(p Jp, k str)
    p.keys.append(k)
    p.idx.append(-1)

fn jp_idx(p Jp, i int)
    p.keys.append("")
    p.idx.append(i)

fn jp_up(p Jp)
    p.keys.pop()
    p.idx.pop()

fn jp_key_int(p Jp, k str) int
    i = if len(k) > 0 and _byte(k, 0) == 45 then 1 else 0
    ok = len(k) > i and len(k) < 21
    j = i
    while ok and j < len(k)
        ok = _digit(_byte(k, j))
        j += 1
    if not ok then jp_fail(p, "object key is not an int")
    _jp_dec(p, k, 0, len(k))

fn jp_end(p Jp)
    if _jp_peek(p) != 0 then fail ParseError(_jp_syn(p, "extra data after the value"))

# поле "type" объекта (для типов-сумм); позиция не меняется
fn jp_tag(p Jp) str
    save = p.i
    jp_want(p, 123, "object")
    tag = ""
    found = false
    i = 0
    while jp_obj_next(p, i)
        if p.key == "type" and _jp_peek(p) == 34
            tag = jp_str(p)
            found = true
        else
            jp_skip(p)
        i += 1
    p.i = save
    if not found then jp_fail(p, "object has no \"type\" field")
    tag

# вывод: ind < 0 — в одну строку, как json.dumps; иначе с отступом ind
_SPACES = "                                                                "

fn je_sep(b ptr, ind int, depth int, first bool)
    if not first then _putc(b, 44)
    if ind < 0
        if not first then _putc(b, 32)
        return
    _putc(b, 10)
    k = ind * depth
    while k > 0
        m = min(k, 64)
        _put(b, _sub(_SPACES, 0, m))
        k -= m

fn je_close(b ptr, ind int, depth int, c int)
    if ind >= 0 then je_sep(b, ind, depth, true)
    _putc(b, c)

_HEX = "0123456789abcdef"

fn je_str(b ptr, s str)
    _putc(b, 34)
    n = len(s)
    start = 0
    i = _plain_end(s, 0)
    while i < n
        _put(b, _sub(s, start, i))
        c = _byte(s, i)
        if c == 34
            _put(b, "\\\"")
        elif c == 92
            _put(b, "\\\\")
        elif c == 10
            _put(b, "\\n")
        elif c == 13
            _put(b, "\\r")
        elif c == 9
            _put(b, "\\t")
        elif c == 8
            _put(b, "\\b")
        elif c == 12
            _put(b, "\\f")
        else
            _put(b, "\\u00")
            _put(b, _sub(_HEX, c // 16, (c // 16) + 1))
            _put(b, _sub(_HEX, c & 15, (c & 15) + 1))
        start = i + 1
        i = _plain_end(s, start)
    _put(b, _sub(s, start, n))
    _putc(b, 34)

fn je_float(b ptr, x float)
    if x != x
        _put(b, "NaN")
    elif x > 1.7976931348623157e308
        _put(b, "Infinity")
    elif x < -1.7976931348623157e308
        _put(b, "-Infinity")
    else
        fmt_float(b, x)

fn je_bool(b ptr, x bool)
    _put(b, if x then "true" else "false")

# ---------- CSV ----------
# Диалект Python по умолчанию: поля в кавычках с "" внутри, строки \n, \r\n или \r; при записи кавычки
# только там, где нужны, строки кончаются \r\n. Как и для JSON, код под каждый тип генерирует компилятор.
# csv_row кладёт поля записи в f (список один на весь разбор), row_line — её строка в файле, для ошибок.

type Csv(s str, i int, d int, row_line int, next_line int, f [str])

fn csv_delim(d str) int
    if len(d) != 1 then fail ValueError("delimiter must be a 1-character string")
    _byte(d, 0)

fn csv_new(text str, delim str) Csv = Csv(text, 0, csv_delim(delim), 1, 1, [])

# конец поля без кавычек: разделитель или конец строки
fn _csv_end(s str, i int, d int) int
    n = len(s)
    j = i
    while j < n
        ch = _byte(s, j)
        if ch == d or ch == 10 or ch == 13 then break
        j += 1
    j

# следующая запись; false — данных больше нет
fn csv_row(c Csv) bool
    s = c.s
    n = len(s)
    i = c.i
    if i >= n then return false
    f = c.f
    f.clear()
    c.row_line = c.next_line
    ch = _byte(s, i)
    if ch == 10 or ch == 13  # пустая строка — запись без полей
        if ch == 13 and i + 1 < n and _byte(s, i + 1) == 10 then i += 1
        c.i = i + 1
        c.next_line += 1
        return true
    while true
        if i < n and _byte(s, i) == 34
            b = _sb()
            i += 1
            while i < n
                q = _find(s, "\"", i)
                if q < 0 then q = n
                c.next_line += sum(1 for k in i..q - 1 if _byte(s, k) == 10)
                _put(b, _sub(s, i, q))
                i = q
                if i >= n then break
                if i + 1 < n and _byte(s, i + 1) == 34
                    _putc(b, 34)
                    i += 2
                    continue
                i += 1
                break
            j = _csv_end(s, i, c.d)  # после закрывающей кавычки — как в Python: всё до разделителя в поле
            _put(b, _sub(s, i, j))
            i = j
            f.append(_done(b))
        else
            j = _csv_end(s, i, c.d)
            f.append(_sub(s, i, j))
            i = j
        if i >= n
            c.i = i
            return true
        ch = _byte(s, i)
        if ch == c.d
            i += 1
            if i >= n
                f.append("")
                c.i = i
                return true
            continue
        if ch == 13 and i + 1 < n and _byte(s, i + 1) == 10 then i += 1
        c.i = i + 1
        c.next_line += 1
        return true
    false

fn csv_cell(c Csv, i int) str = if i >= 0 and i < len(c.f) then c.f[i] else ""

fn csv_header(c Csv) [str] = c.f.copy()

fn csv_col(h [str], name str) int
    for i in 0..len(h) - 1
        if h[i] == name then return i
    -1

fn _csv_bad(c Csv, i int, col str, what str) str
    v = _head(csv_cell(c, i))
    if len(col) > 0 then return "CSV line {c.row_line}, column '{col}': invalid {what}: '{v}'"
    "CSV line {c.row_line}, column {i + 1}: invalid {what}: '{v}'"

# как strtoll после удаления "_": пробелы, знак, цифры
fn csv_int(c Csv, i int, col str) int
    t = csv_cell(c, i).strip()
    n = len(t)
    bad = n == 0 or n >= 64
    k = 0
    while k < n and (_byte(t, k) == 95 or _space(_byte(t, k)))
        k += 1
    neg = false
    if k < n and (_byte(t, k) == 45 or _byte(t, k) == 43)
        neg = _byte(t, k) == 45
        k += 1
    v = 0
    digits = 0
    while not bad and k < n
        ch = _byte(t, k)
        k += 1
        if ch == 95 then continue
        d = ch - 48
        if not _digit(ch) or v < -922337203685477580 or (v == -922337203685477580 and d > 8)
            bad = true
        else
            v = v * 10 - d
            digits += 1
    if bad or digits == 0 or (not neg and v == -9223372036854775807 - 1) then fail ParseError(_csv_bad(c, i, col, "int"))
    if neg then v else -v

fn csv_float(c Csv, i int, col str) float
    v = _tofloat(csv_cell(c, i).strip())
    if _fbad() then fail ParseError(_csv_bad(c, i, col, "float"))
    v

fn csv_bool(c Csv, i int, col str) bool
    t = csv_cell(c, i).strip()
    if t == "true" or t == "True" or t == "1" or t == "yes" then return true
    if t == "false" or t == "False" or t == "0" or t == "no" or t == "" then return false
    fail ParseError(_csv_bad(c, i, col, "bool"))

fn csv_put(b ptr, s str, d int)
    q = false
    for i in 0..len(s) - 1
        ch = _byte(s, i)
        if ch == d or ch == 34 or ch == 10 or ch == 13
            q = true
            break
    if not q
        _put(b, s)
        return
    _putc(b, 34)
    start = 0
    j = _find(s, "\"", 0)
    while j >= 0
        _put(b, _sub(s, start, j + 1))
        _putc(b, 34)
        start = j + 1
        j = _find(s, "\"", start)
    _put(b, _sub(s, start, len(s)))
    _putc(b, 34)
