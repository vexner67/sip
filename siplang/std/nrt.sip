# Рантайм нативного бэкенда (sipc native): память со сборщиком мусора, строки, списки.
# Подключается только к нативной сборке и компилируется ею же; адреса — обычные int.
#
# Куча — одна зарезервированная область. Блок: слово заголовка (размер блока в байтах, кратный 16,
# плюс флаги: 1 — помечен, 2 — внутри нет ссылок), за ним данные. Адрес объекта — адрес данных
# (заголовок + 8). Строка: [длина][байты]. Список: [n][cap][данные] — данные отдельным объектом,
# по 8 байт на элемент. Литералы строк лежат в __TEXT: [длина][байты], сборщик их не трогает.
#
# Сборщик консервативный, без перемещения: корни — стек, сохраняемые регистры и __bss. Слово
# считается ссылкой, если указывает ровно на данные выделенного блока (карта начал блоков — байт на
# каждые 16 байт кучи). Поэтому код не держит через выделение памяти только адрес внутри объекта —
# всегда и сам объект. Свободные блоки: списки по размеру (до 512 байт) и общий список больших;
# соседние мёртвые блоки при сборке сливаются.
#
# Состояние — в ячейках _state() (глобальные переменные модуля из функций не присваиваются):
#   0 начало кучи, 8 граница выделенного, 16 конец кучи, 24 карта начал, 32 стек пометки,
#   40 выделено после сборки, 48 порог следующей сборки, 64 + 8k — списки свободных блоков
#   (k = 1..32 — блоки из k кусков по 16 байт, k = 0 — большие)

extern "sip" fn _ld(p int) int = sip_n_ld
extern "sip" fn _st(p int, v int) = sip_n_st
extern "sip" fn _ldb(p int) int = sip_n_ldb
extern "sip" fn _stb(p int, v int) = sip_n_stb
extern "sip" fn _state() int = sip_n_state
extern "sip" fn _chars() int = sip_n_chars  # 256 строк из одного байта, по 16 байт
extern "sip" fn _a(s str) int = sip_n_addr  # строка как адрес
extern "sip" fn _mmap(n int) int = sip_n_mmap
extern "sip" fn _move(dst int, src int, n int) = sip_n_move
extern "sip" fn _cmp(a int, b int, n int) int = sip_n_cmp
extern "sip" fn _zero(p int, n int) = sip_n_zero
extern "sip" fn _chr(p int, c int, n int) int = sip_n_chr  # memchr: адрес или 0
extern "sip" fn _roots() = sip_n_roots  # сохраняемые регистры — в стек, затем collect(sp)
extern "sip" fn _stack_top() int = sip_n_stack_top
extern "sip" fn _bss_lo() int = sip_n_bss_lo
extern "sip" fn _bss_hi() int = sip_n_bss_hi
extern "sip" fn _die(s int) = sip_n_die  # текст ошибки (строка) в stderr, exit(1)
extern "sip" fn _cbase() int = sip_n_cbase  # начало __const: там описатели типов

# Вид значения (kind) — для печати, == и <: 0 int, 1 bool, 2 str, иначе kind - 16 — смещение описателя
# типа в __const. Описатель — слова: список [3, вид элемента]; кортеж [4, n, виды...];
# record [5, n, смещение имени, (смещение имени поля, вид) * n]. Смещения строк — тоже от начала __const.
fn _desc(kind int) int = _cbase() + kind - 16

fn _heap_bytes() int = 17179869184  # 16 ГБ адресов: память берётся у системы по мере касания

fn _init(g int)
    n = _heap_bytes()
    base = _mmap(n + n // 16 + n // 2)
    if base == -1 then _die(_a("MemoryError: cannot reserve the heap\n"))
    _st(g, base)
    _st(g + 8, base)
    _st(g + 16, base + n)
    _st(g + 24, base + n)
    _st(g + 32, base + n + n // 16)
    _st(g + 48, 33554432)

# блок h размера bs — в свой список свободных
fn _push(g int, h int, bs int)
    k = bs // 16
    head = if k <= 32 then g + 64 + 8 * k else g + 64
    _st(h, bs)
    _st(h + 8, _ld(head))
    _st(head, h)

# кусок большого свободного блока размером sz; 0 — нет
fn _take(g int, sz int) int
    link = g + 64
    b = _ld(link)
    while b != 0
        bs = _ld(b)
        if bs >= sz
            nxt = _ld(b + 8)
            if bs > sz
                rest = b + sz
                if (bs - sz) // 16 <= 32
                    _st(link, nxt)
                    _push(g, rest, bs - sz)
                else
                    _st(rest, bs - sz)
                    _st(rest + 8, nxt)
                    _st(link, rest)
            else
                _st(link, nxt)
            _st(b, sz)
            return b
        link = b + 8
        b = _ld(link)
    0

# n байт данных; flags 2 — без ссылок (не обнуляется и не сканируется).
# Быстрый путь — без вызовов (функция листовая): маленький блок из списка свободных или сдвигом
# границы; остальное — _alloc_slow хвостовым вызовом.
fn alloc(n int, flags int) int
    g = _state()
    sz = (n + 23) // 16 * 16
    k = sz // 16
    since = _ld(g + 40) + sz
    if k > 32 or since > _ld(g + 48) then return _alloc_slow(n, flags)
    h = _ld(g + 64 + 8 * k)
    if h != 0
        _st(g + 64 + 8 * k, _ld(h + 8))
    else
        h = _ld(g + 8)
        if h + sz > _ld(g + 16) then return _alloc_slow(n, flags)
        _st(g + 8, h + sz)
    if flags == 0  # память после сборки грязная
        p = h + 8
        while p < h + sz
            _st(p, 0)
            p += 8
    _st(g + 40, since)
    _st(h, sz + flags)
    _stb(_ld(g + 24) + (h - _ld(g)) // 16, 1)
    h + 8

fn _alloc_slow(n int, flags int) int
    g = _state()
    if _ld(g) == 0 then _init(g)
    if _ld(g + 40) >= _ld(g + 48) then _roots()
    sz = (n + 23) // 16 * 16
    k = sz // 16
    h = 0
    if k <= 32  # точный по размеру свободный блок
        h = _ld(g + 64 + 8 * k)
        if h != 0 then _st(g + 64 + 8 * k, _ld(h + 8))
    if h == 0 and _ld(g + 64) != 0 then h = _take(g, sz)
    if h == 0
        h = _ld(g + 8)
        if h + sz > _ld(g + 16) then _die(_a("MemoryError: out of memory\n"))
        _st(g + 8, h + sz)
    if flags == 0  # память после сборки грязная
        if sz <= 256
            p = h + 8
            while p < h + sz
                _st(p, 0)
                p += 8
        else
            _zero(h + 8, sz - 8)
    _st(g + 40, _ld(g + 40) + sz)
    _st(h, sz + flags)
    base = _ld(g)
    _stb(_ld(g + 24) + (h - base) // 16, 1)
    h + 8

# пометить объекты, на которые указывают слова [lo, hi); вернуть новую вершину стека пометки
fn _scan(g int, lo int, hi int, top0 int) int
    top = top0
    base = _ld(g)
    lim = _ld(g + 8)
    smap = _ld(g + 24)
    p = lo
    while p < hi
        w = _ld(p)
        if w > base and w < lim and (w & 15) == 8
            h = w - 8
            if _ldb(smap + (h - base) // 16) == 1
                hd = _ld(h)
                if (hd & 1) == 0
                    _st(h, hd + 1)
                    if (hd & 2) == 0
                        _st(top, h)
                        top += 8
        p += 8
    top

# сборка: sp — вершина стека с сохранёнными регистрами
fn collect(sp int)
    g = _state()
    ms = _ld(g + 32)
    top = _scan(g, sp, _stack_top(), ms)
    top = _scan(g, _bss_lo(), _bss_hi(), top)
    while top > ms
        top -= 8
        h = _ld(top)
        hd = _ld(h)
        top = _scan(g, h + 8, h + hd - (hd & 15), top)
    _sweep(g)

fn _sweep(g int)
    base = _ld(g)
    lim = _ld(g + 8)
    smap = _ld(g + 24)
    for k in 0..32
        _st(g + 64 + 8 * k, 0)
    live = 0
    run = 0  # начало серии мёртвых блоков
    h = base
    while h < lim
        hd = _ld(h)
        sz = hd - (hd & 15)
        at = smap + (h - base) // 16
        if (hd & 1) == 1 and _ldb(at) == 1
            _st(h, hd - 1)
            live += sz
            if run != 0
                _push(g, run, h - run)
                run = 0
        else
            _stb(at, 0)
            if run == 0 then run = h
        h += sz
    if run != 0 then _st(g + 8, run)  # мёртвый хвост — обратно в нетронутую память
    _st(g + 40, 0)
    _st(g + 48, if live > 33554432 then live else 33554432)

# ---------- строки ----------

fn str_new(n int) int
    p = alloc(n + 8, 2)
    _st(p, n)
    p

fn char(c int) int = _chars() + 16 * c

# длина десятичной записи x
fn _ilen(x int) int
    if x == -9223372036854775807 - 1 then return 20
    t = (if x < 0 then -x else x) & 9223372036854775807  # маска: генератор видит, что t >= 0
    n = if x < 0 then 2 else 1
    while t >= 10
        t = t // 10
        n += 1
    n

# десятичная запись x в n байт с адреса p; вернуть p + n
fn _iput(p int, x int, n int) int
    if x == -9223372036854775807 - 1
        m = _a("-9223372036854775808")
        for i in 0..19
            _stb(p + i, _ldb(m + 8 + i))
        return p + 20
    t = (if x < 0 then -x else x) & 9223372036854775807
    q = p + n - 1
    while t >= 10
        _stb(q, 48 + t % 10)
        t = t // 10
        q -= 1
    _stb(q, 48 + t)
    if x < 0 then _stb(p, 45)
    p + n

fn _plen(x int, num bool) int = if num then _ilen(x) else _ld(x)

fn _copy(p int, src int, n int) int
    _move(p, src, n)
    p + n

# n байт из src в p (куски не пересекаются): короткие — словами по 8 байт, длинные — memmove; p + n
fn _bytes(p int, src int, n int) int
    if n > 64 then return _copy(p, src, n)
    i = 0
    while i + 8 <= n
        _st(p + i, _ld(src + i))
        i += 8
    while i < n
        _stb(p + i, _ldb(src + i))
        i += 1
    p + n

fn _memeq(p int, q int, n int) bool
    c = _cmp(p, q, n)
    c == 0

# n байт по адресам p и q равны
fn _same(p int, q int, n int) bool
    if n > 64 then return _memeq(p, q, n)
    i = 0
    while i + 8 <= n
        if _ld(p + i) != _ld(q + i) then return false
        i += 8
    while i < n
        if _ldb(p + i) != _ldb(q + i) then return false
        i += 1
    true

# часть склейки (число или строка) длины n — с адреса p; вернуть p + n
fn _pput(p int, x int, n int, num bool) int
    if num then return _iput(p, x, n)
    return _bytes(p, x + 8, n)

# склейка cnt (2..6) частей за одно выделение памяти; бит i маски: часть i — число (int), иначе строка
fn cat(cnt int, mask int, a int, b int, c int, d int, e int, f int) int
    la = _plen(a, (mask & 1) != 0)
    lb = _plen(b, (mask & 2) != 0)
    lc = if cnt > 2 then _plen(c, (mask & 4) != 0) else 0
    ld = if cnt > 3 then _plen(d, (mask & 8) != 0) else 0
    le = if cnt > 4 then _plen(e, (mask & 16) != 0) else 0
    lf = if cnt > 5 then _plen(f, (mask & 32) != 0) else 0
    n = la + lb + lc + ld + le + lf
    if n == 0 then return _a("")
    if n == 1 and cnt == 2 and mask == 0 then return if la == 1 then a else b
    r = str_new(n)
    p = _pput(r + 8, a, la, (mask & 1) != 0)
    p = _pput(p, b, lb, (mask & 2) != 0)
    if cnt > 2 then p = _pput(p, c, lc, (mask & 4) != 0)
    if cnt > 3 then p = _pput(p, d, ld, (mask & 8) != 0)
    if cnt > 4 then p = _pput(p, e, le, (mask & 16) != 0)
    if cnt > 5 then _pput(p, f, lf, (mask & 32) != 0)
    r

fn str_eq(a int, b int) bool
    if a == b then return true
    n = _ld(a)
    if n != _ld(b) then return false
    return _same(a + 8, b + 8, n)

# знак: a < b, a == b, a > b
fn str_cmp(a int, b int) int
    la = _ld(a)
    lb = _ld(b)
    c = _cmp(a + 8, b + 8, if la < lb then la else lb)
    if c != 0 then return c
    la - lb

# s[lo:hi] без проверок (0 <= lo <= hi <= len)
fn sub(s int, lo int, hi int) int
    m = hi - lo
    if m == 0 then return _a("")
    if m == 1 then return char(_ldb(s + 8 + lo))
    if m == _ld(s) then return s
    r = str_new(m)
    _bytes(r + 8, s + 8 + lo, m)
    r

# границы среза, как в Python; has: 1 — есть начало, 2 — есть конец
fn _lo(n int, lo0 int, has int) int
    lo = if (has & 1) != 0 then lo0 else 0
    if lo < 0 then lo += n
    if lo < 0 then lo = 0
    if lo > n then lo = n
    lo

fn _hi(n int, hi0 int, has int) int
    hi = if (has & 2) != 0 then hi0 else n
    if hi < 0 then hi += n
    if hi < 0 then hi = 0
    if hi > n then hi = n
    hi

fn slice(s int, lo0 int, hi0 int, has int) int
    n = _ld(s)
    lo = _lo(n, lo0, has)
    hi = _hi(n, hi0, has)
    if hi < lo then hi = lo
    sub(s, lo, hi)

# первое вхождение t в s начиная с at (0 <= at <= len); -1 — нет
fn find(s int, t int, at int) int
    n = _ld(s)
    m = _ld(t)
    if m == 0 then return at
    if m > n - at then return -1
    p = s + 8 + at
    last = s + 8 + n - m
    c = _ldb(t + 8)
    while p <= last
        q = _chr(p, c, last - p + 1)
        if q == 0 then return -1
        if _same(q + 1, t + 9, m - 1) then return q - s - 8
        p = q + 1
    -1

# t in s
fn has_sub(t int, s int) bool = find(s, t, 0) >= 0

fn starts(s int, t int) bool
    m = _ld(t)
    m <= _ld(s) and _same(s + 8, t + 8, m)

fn ends(s int, t int) bool
    m = _ld(t)
    n = _ld(s)
    m <= n and _same(s + 8 + n - m, t + 8, m)

fn of_int(x int) int
    if x >= 0 and x < 10 then return char(48 + x)
    n = _ilen(x)
    r = str_new(n)
    _iput(r + 8, x, n)
    r

# ---------- построитель строки: [n][cap][байты] ----------

fn sb_new() int
    b = alloc(24, 0)
    d = alloc(64, 2)
    _st(b + 8, 64)
    _st(b + 16, d)
    b

# место под k байт в конце; вернуть смещение, с которого писать
fn _room(b int, k int) int
    n = _ld(b)
    cap = _ld(b + 8)
    if n + k > cap
        nc = cap * 2
        while nc < n + k
            nc = nc * 2
        d = alloc(nc, 2)
        _move(d, _ld(b + 16), n)
        _st(b + 16, d)
        _st(b + 8, nc)
    _st(b, n + k)
    n

fn sb_byte(b int, c int)
    at = _room(b, 1)
    _stb(_ld(b + 16) + at, c)

# s[lo:hi]
fn sb_sub(b int, s int, lo int, hi int)
    at = _room(b, hi - lo)
    _move(_ld(b + 16) + at, s + 8 + lo, hi - lo)

fn sb_put(b int, s int) = sb_sub(b, s, 0, _ld(s))

fn sb_done(b int) int
    n = _ld(b)
    if n == 1 then return char(_ldb(_ld(b + 16)))
    r = str_new(n)
    _move(r + 8, _ld(b + 16), n)
    r

# запись значения вида kind (как str())
fn sb_val(b int, v int, kind int)
    if kind == 0
        sb_put(b, of_int(v))
    elif kind == 1
        sb_put(b, if v != 0 then _a("True") else _a("False"))
    elif kind == 2
        sb_put(b, v)
    else
        d = _desc(kind)
        tag = _ld(d)
        if tag == 3
            sb_list(b, v, _ld(d + 8))
        elif tag == 4
            n = _ld(d + 8)
            sb_byte(b, 40)
            for i in 0..n - 1
                if i > 0 then sb_put(b, _a(", "))
                sb_repr(b, _ld(v + 8 * i), _ld(d + 16 + 8 * i))
            if n == 1 then sb_byte(b, 44)
            sb_byte(b, 41)
        else
            n = _ld(d + 8)
            sb_put(b, _cbase() + _ld(d + 16))
            sb_byte(b, 40)
            for i in 0..n - 1
                if i > 0 then sb_put(b, _a(", "))
                sb_put(b, _cbase() + _ld(d + 24 + 16 * i))
                sb_byte(b, 61)
                sb_repr(b, _ld(v + 8 * i), _ld(d + 32 + 16 * i))
            sb_byte(b, 41)
    pass

fn sb_repr(b int, v int, kind int)
    if kind == 2 then repr_str(b, v) else sb_val(b, v, kind)

fn sb_list(b int, l int, ek int)
    sb_byte(b, 91)
    i = 0
    while i < _ld(l)
        if i > 0 then sb_put(b, _a(", "))
        sb_repr(b, _ld(_ld(l + 16) + 8 * i), ek)
        i += 1
    sb_byte(b, 93)

fn to_str(v int, kind int) int
    if kind == 2 then return v
    if kind == 0 then return of_int(v)
    if kind == 1 then return if v != 0 then _a("True") else _a("False")
    b = sb_new()
    sb_val(b, v, kind)
    sb_done(b)

# a == b для значений вида kind
fn eq(a int, b int, kind int) bool
    if a == b then return true
    if kind < 2 then return false
    if kind == 2 then return str_eq(a, b)
    d = _desc(kind)
    tag = _ld(d)
    if tag == 3
        n = _ld(a)
        if n != _ld(b) then return false
        ek = _ld(d + 8)
        i = 0
        while i < n
            if not eq(_ld(_ld(a + 16) + 8 * i), _ld(_ld(b + 16) + 8 * i), ek) then return false
            i += 1
        return true
    n = _ld(d + 8)
    step = if tag == 4 then 8 else 16
    at = if tag == 4 then d + 16 else d + 32
    for i in 0..n - 1
        if not eq(_ld(a + 8 * i), _ld(b + 8 * i), _ld(at + step * i)) then return false
    true

# знак сравнения a и b (числа, строки, списки и кортежи — по элементам, как в Python)
fn cmp(a int, b int, kind int) int
    if kind < 2
        if a < b then return -1
        return if a > b then 1 else 0
    if kind == 2 then return str_cmp(a, b)
    d = _desc(kind)
    if _ld(d) == 3
        na = _ld(a)
        nb = _ld(b)
        ek = _ld(d + 8)
        i = 0
        while i < na and i < nb
            c = cmp(_ld(_ld(a + 16) + 8 * i), _ld(_ld(b + 16) + 8 * i), ek)
            if c != 0 then return c
            i += 1
        return na - nb
    n = _ld(d + 8)
    for i in 0..n - 1
        c = cmp(_ld(a + 8 * i), _ld(b + 8 * i), _ld(d + 16 + 8 * i))
        if c != 0 then return c
    0

# объект из n слов (кортеж, record); flags 2 — в нём нет ссылок
fn obj_new(n int, flags int) int = alloc(8 * n, flags)

# как repr() в Python: кавычки, экранирование
fn repr_str(b int, s int)
    q = if find(s, _a("'"), 0) >= 0 and find(s, _a("\""), 0) < 0 then 34 else 39
    sb_byte(b, q)
    n = _ld(s)
    start = 0
    for i in 0..n - 1
        c = _ldb(s + 8 + i)
        if c == 92 or c == q or c < 32 or c == 127
            sb_sub(b, s, start, i)
            start = i + 1
            if c == 92
                sb_put(b, _a("\\\\"))
            elif c == q
                sb_byte(b, 92)
                sb_byte(b, c)
            elif c == 10
                sb_put(b, _a("\\n"))
            elif c == 9
                sb_put(b, _a("\\t"))
            elif c == 13
                sb_put(b, _a("\\r"))
            else
                sb_put(b, _a("\\x"))
                sb_byte(b, _ldb(_a("0123456789abcdef") + 8 + c // 16))
                sb_byte(b, _ldb(_a("0123456789abcdef") + 8 + (c & 15)))
    sb_sub(b, s, start, n)
    sb_byte(b, q)

fn join(sep int, l int) int
    n = _ld(l)
    if n == 0 then return _a("")
    if n == 1 then return _ld(_ld(l + 16))
    b = sb_new()
    i = 0
    while i < _ld(l)
        if i > 0 then sb_put(b, sep)
        sb_put(b, _ld(_ld(l + 16) + 8 * i))
        i += 1
    sb_done(b)

# ---------- списки ----------

# n элементов, место под cap; flags 2 — элементы не ссылки
fn list_new(n int, cap int, flags int) int
    l = alloc(24, 0)
    if cap > 0
        d = alloc(8 * cap, flags)
        _st(l + 16, d)
    _st(l, n)
    _st(l + 8, cap)
    l

fn _grow(l int, need int, flags int)
    cap = _ld(l + 8)
    nc = if cap == 0 then 4 else cap * 2
    while nc < need
        nc = nc * 2
    d = alloc(8 * nc, flags)
    _move(d, _ld(l + 16), 8 * _ld(l))
    _st(l + 16, d)
    _st(l + 8, nc)

fn append(l int, x int, flags int)
    n = _ld(l)
    if n == _ld(l + 8) then _grow(l, n + 1, flags)
    _st(_ld(l + 16) + 8 * n, x)
    _st(l, n + 1)

fn list_slice(l int, lo0 int, hi0 int, has int, flags int) int
    n = _ld(l)
    lo = _lo(n, lo0, has)
    hi = _hi(n, hi0, has)
    if hi < lo then hi = lo
    r = list_new(hi - lo, hi - lo, flags)
    if hi > lo then _move(_ld(r + 16), _ld(l + 16) + 8 * lo, 8 * (hi - lo))
    r

fn list_concat(a int, b int, flags int) int
    na = _ld(a)
    nb = _ld(b)
    r = list_new(na + nb, na + nb, flags)
    if na > 0 then _move(_ld(r + 16), _ld(a + 16), 8 * na)
    if nb > 0 then _move(_ld(r + 16) + 8 * na, _ld(b + 16), 8 * nb)
    r

fn list_rep(l int, k int, flags int) int
    n = _ld(l)
    t = if k > 0 then n * k else 0
    r = list_new(t, t, flags)
    i = 0
    while i < t
        _st(_ld(r + 16) + 8 * i, _ld(_ld(l + 16) + 8 * (i % n)))
        i += 1
    r

# x в списке l; kind — вид элементов (строки сравниваются по содержимому)
fn list_has(x int, l int, kind int) bool
    i = 0
    while i < _ld(l)
        y = _ld(_ld(l + 16) + 8 * i)
        if eq(y, x, kind) then return true
        i += 1
    false
