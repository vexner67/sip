# Собственный бэкенд: проверенная программа -> машинный код arm64 -> Mach-O (без C, clang и ld).
#
# Подмножество: int, bool, str и списки (значение — регистр: число или адрес объекта), функции до 8
# аргументов, рекурсия, if/while/for по range, списку и строке, break/continue, return, print. Арифметика
# проверяется так же, как в C-бэкенде: переполнение — OverflowError, деление и остаток — с округлением
# вниз и ошибкой при нуле, индекс — IndexError; текст ошибки (файл:строка, вид, строка исходника)
# совпадает с C. Остальное — ошибка «native backend: ... not supported yet».
#
# Строки, списки и память — рантайм std/nrt.sip (на Sip, компилируется здесь же, без проверок
# переполнения): вызовы его функций генерируются как обычные; встроенные функции nrt (_ld, _st, ...)
# становятся отдельными командами.
#
# Оптимизации:
#   - функция генерируется дважды: пробный проход узнаёт, есть ли вызовы и сколько регистров x19..x28
#     нужно, чистовой пишет точный пролог (stp/ldp только нужных регистров) и эпилог в каждом return;
#   - листовая функция (без вызовов) держит переменные в x0..x8: параметры остаются, где пришли, кадра нет;
#   - значение, которое живёт через вызов, лежит в сохраняемом регистре x19..x28, а не в памяти;
#   - диапазоны: из условий (`if n < 2 then return ...`) известно, что n >= 2, и `n - 1` не проверяется;
#   - маленькие функции вида `fn f(x) = выражение` встраиваются в место вызова (рекурсивные — на один
#     уровень), а `// и %` на константу — без проверок, для степени двойки — сдвиг и маска;
#   - свёртка констант, цикл for в три команды на виток.
#
# Регистры: x9..x15 — промежуточные значения выражения, x16/x17 — рабочие, x0..x7 — аргументы и результат.

import arm64
import macho
import cgen
import checker
import modules
from arm64 import Asm, SP, ZR, FP, EQ, NE, LT, LE, GT, GE, VS, P2
from parser import N
from checker import Ty, Fn, Var, INT, BOOL, STR, UNIT
from creg import deep
from modules import SipErr, isn, nm

T0 = 9  # первый регистр промежуточных значений
TN = 15  # последний
VREG = [19, 20, 21, 22, 23, 24, 25, 26, 27, 28]  # сохраняемые вызываемой функцией
OUTBUF = 65536
NOANN = checker.Ann()
IMAX = 9223372036854775807
IMIN = -9223372036854775807 - 1
INLINE_SIZE = 40  # узлов в теле встраиваемой функции
INLINE_DEPTH = 3
# встроенные функции рантайма nrt без вызова (команды на месте)
PURE = ["sip_n_ld", "sip_n_st", "sip_n_ldb", "sip_n_stb", "sip_n_state", "sip_n_chars", "sip_n_addr",
        "sip_n_stack_top", "sip_n_bss_lo", "sip_n_bss_hi"]
IMPORTS = ["write", "exit", "mmap", "memmove", "memcmp", "bzero", "memchr"]

# имя extern-функции в C ("" — обычная функция)
fn ext_name(fi Fn) str = if checker.is_extern(fi.node) then fi.node.kids[8].kids[1].s else ""

fn inv(c int) int = c ^ 1

fn last_line(fi Fn) int
    body = fi.node.kids[3].kids
    if body then body[len(body) - 1].line else fi.node.line

fn bytes_of(s str) [int] = [ord(s[i]) for i in 0..len(s) - 1]

fn cond_of(op str) int
    if op == "==" then return EQ
    if op == "!=" then return NE
    if op == "<" then return LT
    if op == "<=" then return LE
    if op == ">" then return GT
    GE

# сравнение с переставленными операндами: a < b  <=>  b > a
fn flip(op str) str
    if op == "<" then return ">"
    if op == ">" then return "<"
    if op == "<=" then return ">="
    if op == ">=" then return "<="
    op

fn size(n N) int
    s = 1
    for k in n.kids
        s += size(k)
    s

# k, если x == 2**k (x > 0), иначе -1
fn log2(x int) int
    k = 0
    v = 1
    while v < x and k < 62
        v = v * 2
        k += 1
    if v == x then k else -1

# x op y без переполнения: (ok, значение)
fn fold(op str, x int, y int) (bool, int)
    if op == "+"
        if (y > 0 and x > IMAX - y) or (y < 0 and x < IMIN - y) then return (false, 0)
        return (true, x + y)
    if op == "-"
        if (y < 0 and x > IMAX + y) or (y > 0 and x < IMIN + y) then return (false, 0)
        return (true, x - y)
    if op == "*"
        if x > -3037000499 and x < 3037000499 and y > -3037000499 and y < 3037000499 then return (true, x * y)
        return (false, 0)
    if op == "&" then return (true, x & y)
    if op == "|" then return (true, x | y)
    if op == "^" then return (true, x ^ y)
    (false, 0)

# x // d для 0 <= x < 2**63 и 2 < d < 2**40 не степени двойки: (M, s), x // d == (x * M) >> (64 + s), где
# s = floor(log2 d), M = ceil(2**(64 + s) / d) < 2**64 (как int: 64 бита со знаком)
fn magic(d int) (int, int)
    s = 0
    while P2[s + 1] <= d
        s += 1
    # деление 2**(64 + s) на d столбиком; частное — два 32-битных куска
    r = 1
    qh = 0
    ql = 0
    for i in 1..64 + s
        r = r * 2
        bit = 0
        if r >= d
            r -= d
            bit = 1
        ql = ql * 2 + bit
        qh = qh * 2 + ql // P2[32]
        ql = ql % P2[32]
    ql += 1  # ceil: 2**(64 + s) на d не делится
    qh += ql // P2[32]
    ql = ql % P2[32]
    m = if qh >= P2[31] then (qh - P2[32]) * P2[32] + ql else qh * P2[32] + ql
    (m, s)

# объединение диапазонов
fn join(a (int, int), b (int, int)) (int, int) = (min(a[0], b[0]), max(a[1], b[1]))

fn full() (int, int) = (IMIN, IMAX)

# наименьшее 2**k - 1 >= x (x >= 0)
fn ones_above(x int) int
    m = 0
    while m < x
        m = m * 2 + 1
    m

# диапазон a op b по диапазонам операндов
fn range_op(op str, a (int, int), b (int, int)) (int, int)
    if a[0] > a[1] or b[0] > b[1] then return (IMAX, IMIN)
    if op == "+" or op == "-"
        lo_b = if op == "+" then b[0] else b[1]
        hi_b = if op == "+" then b[1] else b[0]
        ok1, lo = fold(op, a[0], lo_b)
        ok2, hi = fold(op, a[1], hi_b)
        if ok1 and ok2 then return (lo, hi)
        return full()
    if op == "*"
        c1, p1 = fold("*", a[0], b[0])
        c2, p2 = fold("*", a[0], b[1])
        c3, p3 = fold("*", a[1], b[0])
        c4, p4 = fold("*", a[1], b[1])
        if c1 and c2 and c3 and c4 then return (min(min(p1, p2), min(p3, p4)), max(max(p1, p2), max(p3, p4)))
        return full()
    if op == "&"
        if a[0] >= 0 and b[0] >= 0 then return (0, min(a[1], b[1]))
        if a[0] >= 0 then return (0, a[1])
        if b[0] >= 0 then return (0, b[1])
        return full()
    if (op == "|" or op == "^") and a[0] >= 0 and b[0] >= 0
        return (0, ones_above(max(a[1], b[1])))
    if (op == "//" or op == "/") and b[0] == b[1] and b[0] > 0
        return (a[0] // b[0], a[1] // b[0])
    if op == "%" and b[0] > 0
        if a[0] >= 0 then return (0, min(a[1], b[1] - 1))
        return (0, b[1] - 1)
    if op == "%" and b[1] < 0
        return (b[0] + 1, 0)
    full()

# x op y заведомо без переполнения (+, -, *): крайние значения — в углах интервалов
fn exact(op str, a (int, int), b (int, int)) bool
    if a[0] > a[1] or b[0] > b[1] then return false
    if op == "+" then return fold("+", a[0], b[0])[0] and fold("+", a[1], b[1])[0]
    if op == "-" then return fold("-", a[0], b[1])[0] and fold("-", a[1], b[0])[0]
    if op == "*"
        return fold("*", a[0], b[0])[0] and fold("*", a[0], b[1])[0] and fold("*", a[1], b[0])[0] and fold("*", a[1], b[1])[0]
    false

# где живёт переменная: регистр (reg >= 0), ячейка кадра номер slot (reg == -1) или это константа
# slot (reg == -2: аргумент встроенной функции)
type Home(reg int, slot int)

# сколько промежуточных регистров нужно выражению при нашей схеме (r — результат, r + 1 — правый операнд)
fn regs_needed(n N) int
    k = n.kind
    if k == "Name" or k == "Num" or k == "Const" then return 1
    if k == "BinOp" then return max(regs_needed(n.kids[1]), regs_needed(n.kids[2]) + 1)
    if k == "Unary" then return regs_needed(n.kids[1])
    if k == "IfExpr" then return max(regs_needed(n.kids[0]), max(regs_needed(n.kids[1]), regs_needed(n.kids[2])))
    if k == "Compare"
        best = regs_needed(n.kids[0])
        for o in n.kids[1].kids
            best = max(best, regs_needed(o.kids[1]) + 1)
        return best + 1
    if k == "Call"
        best = 1
        for i, a in enumerate(n.kids[1].kids)
            best = max(best, regs_needed(a) + i)
        return best + 1
    8

# часть склейки строк: литерал text (node == nil) или выражение; num — int, который пишется цифрами
type Piece(node N?, text str, num bool)

# откат: факт о переменной name до изменения (had — был ли)
type Undo(name str, had bool, lo int, hi int)

type NGen(c checker.Checker, ld modules.Loader, file str, a Asm, homes {str: Home} = {},
          fi Fn? = nil, brk [str] = [], cont [str] = [], nhid int = 0,
          stubs {str: str} = {}, stub_list [(str, str, int)] = [], queue [Fn] = [], seen {str: bool} = {},
          measuring bool = false, leaf bool = false, ncalls int = 0, nvreg int = 0, maxv int = 0,
          holds [int] = [], live [int] = [], used_tslot bool = false, nslots int = 0, nsave int = 0,
          frame int = 0, slot_base int = 0, tslot int = 0, facts {str: (int, int)} = {}, fstack [Undo] = [],
          mut {str: bool} = {}, inl [str] = [], shared {str: bool} = {},
          cold [(str, str, str, int, int, int)] = [], inv {str: (int, int)} = {}, cregs {int: int} = {},
          trusted bool = false)

    fn no(what str, node N?)
        line = if node == nil then 0 else node.line
        fail SipErr("native backend: {what} not supported yet", .file, line, 0)

    fn an(n N) checker.Ann = if n.an == 0 then NOANN else .c.ans[n.an]

    fn ty(n N) Ty
        a = .an(n)
        if a.cty != nil
            ct: Ty = a.cty
            return deep(ct)
        deep(.c.tys[n.ty])

    fn scalar(t Ty) bool = t.id == INT.id or t.id == BOOL.id

    # значение в одном регистре: int, bool, str или список (адрес объекта)
    fn word(t Ty) bool
        if .scalar(t) or t.id == STR.id then return true
        t.k == "list" and .word(deep(t.a[0]))

    fn need(n N)
        t = .ty(n)
        if not .word(t) then .no("type {checker.show(t)}", n)

    fn is_str(n N) bool = .ty(n).id == STR.id

    fn is_list(n N) bool = .ty(n).k == "list"

    # вид значения для рантайма: 0 int, 1 bool, 2 str, 3 + 4 * вид элемента — список
    fn kind_of(t Ty) int
        if t.id == INT.id then return 0
        if t.id == BOOL.id then return 1
        if t.id == STR.id then return 2
        3 + 4 * .kind_of(deep(t.a[0]))

    # флаги данных списка типа t: 2 — элементы не ссылки (сборщик их не сканирует)
    fn lflags(t Ty) int = if .scalar(deep(t.a[0])) then 2 else 0

    # функция рантайма nrt
    fn nrt(name str) Fn
        key = "std__nrt__" + name
        if key not in .c.fns then fail SipErr("native runtime: no function {name}", .file, 0, 0)
        fi: Fn = .c.fns[key]
        fi

    fn cur() Fn
        f: Fn = .fi
        f

    # ---------- ошибки времени выполнения ----------

    # переход на заглушку, которая печатает ошибку как C-рантайм и завершает программу
    fn stub(kind str, msg str, line int) str
        if .measuring then return "t:dummy"
        key = "{kind}|{msg}|{line}"
        if key in .stubs then return .stubs[key]
        f, local = .ld.locate(line)
        text = "{f}:{local}: {kind}"
        if msg != "" then text = text + ": " + msg
        text = text + "\n"
        for i, fp in enumerate(.ld.files)
            if fp[1] == f
                src = .ld.srcs[i]
                if local > 0 and local <= len(src)
                    s = src[local - 1]
                    j = 0
                    while j < len(s) and s[j] == " "
                        j += 1
                    text = text + "    " + s[j:] + "\n"
        bs = bytes_of(text)
        label = .a.new_label("err")
        .stubs[key] = label
        .stub_list.append((label, .a.cstr(bs), len(bs)))
        label

    fn overflow(line int) str = .stub("OverflowError", "integer overflow", line)

    fn emit_stubs()
        for kind, label, back, r, x, line in .cold  # редкие пути деления на -1
            .a.here(label)
            if kind == "div"
                .a.negs(r, x)
                .a.bcond(VS, .overflow(line))
            else
                .a.movz(r, 0, 0)
            .a.b(back)
        .cold = []
        for label, cl, n in .stub_list
            .a.here(label)
            .a.adr(0, cl)
            .a.mov_imm(1, n)
            .a.b("t:rt_die")
        .stub_list = []

    # ---------- переменные ----------

    fn var_of(n N) Var
        a = .an(n)
        if a.var == nil then .no("this name", n)
        v: Var = a.var
        v

    # глобальная переменная в памяти (не перенесена в регистр верхнего уровня)
    fn in_mem(v Var) bool = v.kind == "global" and v.cname not in .homes

    fn glabel(v Var) str = .a.bslot("g_" + v.cname, 8)

    fn slot_off(slot int) int = .slot_base + 8 * slot

    # значение переменной в регистре: её собственный регистр или r
    fn load_var(v Var, r int) int
        if .in_mem(v)
            .a.ldr_label(r, .glabel(v))
            return r
        h = .homes[v.cname]
        if h.reg >= 0 then return h.reg
        if h.reg == -2
            .a.mov_imm(r, h.slot)
            return r
        .a.ldr(r, SP, .slot_off(h.slot))
        r

    fn store_var(v Var, src int)
        if .in_mem(v)
            .a.str_label(src, .glabel(v), 16)
            return
        h = .homes[v.cname]
        if h.reg >= 0
            .mv(h.reg, src)
        else
            .a.str_(src, SP, .slot_off(h.slot))

    # ---------- факты о диапазонах ----------
    # Только о переменных, которым в функции ничего не присваивается (параметры, встроенные аргументы):
    # такой факт верен до конца области, где его вывели.

    fn mark() int = len(.fstack)

    fn undo(m int)
        while len(.fstack) > m
            u = .fstack.pop()
            .facts[u.name] = if u.had then (u.lo, u.hi) else (IMIN, IMAX)

    fn range_of(name str) (int, int) = if name in .facts then .facts[name] else (IMIN, IMAX)

    fn set_range(name str, lo int, hi int)
        old = .range_of(name)
        .fstack.append(Undo(name, name in .facts, old[0], old[1]))
        .facts[name] = (max(old[0], lo), min(old[1], hi))

    # неизменяемая локальная переменная под именем e (или "")
    fn fixed_name(e N) str
        if e.kind != "Name" then return ""
        a = .an(e)
        if a.var == nil then return ""
        v: Var = a.var
        if v.kind == "global" or v.cname in .mut then return ""
        v.cname

    # диапазон значения выражения (интервалы; (IMAX, IMIN) — пусто: значение ещё не встречалось)
    fn range_e(e N) (int, int)
        ok, v = .const_val(e)
        if ok then return (v, v)
        if .ty(e).id == BOOL.id then return (0, 1)
        k = e.kind
        if k == "Name"
            name = .fixed_name(e)
            if name != "" then return .range_of(name)
            a = .an(e)
            if a.var != nil
                vv: Var = a.var
                if vv.cname in .inv and not .in_mem(vv) then return .inv[vv.cname]
            return (IMIN, IMAX)
        if k == "BinOp" and .ty(e).id == INT.id
            return range_op(e.kids[0].s, .range_e(e.kids[1]), .range_e(e.kids[2]))
        if k == "Unary" and e.kids[0].s == "-"
            lo, hi = .range_e(e.kids[1])
            if lo > hi then return (lo, hi)
            if lo > IMIN then return (-hi, -lo)
        if k == "IfExpr"  # в каждой ветке известно, чему равно условие
            m = .mark()
            .assume(e.kids[0], true)
            ra = .range_e(e.kids[1])
            .undo(m)
            .assume(e.kids[0], false)
            rb = .range_e(e.kids[2])
            .undo(m)
            return join(ra, rb)
        (IMIN, IMAX)

    # диапазоны изменяемых переменных функции: объединение по всем присваиваниям до неподвижной точки;
    # что не устоялось за несколько кругов — весь int
    fn invariant_ranges(fi Fn)
        .inv = {}
        sets: [(str, N, N?)] = []  # (имя, выражение или начало диапазона for, конец диапазона for)
        for st in fi.body
            .collect_sets(st, sets)
        for st3 in sets
            .inv[st3[0]] = (IMAX, IMIN)
        for p in fi.params
            .inv[fi.locals[p.name].cname] = (IMIN, IMAX)
        rounds = 0
        changed = true
        while changed and rounds < 6
            changed = false
            rounds += 1
            for name, e, hi_e in sets
                r = if hi_e == nil then .range_e(e) else .for_range_of(e, hi_e)
                old = .inv[name]
                nw = join(old, r)
                if nw != old
                    .inv[name] = nw
                    changed = true
        if changed  # не сошлось: расширить до всего int то, что ещё росло на последнем круге
            for name, e, hi_e in sets
                r = if hi_e == nil then .range_e(e) else .for_range_of(e, hi_e)
                if join(.inv[name], r) != .inv[name] then .inv[name] = (IMIN, IMAX)
            # и всё, что от них зависит
            again = true
            while again
                again = false
                for name, e, hi_e in sets
                    r = if hi_e == nil then .range_e(e) else .for_range_of(e, hi_e)
                    if join(.inv[name], r) != .inv[name]
                        .inv[name] = (IMIN, IMAX)
                        again = true
        pass

    fn for_range_of(lo_e N, hi_e0 N?) (int, int)
        hi_e: N = hi_e0
        a = .range_e(lo_e)
        b = .range_e(hi_e)
        if a[0] > a[1] or b[0] > b[1] then return (IMAX, IMIN)
        (a[0], b[1])

    # присваивания переменным функции: x = e, x op= e (как x op e), for x in a..b, a, b = x, y
    fn collect_sets(n N, out [(str, N, N?)])
        k = n.kind
        if k == "Assign"
            targets = n.kids[0].kids
            if len(targets) == 1 and targets[0].kind == "TupleLit" and n.kids[1].kind == "TupleLit"
                items = targets[0].kids[0].kids
                vals = n.kids[1].kids[0].kids
                if len(items) == len(vals)
                    for i, t in enumerate(items)
                        .set_of(t, vals[i], out)
            else
                for t in targets
                    .set_of(t, n.kids[1], out)
        elif k == "AnnAssign" and not isn(n.kids[2])
            .set_of(n.kids[0], n.kids[2], out)
        elif k == "AugAssign" and .an(n).n3 != nil
            a3: N = .an(n).n3
            .collect_sets(a3, out)
        elif k == "AugAssign"
            a = .an(n)
            if a.n2 != nil
                b: N = a.n2
                .set_of(n.kids[0], b, out)
        elif k == "For" and n.kids[0].kind == "Name" and n.kids[1].kind == "Range"
            name = .set_name(n.kids[0])
            hi_e: N? = n.kids[1].kids[1]
            if name != "" then out.append((name, n.kids[1].kids[0], hi_e))
        for c in n.kids
            .collect_sets(c, out)

    fn set_name(t N) str
        if t.kind != "Name" or t.an == 0 or .an(t).var == nil then return ""
        v: Var = .an(t).var
        if v.kind == "param" then return ""
        v.cname

    fn set_of(t N, e N, out [(str, N, N?)])
        name = .set_name(t)
        if name != "" then out.append((name, e, nil))

    # запомнить, что условие c истинно (truth) или ложно
    fn assume(c N, truth bool)
        k = c.kind
        if k == "Unary" and c.kids[0].s == "not"
            .assume(c.kids[1], not truth)
        elif k == "BinOp" and ((c.kids[0].s == "and" and truth) or (c.kids[0].s == "or" and not truth))
            .assume(c.kids[1], truth)
            .assume(c.kids[2], truth)
        elif k == "Compare" and len(c.kids[1].kids) == 1
            op = c.kids[1].kids[0].kids[0].s
            left = c.kids[0]
            right = c.kids[1].kids[0].kids[1]
            if .ty(left).id != INT.id or .ty(right).id != INT.id then return
            if .fixed_name(left) == "" and .fixed_name(right) != ""
                left, right = right, left
                op = flip(op)
            name = .fixed_name(left)
            if name == "" then return
            lo, hi = .range_e(right)
            if not truth
                if op == "<" then op = ">="
                elif op == "<=" then op = ">"
                elif op == ">" then op = "<="
                elif op == ">=" then op = "<"
                elif op == "==" then op = "!="
                else op = "=="
            if op == "<" and hi > IMIN then .set_range(name, IMIN, hi - 1)
            elif op == "<=" then .set_range(name, IMIN, hi)
            elif op == ">" and lo < IMAX then .set_range(name, lo + 1, IMAX)
            elif op == ">=" then .set_range(name, lo, IMAX)
            elif op == "==" then .set_range(name, lo, hi)
            elif op == "!=" and lo == hi  # x != c на краю диапазона x сужает его
                cur = .range_of(name)
                if cur[0] == lo and lo < IMAX then .set_range(name, lo + 1, IMAX)
                elif cur[1] == lo and lo > IMIN then .set_range(name, IMIN, lo - 1)
        pass

    # ---------- константы ----------

    fn const_val(e N) (bool, int)
        k = e.kind
        if k == "Num" and .ty(e).id == INT.id
            text = nm(e).replace("_", "")
            if len(text) > 19 or (len(text) == 19 and text >= "9223372036854775808") then return (false, 0)
            return (true, int(text))
        if k == "Const" and .ty(e).id == BOOL.id
            return (true, if nm(e) == "True" then 1 else 0)
        if k == "Name" and e.an != 0 and .an(e).var == nil and (.an(e).name == "true" or .an(e).name == "false")
            return (true, if .an(e).name == "true" then 1 else 0)  # True/False как в Python
        if k == "Name" and e.an != 0 and .an(e).var != nil
            nv: Var = .an(e).var
            if nv.kind != "global" and nv.cname in .homes and .homes[nv.cname].reg == -2
                return (true, .homes[nv.cname].slot)
            return (false, 0)
        if k == "Unary" and e.kids[0].s == "-" and .ty(e).id == INT.id
            ok, v = .const_val(e.kids[1])
            if ok and v != IMIN then return (true, -v)
            return (false, 0)
        if k == "Unary" and e.kids[0].s == "not" and .ty(e.kids[1]).id == BOOL.id
            ok, v = .const_val(e.kids[1])
            return (ok, if ok then 1 - v else 0)
        if k == "Compare"
            nodes = [e.kids[0]] + [o.kids[1] for o in e.kids[1].kids]
            vals: [int] = []
            for n in nodes
                if not .scalar(.ty(n)) then return (false, 0)
                okn, vn = .const_val(n)
                if not okn then return (false, 0)
                vals.append(vn)
            res = true
            for i, o in enumerate(e.kids[1].kids)
                op = o.kids[0].s
                x = vals[i]
                y = vals[i + 1]
                t = false
                if op == "==" then t = x == y
                elif op == "!=" then t = x != y
                elif op == "<" then t = x < y
                elif op == "<=" then t = x <= y
                elif op == ">" then t = x > y
                elif op == ">=" then t = x >= y
                else return (false, 0)
                if not t then res = false
            return (true, if res then 1 else 0)
        if k == "BinOp" and (e.kids[0].s == "and" or e.kids[0].s == "or") and .ty(e).id == BOOL.id
            oka, va = .const_val(e.kids[1])
            okb, vb = .const_val(e.kids[2])
            if e.kids[0].s == "and"
                if oka and va == 0 then return (true, 0)
                if oka and okb then return (true, vb)
            else
                if oka and va != 0 then return (true, 1)
                if oka and okb then return (true, vb)
            return (false, 0)
        if k == "BinOp" and .ty(e).id == INT.id
            ok1, x = .const_val(e.kids[1])
            if not ok1 then return (false, 0)
            ok2, y = .const_val(e.kids[2])
            if not ok2 then return (false, 0)
            return fold(e.kids[0].s, x, y)
        (false, 0)

    # небольшая неотрицательная константа (для команд с непосредственным операндом)
    fn small(e N) int
        ok, v = .const_val(e)
        if ok and v >= 0 and v <= 4095 then v else -1

    # ---------- регистры ----------

    # r — промежуточный регистр (x9..x15) или регистр переменной, в который считается простое выражение
    fn chk(r int, node N?)
        if (r > TN and r < 19) or r > 28 then .no("expression this deep", node)

    # сохраняемый регистр для значения, которое переживёт вызов; -1 — все заняты
    fn hold() int
        i = .nvreg + len(.holds)
        if i >= len(VREG) then return -1
        .holds.append(VREG[i])
        .maxv = max(.maxv, i + 1)
        VREG[i]

    # x нужно сохранить, пока вычисляется что-то с вызовом (calls): вернуть, где оно теперь
    fn protect(x int, calls bool) int
        if not calls or .leaf or x >= 19 then return x
        h = .hold()
        if h >= 0
            .mv(h, x)
            return h
        .live.append(x)  # запасной путь: call() сохранит его в кадре
        x

    # dst = src; если src — промежуточный регистр, его значение дальше не нужно
    fn mv(dst int, src int)
        if src >= T0 and src <= TN then .a.mov_tmp(dst, src) else .a.mov(dst, src)

    fn release(x int)
        if .holds and .holds[len(.holds) - 1] == x
            .holds.pop()
        elif .live and .live[len(.live) - 1] == x
            .live.pop()
        pass

    # вызов функции (или подпрограммы рантайма) в этом выражении
    fn has_call(n N) bool
        k = n.kind
        if k == "Call"
            a = .an(n)
            if a.ckind == "builtin"
                if a.name != "abs" and a.name != "len" then return true
            elif a.ckind == "fn" and a.f != nil
                fi: Fn = a.f
                if ext_name(fi) not in PURE then return true
            else
                return true
        elif k == "Str"
            for p in n.kids[0].kids
                if p.kind == "Interp" then return true
        elif k == "BinOp"
            if not .scalar(.ty(n)) then return true
        elif k == "Compare"
            if not .scalar(.ty(n.kids[0])) then return true
            for o in n.kids[1].kids
                if not .scalar(.ty(o.kids[1])) or o.kids[0].s == "in" or o.kids[0].s == "not in" then return true
        elif k == "Index"
            if n.s == "slice_str" or n.s == "slice_list" then return true
        elif k == "ListLit" or k == "ListComp"
            return true
        for c in n.kids
            if .has_call(c) then return true
        false

    # ---------- выражения ----------

    # значение e в регистре: если e — переменная в регистре, то её регистр, иначе r
    fn opnd(e N, r int) int
        ok, cv = .const_val(e)
        if ok and cv in .cregs then return .cregs[cv]
        if e.kind == "Name"
            a = .an(e)
            if a.var != nil
                v: Var = a.var
                .need(e)
                return .load_var(v, r)
        .gen(e, r)
        r

    fn gen(e N, r int)
        .chk(r, e)
        k = e.kind
        ok, cv = .const_val(e)
        if ok and cv in .cregs
            .a.mov(r, .cregs[cv])
            return
        if ok
            .a.mov_imm(r, cv)
            return
        if k == "Num"
            if .ty(e).id != INT.id then .no("float", e)
            fail SipErr("integer literal is too large for int (64-bit)", .file, e.line, 0)
        elif k == "Const"
            .no("None", e)
        elif k == "Name"
            if .an(e).var == nil then .no("this name", e)
            got = .opnd(e, r)
            .a.mov(r, got)
        elif k == "BinOp"
            .binop(e, r)
        elif k == "Compare" or (k == "Unary" and e.kids[0].s == "not")
            .need(e)
            if k == "Compare" and len(e.kids[1].kids) == 1
                op = e.kids[1].kids[0]
                c = .compare(e.kids[0], op.kids[0].s, op.kids[1], r, e)
                .a.cset(r, c)
            else
                .bool_value(e, r)
        elif k == "Unary"
            .need(e)
            uop = e.kids[0].s
            x = .opnd(e.kids[1], r)
            if uop == "-"
                lo, _ = .range_e(e.kids[1])
                if lo > IMIN or .trusted
                    .a.sub(r, ZR, x)
                else
                    .a.negs(r, x)
                    .a.bcond(VS, .overflow(e.line))
            elif uop == "~"
                .a.mvn(r, x)
            elif uop == "+"
                .a.mov(r, x)
            else
                .no("unary {uop}", e)
        elif k == "IfExpr" and .const_val(e.kids[0])[0]
            .gen(if .const_val(e.kids[0])[1] != 0 then e.kids[1] else e.kids[2], r)
        elif k == "IfExpr"
            .need(e)
            lelse = .a.new_label("else")
            lend = .a.new_label("end")
            .cjump(e.kids[0], lelse, false, r)
            m = .mark()
            .assume(e.kids[0], true)
            .gen(e.kids[1], r)
            .undo(m)
            .a.b(lend)
            .a.here(lelse)
            .assume(e.kids[0], false)
            .gen(e.kids[2], r)
            .undo(m)
            .a.here(lend)
        elif k == "Call"
            .call(e, r)
        elif k == "Str"
            .str_value(e, r)
        elif k == "Index"
            .index(e, r)
        elif k == "ListLit"
            .list_lit(e, r)
        else
            .no(k, e)
        pass

    # bool как значение через переходы (and, or, not, цепочки сравнений)
    fn bool_value(e N, r int)
        lf = .a.new_label("f")
        lend = .a.new_label("end")
        .cjump(e, lf, false, r)
        .a.movz(r, 1, 0)
        .a.b(lend)
        .a.here(lf)
        .a.movz(r, 0, 0)
        .a.here(lend)

    fn binop(e N, r int)
        op = e.kids[0].s
        if op == "and" or op == "or"
            if .ty(e).id != BOOL.id then .no("'{op}' on non-bool values", e)
            .bool_value(e, r)
            return
        .need(e.kids[1])
        .need(e.kids[2])
        .need(e)
        t = .ty(e)
        if t.id == STR.id and op == "+"
            .str_value(e, r)
        elif t.k == "list" and op == "+"
            .rcall("list_concat", [e.kids[1], e.kids[2]], [.lflags(t)], r)
        elif t.k == "list" and op == "*" and .is_list(e.kids[1])
            .rcall("list_rep", [e.kids[1], e.kids[2]], [.lflags(t)], r)
        elif not .scalar(t)
            .no("operator {op} on {checker.show(t)}", e)
        else
            .arith(op, e.kids[1], e.kids[2], r, r, e.line, e)

    # r = left op right; операнды — в промежуточных sc и sc + 1, результат пишется в r последним
    fn arith(op str, left N, right N, r int, sc int, line int, e N)
        ok, c = .const_val(right)
        .chk(sc + 1, e)
        if ok and .arith_const(op, left, c, r, sc, line)
            return
        okl, cl = .const_val(left)
        if okl and (op == "*" or op == "+" or op == "&") and not ok and .arith_const(op, right, cl, r, sc, line)
            return
        lr = .range_e(left)
        rr = .range_e(right)
        x = .opnd(left, sc)
        x = .protect(x, .has_call(right))
        y = .opnd(right, sc + 1)
        .op3(op, r, x, y, line, e, lr, rr)
        .release(x)

    # left op константа c; false — нет особого случая
    # r — куда результат (пишется последней командой), sc — промежуточный регистр для левого операнда
    fn arith_const(op str, left N, c int, r int, sc int, line int) bool
        lo, hi = .range_e(left)
        if op == "+" or op == "-"
            if c < -4095 or c > 4095 then return false
            d = if op == "+" then c else -c
            safe = (d >= 0 and hi <= IMAX - d) or (d < 0 and lo >= IMIN - d) or .trusted
            x = .opnd(left, sc)
            if safe
                if d >= 0 then .a.add_imm(r, x, d) else .a.sub_imm(r, x, -d)
            else
                if d >= 0 then .a.adds_imm(r, x, d) else .a.subs_imm(r, x, -d)
                .a.bcond(VS, .overflow(line))
            return true
        if op == "*" and c >= 0 and c <= 5
            x = .opnd(left, sc)
            if c == 0
                .a.movz(r, 0, 0)
            elif c == 1
                .a.mov(r, x)
            elif exact("*", (lo, hi), (c, c))
                if c == 2
                    .a.add(r, x, x)
                elif c == 4
                    .a.add(16, x, x)
                    .a.add(r, 16, 16)
                else
                    .a.mul(r, x, .creg_or(c, 17))
            else  # сложениями: у частичных сумм тот же знак, переполнение — ровно когда у произведения
                ovf = .overflow(line)
                .a.adds(16, x, x)  # 2x
                .a.bcond(VS, ovf)
                if c == 2
                    .a.mov(r, 16)
                elif c == 3
                    .a.adds(r, 16, x)
                    .a.bcond(VS, ovf)
                elif c == 4
                    .a.adds(r, 16, 16)
                    .a.bcond(VS, ovf)
                else
                    .a.adds(16, 16, 16)
                    .a.bcond(VS, ovf)
                    .a.adds(r, 16, x)
                    .a.bcond(VS, ovf)
            return true
        if op == "*" and c > 5 and log2(c) > 0
            k = log2(c)
            x = .opnd(left, sc)
            if exact("*", (lo, hi), (c, c)) or .trusted
                .a.lsl(r, x, k)
            else  # сдвиг обратно должен вернуть x
                .a.lsl(16, x, k)
                .a.cmp_asr(x, 16, k)
                .a.bcond(NE, .overflow(line))
                .a.mov(r, 16)
            return true
        if op == "&" and c > 0 and c < IMAX and log2(c + 1) > 0
            x = .opnd(left, sc)
            .a.and_low(r, x, log2(c + 1))
            return true
        if (op == "/" or op == "//" or op == "%") and c > 0
            x = .opnd(left, sc)
            k = log2(c)
            if k == 0
                if op == "%" then .a.movz(r, 0, 0) else .a.mov(r, x)
            elif k > 0
                if op == "%" then .a.and_low(r, x, k) else .a.asr(r, x, k)
            elif lo >= 0 and c < P2[40]  # делимое неотрицательно: x // c = (x * M) >> (64 + s), M — магическое
                m, sh = magic(c)
                mr = .creg_or(m, 17)
                if op == "%"
                    .a.umulh(16, x, mr)
                    .a.lsr(16, 16, sh)
                    cr = .creg_or(c, 17)
                    .a.msub(r, 16, cr, x)
                else
                    .a.umulh(r, x, mr)
                    .a.lsr(r, r, sh)
            else
                cr = .creg_or(c, 17)
                .a.sdiv(16, x, cr)
                .a.msub(17, 16, cr, x)  # остаток со знаком x
                .a.cmp_imm(17, 0)
                if op == "%"
                    if cr == 17
                        .a.mov_imm(16, c)
                        .a.add(16, 17, 16)
                    else
                        .a.add(16, 17, cr)
                    .a.csel(r, 16, 17, LT)
                else
                    .a.sub_imm(17, 16, 1)
                    .a.csel(r, 17, 16, LT)
            return true
        false

    # регистр с константой c: вынесенный из цикла или scratch
    fn creg_or(c int, scratch int) int
        if c in .cregs then return .cregs[c]
        .a.mov_imm(scratch, c)
        scratch

    # r = x op y (регистры)
    fn op3(op str, r int, x int, y int, line int, e N, lr (int, int), rr (int, int))
        safe = exact(op, lr, rr) or .trusted
        pos = rr[0] > 0 and rr[0] <= rr[1]  # делитель заведомо > 0: ни нуля, ни -1
        if op == "+" and safe
            if not (x >= T0 and x <= TN and .a.fuse_madd(r, x, y)) and not (y >= T0 and y <= TN and .a.fuse_madd(r, y, x))
                .a.add(r, x, y)
        elif op == "+"
            .a.adds(r, x, y)
            .a.bcond(VS, .overflow(line))
        elif op == "-" and safe
            .a.sub(r, x, y)
        elif op == "-"
            .a.subs(r, x, y)
            .a.bcond(VS, .overflow(line))
        elif op == "*" and safe
            .a.mul(r, x, y)
        elif op == "*"
            .a.smulh(16, x, y)
            .a.mul(r, x, y)
            .a.cmp_asr63(16, r)
            .a.bcond(NE, .overflow(line))
        elif (op == "/" or op == "//" or op == "%") and pos and lr[0] >= 0 and lr[0] <= lr[1]
            if op == "%"
                .a.sdiv(16, x, y)
                .a.msub(r, 16, y, x)
            else
                .a.sdiv(r, x, y)
        elif op == "/" or op == "//"
            .floordiv(r, x, y, line)
        elif op == "%"
            .modulo(r, x, y, line)
        elif op == "&"
            .a.and_(r, x, y)
        elif op == "|"
            .a.orr(r, x, y)
        elif op == "^"
            .a.eor(r, x, y)
        else
            .no("operator {op}", e)
        pass

    # деление с округлением вниз, как sip_floordiv; делитель -1 — в холодном хвосте функции
    fn floordiv(r int, x int, y int, line int)
        .a.cbz(y, .stub("ZeroDivisionError", "division by zero", line))
        lm1 = .a.new_label("m1")
        lend = .a.new_label("end")
        .a.cmn_imm(y, 1)
        .a.bcond(EQ, lm1)
        .a.sdiv(16, x, y)
        .a.msub(17, 16, y, x)  # остаток
        .a.cmp_imm(17, 0)
        .a.eor(17, 17, y)
        .a.ccmp_imm(17, 0, 0, NE)  # «меньше» — остаток не 0 и его знак не как у делителя
        .a.sub_imm(17, 16, 1)
        .a.csel(r, 17, 16, LT)
        .a.here(lend)
        .cold.append(("div", lm1, lend, r, x, line))

    # остаток со знаком делителя, как sip_mod
    fn modulo(r int, x int, y int, line int)
        .a.cbz(y, .stub("ZeroDivisionError", "modulo by zero", line))
        lm1 = .a.new_label("m1")
        lend = .a.new_label("end")
        .a.cmn_imm(y, 1)
        .a.bcond(EQ, lm1)
        .a.sdiv(16, x, y)
        .a.msub(17, 16, y, x)
        .a.eor(16, 17, y)
        .a.cmp_imm(17, 0)
        .a.ccmp_imm(16, 0, 0, NE)  # остаток 0 — флаги «не меньше»
        .a.add(16, 17, y)
        .a.csel(r, 16, 17, LT)
        .a.here(lend)
        .cold.append(("mod", lm1, lend, r, x, line))

    # флаги сравнения left и right (int или bool); r — свободный регистр; условие «истинно»
    fn compare(left0 N, op0 str, right0 N, r int, e N) int
        left = left0
        right = right0
        op = op0
        lt = .ty(left)
        rt = .ty(right)
        if (op == "in" or op == "not in") and rt.id == STR.id and lt.id == STR.id
            .rcall("has_sub", [left, right], [], r)
            .a.cmp_imm(r, 0)
            return if op == "in" then NE else EQ
        if (op == "in" or op == "not in") and rt.k == "list" and .word(lt)
            .rcall("list_has", [left, right], [.kind_of(lt)], r)
            .a.cmp_imm(r, 0)
            return if op == "in" then NE else EQ
        if lt.id == STR.id and rt.id == STR.id and op != "is" and op != "is not"
            if op == "==" or op == "!="
                .rcall("str_eq", [left, right], [], r)
                .a.cmp_imm(r, 0)
                return if op == "==" then NE else EQ
            .rcall("str_cmp", [left, right], [], r)
            .a.cmp_imm(r, 0)
            return cond_of(op)
        if not .scalar(lt) or not .scalar(rt) or op == "in" or op == "not in" or op == "is" or op == "is not"
            .no("comparison '{op}' of {checker.show(lt)} and {checker.show(rt)}", e)
        if .small(left) >= 0 and .small(right) < 0
            left, right = right, left
            op = flip(op)
        x = .opnd(left, r)
        imm = .small(right)
        if imm >= 0
            .a.cmp_imm(x, imm)
            return cond_of(op)
        x = .protect(x, .has_call(right))
        y = .opnd(right, r + 1)
        .a.cmp(x, y)
        .release(x)
        cond_of(op)

    fn is_mod(e N) bool = e.kind == "BinOp" and e.kids[0].s == "%" and .ty(e).id == INT.id

    # x % y == 0 (zero) или != 0: остаток нулевой при любом округлении, поправка не нужна
    fn rem_jump(e N, zero bool, label str, when bool, r int)
        x0 = e.kids[1]
        y0 = e.kids[2]
        on_zero = zero == when  # прыгать, когда остаток ноль
        ok, c = .const_val(y0)
        if ok and c > 0 and log2(c) >= 1
            x = .opnd(x0, r)
            k = log2(c)
            if k == 1
                if on_zero then .a.tbz(x, 0, label) else .a.tbnz(x, 0, label)
                return
            .a.and_low(16, x, k)
            if on_zero then .a.cbz(16, label) else .a.cbnz(16, label)
            return
        x = .opnd(x0, r)
        if ok and c != 0
            y = .creg_or(c, 17)
            .a.sdiv(16, x, y)
            .a.msub(16, 16, y, x)
        else
            x = .protect(x, .has_call(y0))
            y = .opnd(y0, r + 1)
            .release(x)
            .a.cbz(y, .stub("ZeroDivisionError", "modulo by zero", e.line))
            .a.sdiv(16, x, y)  # INT64_MIN // -1 даёт INT64_MIN, остаток всё равно 0
            .a.msub(16, 16, y, x)
        if on_zero then .a.cbz(16, label) else .a.cbnz(16, label)

    # переход на label, если e истинно (when) или ложно (not when)
    fn cjump(e N, label str, when bool, r int)
        k = e.kind
        if k == "Compare"
            ops = e.kids[1].kids
            if len(ops) == 1
                op = ops[0].kids[0].s
                right = ops[0].kids[1]
                if (op == "==" or op == "!=") and .small(right) == 0 and .is_mod(e.kids[0])
                    .rem_jump(e.kids[0], op == "==", label, when, r)
                    return
                if (op == "==" or op == "!=") and .small(right) == 0 and .scalar(.ty(e.kids[0]))
                    x = .opnd(e.kids[0], r)
                    if (op == "==") == when then .a.cbz(x, label) else .a.cbnz(x, label)
                    return
                c = .compare(e.kids[0], op, right, r, e)
                .a.bcond(if when then c else inv(c), label)
                return
            # a < b < c: каждое звено по очереди, средние операнды вычисляются один раз
            skip = .a.new_label("skip")
            nodes = [e.kids[0]] + [o.kids[1] for o in ops]
            for n in nodes
                .need(n)
                if not .scalar(.ty(n)) then .no("chained comparison of {checker.show(.ty(n))}", e)
            .chk(r + 1, e)
            .gen(nodes[0], r)
            for i, o in enumerate(ops)
                op = o.kids[0].s
                x = .protect(r, .has_call(nodes[i + 1]))
                .gen(nodes[i + 1], r + 1)
                .a.cmp(x, r + 1)
                .release(x)
                c = cond_of(op)
                last = i == len(ops) - 1
                if when and last
                    .a.bcond(c, label)
                elif when
                    .a.bcond(inv(c), skip)
                else
                    .a.bcond(inv(c), label)
                if not last then .a.mov(r, r + 1)
            .a.here(skip)
            return
        if k == "Unary" and e.kids[0].s == "not"
            .cjump(e.kids[1], label, not when, r)
            return
        if k == "BinOp" and (e.kids[0].s == "and" or e.kids[0].s == "or")
            is_and = e.kids[0].s == "and"
            m = .mark()
            if is_and != when  # and и «ложно» или or и «истинно»: любой операнд решает
                .cjump(e.kids[1], label, when, r)
                .assume(e.kids[1], not when)
                .cjump(e.kids[2], label, when, r)
            else
                skip = .a.new_label("skip")
                .cjump(e.kids[1], skip, not when, r)
                .assume(e.kids[1], when)
                .cjump(e.kids[2], label, when, r)
                .a.here(skip)
            .undo(m)
            return
        ok, v = .const_val(e)
        if ok
            if (v != 0) == when then .a.b(label)
            return
        .need(e)
        x = .opnd(e, r)
        if when then .a.cbnz(x, label) else .a.cbz(x, label)

    # ---------- вызовы ----------

    fn user_fn(e N) Fn
        a = .an(e)
        if a.ckind != "fn" then .no("this kind of call", e)
        fi: Fn = a.f
        if fi.std and not fi.cname.startswith("f_std__nrt__") then .no("standard library function {fi.name}()", e)
        if fi.parent != nil or fi.owner != nil or fi.allparams or fi.is_async or fi.cache
            .no("calling {fi.name}()", e)
        if len(a.bound) > 8 then .no("more than 8 arguments", e)
        rt = deep(fi.ret)
        if rt.id != UNIT.id and not .word(rt) then .no("return type {checker.show(rt)}", e)
        for p in fi.params
            if not .word(deep(p.ty)) then .no("parameter type {checker.show(deep(p.ty))}", fi.node)
        fi

    fn call(e N, r int)
        a = .an(e)
        if a.ckind == "bmethod"
            .method(e, r)
            return
        if a.ckind == "fn" and a.f != nil
            f0: Fn = a.f
            if ext_name(f0) != ""
                .intrinsic(e, f0, r)
                return
        if a.ckind == "builtin"
            if a.name == "print"
                if r != T0 or .live or .holds then .no("print inside an expression", e)
                .print(e)
                return
            bargs = e.kids[1].kids
            if a.name == "len" and len(bargs) == 1 and (.is_str(bargs[0]) or .is_list(bargs[0]))
                x0 = .opnd(bargs[0], r)
                .a.ldr(r, x0, 0)
                return
            if a.name == "str" and len(bargs) == 1 and e.kids[2].kids == []
                .need(bargs[0])
                .to_str(bargs[0], r)
                return
            if a.name == "abs" and len(e.kids[1].kids) == 1
                ax = e.kids[1].kids[0]
                .need(ax)
                .gen(ax, r)
                lo, hi = .range_e(ax)
                if lo >= 0 then return
                .a.cmp_imm(r, 0)
                lpos = .a.new_label("pos")
                .a.bcond(GE, lpos)
                .a.negs(r, r)
                .a.bcond(VS, .overflow(e.line))
                .a.here(lpos)
                return
            .no("builtin {a.name}()", e)
        fi = .user_fn(e)
        if .inline(e, fi, r) then return
        .emit_call("t:" + fi.cname, .opts(a.bound), [], r)
        if deep(fi.ret).id != UNIT.id then .a.mov(r, 0)
        .want(fi)

    # вызов target (метка кода или ячейка импорта "d:..."): аргументы args (nil — ноль), за ними константы
    # extra; результат остаётся в x0
    fn emit_call(target str, args [N?], extra [int], r int)
        calls = false
        for arg0 in args
            if arg0 != nil
                arg: N = arg0
                .need(arg)
                if .has_call(arg) then calls = true
        regs: [int] = []
        if calls  # аргументы — в промежуточные регистры: вызов внутри аргумента испортит x0..x7
            .chk(r + len(args) - 1, nil)
            for i, arg1 in enumerate(args)
                if arg1 == nil
                    .a.movz(r + i, 0, 0)
                else
                    ai: N = arg1
                    .gen(ai, r + i)
                later = false
                for j in i + 1..len(args) - 1
                    aj: N? = args[j]
                    if aj != nil and .has_call(aj) then later = true
                regs.append(.protect(r + i, later))
        else  # сразу в x0..x7
            for i, arg2 in enumerate(args)
                if arg2 == nil
                    .a.movz(i, 0, 0)
                else
                    ak: N = arg2
                    got = .opnd(ak, r)
                    .mv(i, got)
        saved = [x for x in .live if x >= T0 and x <= TN]
        for x in saved  # запасной путь: живые промежуточные значения — в кадр
            .a.str_(x, SP, .tslot + 8 * (x - T0))
            .used_tslot = true
        for i, x in enumerate(regs)
            .a.mov(i, x)
        i = len(regs) - 1
        while i >= 0
            .release(regs[i])
            i -= 1
        for j, cv in enumerate(extra)
            .a.mov_imm(len(args) + j, cv)
        if target.startswith("d:")
            .ncalls += 1
            .a.ldr_label(16, target)
            .a.blr(16)
        else
            .bl(target)
        for x in saved
            .a.ldr(x, SP, .tslot + 8 * (x - T0))

    # функция рантайма nrt; результат — в r
    fn rcall(name str, args [N], extra [int], r int)
        .rcall_opt(name, .opts(args), extra, r)

    fn opts(args [N]) [N?]
        out: [N?] = []
        for x in args
            out.append(x)
        out

    fn rcall_opt(name str, args [N?], extra [int], r int)
        fi = .nrt(name)
        .emit_call("t:" + fi.cname, args, extra, r)
        .a.mov(r, 0)
        .want(fi)

    # то же с аргументами, уже лежащими в регистрах; ret — нужен ли результат в r
    fn rcall_regs(name str, regs [int], extra [int], r int, ret bool)
        fi = .nrt(name)
        saved = [x for x in .live if x >= T0 and x <= TN]
        for x in saved
            .a.str_(x, SP, .tslot + 8 * (x - T0))
            .used_tslot = true
        for i, x in enumerate(regs)
            .a.mov(i, x)
        for j, cv in enumerate(extra)
            .a.mov_imm(len(regs) + j, cv)
        .bl("t:" + fi.cname)
        for x in saved
            .a.ldr(x, SP, .tslot + 8 * (x - T0))
        if ret then .a.mov(r, 0)
        .want(fi)

    # адрес вида base + c (c кратно scale, команда берёт смещение сама)
    fn addr_off(e N, scale int) (N, int)
        if e.kind == "BinOp" and e.kids[0].s == "+"
            ok, c = .const_val(e.kids[2])
            if ok and c >= 0 and c % scale == 0 and c // scale <= 4095 then return (e.kids[1], c)
        (e, 0)

    # встроенные функции рантайма (extern "sip" в std/nrt.sip)
    fn intrinsic(e N, fi Fn, r int)
        name = ext_name(fi)
        args = .an(e).bound
        if not fi.cname.startswith("f_std__nrt__") then .no("extern function {fi.name}()", e)
        if name == "sip_n_ld" or name == "sip_n_ldb"
            base, off = .addr_off(args[0], if name == "sip_n_ld" then 8 else 1)
            x = .opnd(base, r)
            if name == "sip_n_ld" then .a.ldr(r, x, off) else .a.ldrb(r, x, off)
        elif name == "sip_n_st" or name == "sip_n_stb"
            base, off = .addr_off(args[0], if name == "sip_n_st" then 8 else 1)
            .chk(r + 1, e)
            x = .opnd(base, r)
            x = .protect(x, .has_call(args[1]))
            y = .opnd(args[1], r + 1)
            if name == "sip_n_st" then .a.str_(y, x, off) else .a.strb(y, x, off)
            .release(x)
        elif name == "sip_n_state"
            .a.addr(r, .a.bslot("nrt", 512))
        elif name == "sip_n_chars"
            .a.adr(r, .a.chars())
        elif name == "sip_n_addr"
            .gen(args[0], r)
        elif name == "sip_n_stack_top"
            .a.ldr_label(r, .a.bslot("stack_top", 8))
        elif name == "sip_n_bss_lo"
            .a.addr(r, "b:#lo")
        elif name == "sip_n_bss_hi"
            .a.addr(r, "b:#end")
        elif name == "sip_n_mmap"  # mmap(0, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
            x = .opnd(args[0], r)
            .a.mov(1, x)
            .a.movz(0, 0, 0)
            .a.movz(2, 3, 0)
            .a.mov_imm(3, 4098)
            .a.movn(4, 0, 0)
            .a.movz(5, 0, 0)
            .ncalls += 1
            .a.ldr_label(16, "d:mmap")
            .a.blr(16)
            .a.mov(r, 0)
        elif name == "sip_n_move" or name == "sip_n_zero"
            .emit_call(if name == "sip_n_move" then "d:memmove" else "d:bzero", .opts(args), [], r)
        elif name == "sip_n_cmp"
            .emit_call("d:memcmp", .opts(args), [], r)
            .a.sxtw(r, 0)
        elif name == "sip_n_chr"
            .emit_call("d:memchr", .opts(args), [], r)
            .a.mov(r, 0)
        elif name == "sip_n_roots"
            .bl("t:rt_roots")
        elif name == "sip_n_die"
            .emit_call("t:rt_die_str", .opts(args), [], r)
        else
            .no("intrinsic {name}", e)
        pass

    # методы str и списков
    fn method(e N, r int)
        a = .an(e)
        rn: N = a.n
        m = a.name
        args = e.kids[1].kids
        if e.kids[2].kids then .no("keyword arguments of .{m}()", e)
        .need(rn)
        rt = .ty(rn)
        if rt.k == "list" and m == "append" and len(args) == 1
            .rcall("append", [rn, args[0]], [.lflags(rt)], r)
        elif rt.k == "list" and m == "pop" and len(args) == 0
            x = .opnd(rn, r)
            .a.ldr(16, x, 0)
            .a.cbz(16, .stub("IndexError", "pop from empty list", e.line))
            .a.sub_imm(16, 16, 1)
            .a.str_(16, x, 0)
            .a.ldr(17, x, 16)
            .a.ldr_x(r, 17, 16)
        elif rt.id == STR.id and m == "find" and len(args) == 1
            .rcall("find", [rn, args[0]], [0], r)
        elif rt.id == STR.id and m == "startswith" and len(args) == 1
            .rcall("starts", [rn, args[0]], [], r)
        elif rt.id == STR.id and m == "endswith" and len(args) == 1
            .rcall("ends", [rn, args[0]], [], r)
        elif rt.id == STR.id and m == "join" and len(args) == 1 and .ty(args[0]).k == "list"
            .rcall("join", [rn, args[0]], [], r)
        else
            .no("method {checker.show(rt)}.{m}()", e)
        pass

    # str(x) в r
    fn to_str(x N, r int)
        t = .ty(x)
        if t.id == STR.id
            .gen(x, r)
        elif t.id == INT.id
            .rcall("of_int", [x], [], r)
        elif t.id == BOOL.id
            .gen(x, r)
            .a.adr(16, .a.strlit(bytes_of("True")))
            .a.adr(17, .a.strlit(bytes_of("False")))
            .a.cmp_imm(r, 0)
            .a.csel(r, 16, 17, NE)
        else
            .rcall("to_str", [x], [.kind_of(t)], r)
        pass

    # части склейки строк: литералы, подстановки, str(int) и операнды «+» (по порядку вычисления)
    fn pieces(e N, out [Piece])
        if e.kind == "Str"
            for p in e.kids[0].kids
                if p.kind != "Interp"
                    .piece_lit(cgen.unescape(p.s), out)
                    continue
                if not isn(p.kids[1]) then .no("format spec", p)
                x = p.kids[0]
                .need(x)
                out.append(Piece(x, "", .ty(x).id == INT.id))
            return
        if e.kind == "BinOp" and e.kids[0].s == "+" and .is_str(e)
            .pieces(e.kids[1], out)
            .pieces(e.kids[2], out)
            return
        if e.kind == "Call" and .an(e).ckind == "builtin" and .an(e).name == "str" and len(e.kids[1].kids) == 1
            x = e.kids[1].kids[0]
            if .ty(x).id == INT.id and not e.kids[2].kids
                out.append(Piece(x, "", true))
                return
        .need(e)
        out.append(Piece(e, "", false))

    fn piece_lit(text str, out [Piece])
        if text == "" then return
        n = len(out)
        if n > 0 and out[n - 1].node == nil
            out[n - 1] = Piece(nil, out[n - 1].text + text, false)
        else
            out.append(Piece(nil, text, false))

    # строка из частей: литерал, одна часть или склейка nrt.cat (до 6 частей за одно выделение памяти)
    fn str_value(e N, r int)
        ps: [Piece] = []
        .pieces(e, ps)
        if not ps
            .a.adr(r, .a.strlit([]))
            return
        if len(ps) == 1
            .piece(ps[0], r)
            if ps[0].num then .rcall_regs("of_int", [r], [], r, true)
            return
        .chk(r + 5, e)
        done = 0
        acc = -1  # регистр с уже склеенным началом
        while done < len(ps)
            take = min(len(ps) - done, if acc < 0 then 6 else 5)
            regs: [int] = []
            mask = 0
            if acc >= 0 then regs.append(acc)
            for i in 0..take - 1
                p = ps[done + i]
                k = r + len(regs)
                .piece(p, k)
                if p.num then mask += P2[len(regs)]
                later = done + take < len(ps)
                for q in ps[done + i + 1:]
                    if q.node != nil
                        qn: N = q.node
                        if .has_call(qn) or (q.num == false and not .is_str(qn)) then later = true
                regs.append(.protect(k, later))
            j = len(regs) - 1
            while j >= 0
                .release(regs[j])
                j -= 1
            fi = .nrt("cat")
            saved = [x for x in .live if x >= T0 and x <= TN]
            for x in saved
                .a.str_(x, SP, .tslot + 8 * (x - T0))
                .used_tslot = true
            for i, x in enumerate(regs)
                .a.mov(2 + i, x)
            .a.mov_imm(0, len(regs))
            .a.mov_imm(1, mask)
            .bl("t:" + fi.cname)
            for x in saved
                .a.ldr(x, SP, .tslot + 8 * (x - T0))
            .want(fi)
            done += take
            if done < len(ps)
                .a.mov(r, 0)
                acc = .protect(r, true)
                .release(acc)
            else
                .a.mov(r, 0)
        pass

    # значение части в r: адрес строки или int
    fn piece(p Piece, r int)
        if p.node == nil
            .a.adr(r, .a.strlit(bytes_of(p.text)))
            return
        x: N = p.node
        if p.num then .gen(x, r) else .to_str(x, r)

    # индекс в r (idx — уже неотрицательный или нормализуется в x17); длина — в x16; ошибка — msg
    fn bound(i int, lo int, msg str, line int) int
        idx = i
        if lo < 0  # отрицательный индекс — с конца
            .a.add(17, i, 16)
            .a.cmp_imm(i, 0)
            .a.csel(17, 17, i, LT)
            idx = 17
        .a.cmp(idx, 16)
        .a.bcond(arm64.HS, .stub("IndexError", msg, line))
        idx

    # s[i], l[i], срезы
    fn index(e N, r int)
        kind = e.s
        obj = e.kids[0]
        .need(obj)
        if kind == "slice_str" or kind == "slice_list"
            sl = e.kids[1]
            if not isn(sl.kids[2]) then .no("slice step", e)
            has = (if isn(sl.kids[0]) then 0 else 1) + (if isn(sl.kids[1]) then 0 else 2)
            sa = .opts([obj])
            for b in [sl.kids[0], sl.kids[1]]
                if isn(b) then sa.append(nil) else sa.append(b)
            if kind == "slice_str"
                .rcall_opt("slice", sa, [has], r)
            else
                .rcall_opt("list_slice", sa, [has, .lflags(.ty(obj))], r)
            return
        if kind != "str" and kind != "list" then .no("index of {checker.show(.ty(obj))}", e)
        ie = e.kids[1]
        .need(ie)
        .chk(r + 1, e)
        x = .opnd(obj, r)
        x = .protect(x, .has_call(ie))
        i = .opnd(ie, r + 1)
        .release(x)
        lo, _ = .range_e(ie)
        .a.ldr(16, x, 0)
        if kind == "str"
            idx = .bound(i, lo, "string index out of range", e.line)
            .a.add(16, x, idx)
            .a.ldrb(16, 16, 8)
            .a.adr(17, .a.chars())
            .a.add_lsl(r, 17, 16, 4)
        else
            idx2 = .bound(i, lo, "list index out of range", e.line)
            .a.ldr(16, x, 16)
            .a.ldr_x(r, 16, idx2)

    # l[i] = v
    fn set_index(t N, v N)
        obj = t.kids[0]
        ie = t.kids[1]
        if t.s != "list" then .no("assignment to an index of {checker.show(.ty(obj))}", t)
        .need(obj)
        .need(ie)
        .need(v)
        x = .opnd(obj, T0)
        x = .protect(x, .has_call(ie) or .has_call(v))
        i = .opnd(ie, T0 + 1)
        i = .protect(i, .has_call(v))
        y = .opnd(v, T0 + 2)
        lo, _ = .range_e(ie)
        .a.ldr(16, x, 0)
        idx = .bound(i, lo, "list index out of range", t.line)
        .a.ldr(16, x, 16)
        .a.str_x(y, 16, idx)
        .release(i)
        .release(x)

    # l[i] = значение из регистра y; l и i — без вызовов, считаются в sc и sc + 1
    fn store_index(t N, y int, sc int)
        .chk(sc + 1, t)
        x = .opnd(t.kids[0], sc)
        i = .opnd(t.kids[1], sc + 1)
        lo, _ = .range_e(t.kids[1])
        .a.ldr(16, x, 0)
        idx = .bound(i, lo, "list index out of range", t.line)
        .a.ldr(16, x, 16)
        .a.str_x(y, 16, idx)

    # [a, b, c]
    fn list_lit(e N, r int)
        items = e.kids[0].kids
        t = .ty(e)
        n = len(items)
        .rcall("list_new", [], [n, n, .lflags(t)], r)
        if not items then return
        calls = false
        for item in items
            .need(item)
            if .has_call(item) then calls = true
        .chk(r + 1, e)
        l = .protect(r, calls)
        for i, item in enumerate(items)
            y = .opnd(item, r + 1)
            .a.ldr(16, l, 16)
            if i < 4096
                .a.str_(y, 16, 8 * i)
            else
                .a.mov_imm(17, i)
                .a.str_x(y, 16, 17)
        .release(l)
        .mv(r, l)

    fn bl(label str)
        .ncalls += 1
        .a.bl_(label)

    # встроить fn f(x) = выражение: аргументы — в регистры, тело — как выражение
    # можно ли встроить вызов e функции fi с результатом в r
    fn inlinable(e N, fi Fn, r int) bool
        if len(fi.body) != 1 or fi.body[0].kind != "Return" or isn(fi.body[0].kids[0]) then return false
        if len(fi.locals) != len(fi.params) or deep(fi.ret).id == UNIT.id then return false
        body = fi.body[0].kids[0]
        if size(body) > INLINE_SIZE or len(.inl) >= INLINE_DEPTH then return false
        same = len([x for x in .inl if x == fi.cname]) + (if .cur().cname == fi.cname then 1 else 0)
        if same >= 2 then return false
        ntmp = 0
        for arg in .an(e).bound
            okc, _ = .const_val(arg)
            name = .fixed_name(arg)
            if not okc and not (name != "" and name in .homes) then ntmp += 1
        r + ntmp + regs_needed(body) - 1 <= TN

    fn inline(e N, fi Fn, r int) bool
        if not .inlinable(e, fi, r) then return false
        body = fi.body[0].kids[0]
        args = .an(e).bound
        bcall = .has_call(body)
        binds: [Home] = []
        regs: [int] = []
        k = r
        for i, arg in enumerate(args)
            .need(arg)
            okc, cv = .const_val(arg)
            if okc
                binds.append(Home(-2, cv))
                continue
            name = .fixed_name(arg)
            if name != "" and name in .homes
                binds.append(.homes[name])
                continue
            .chk(k, e)
            .gen(arg, k)
            later = bcall
            for j in i + 1..len(args) - 1
                if .has_call(args[j]) then later = true
            x = .protect(k, later)
            regs.append(x)
            if x == k then k += 1
            binds.append(Home(x, -1))
        olds: [Home] = []
        m = .mark()
        for i, p in enumerate(fi.params)
            cn = fi.locals[p.name].cname
            olds.append(if cn in .homes then .homes[cn] else Home(-1, -1))
            .homes[cn] = binds[i]
            arg = args[i]
            lo, hi = .range_e(arg)
            old = .range_of(cn)
            .fstack.append(Undo(cn, cn in .facts, old[0], old[1]))
            .facts[cn] = (lo, hi)
        .inl.append(fi.cname)
        .need(body)
        .gen(body, k)
        .inl.pop()
        .mv(r, k)
        .undo(m)
        for i, p in enumerate(fi.params)
            .homes[fi.locals[p.name].cname] = olds[i]
        i = len(regs) - 1
        while i >= 0
            .release(regs[i])
            i -= 1
        true

    fn want(fi Fn)
        if .measuring then return
        if fi.cname not in .seen
            .seen[fi.cname] = true
            .queue.append(fi)

    fn put_lit(s str)
        if s == "" then return
        bs = bytes_of(s)
        .a.adr(0, .a.cstr(bs))
        .a.mov_imm(1, len(bs))
        .bl("t:rt_put")

    fn put_val(x N)
        t = .ty(x)
        if x.kind == "Str"
            for p in x.kids[0].kids
                if p.kind != "Interp"
                    .put_lit(cgen.unescape(p.s))
                    continue
                if not isn(p.kids[1]) then .no("format spec", p)
                .put_val(p.kids[0])
            return
        if t.id == INT.id
            .gen(x, T0)
            .a.mov(0, T0)
            .bl("t:rt_put_int")
        elif t.id == BOOL.id
            .gen(x, T0)
            .a.mov(0, T0)
            .bl("t:rt_put_bool")
        elif .word(t)
            .to_str(x, T0)
            .a.mov(0, T0)
            .bl("t:rt_put_str")
        else
            .no("printing {checker.show(t)}", x)
        pass

    fn print(e N)
        if e.kids[2].kids then .no("print with keyword arguments", e)
        for i, x in enumerate(e.kids[1].kids)
            if i > 0 then .put_lit(" ")
            .put_val(x)
        .put_lit("\n")

    # ---------- инструкции ----------

    fn block(stmts [N])
        m = .mark()
        for s in stmts
            .stmt(s)
        .undo(m)

    # блок заканчивается выходом (return, break, continue): после него код недостижим
    fn exits(stmts [N]) bool
        if not stmts then return false
        k = stmts[len(stmts) - 1].kind
        k == "Return" or k == "Break" or k == "Continue" or k == "Fail"

    fn stmt(s N)
        k = s.kind
        if k == "ExprStmt"
            e = s.kids[0]
            if e.kind != "Call" then .no("expression statement", e)
            .call(e, T0)
        elif k == "Assign"
            targets = s.kids[0].kids
            if len(targets) == 1 and targets[0].kind == "TupleLit" and s.kids[1].kind == "TupleLit"
                .swap(targets[0].kids[0].kids, s.kids[1].kids[0].kids, s)
                return
            if len(targets) == 1 and targets[0].kind == "Index"
                .set_index(targets[0], s.kids[1])
                return
            if len(targets) != 1 or targets[0].kind != "Name" then .no("this assignment", s)
            .need(s.kids[1])
            .need(targets[0])
            .assign(.var_of(targets[0]), s.kids[1])
        elif k == "AnnAssign"
            if isn(s.kids[2]) then return
            if s.kids[0].kind != "Name" then .no("this assignment", s)
            .need(s.kids[2])
            .assign(.var_of(s.kids[0]), s.kids[2])
        elif k == "AugAssign"
            a = .an(s)
            if a.n3 != nil
                aa: N = a.n3
                .stmt(aa)
                return
            b: N = a.n2
            t = s.kids[0]
            if t.kind == "Index" and t.s == "list" and not .has_call(t.kids[0]) and not .has_call(t.kids[1])
                .need(b)  # l[i] op= v: l и i без вызовов вычисляются ещё раз для записи
                .gen(b, T0)
                .store_index(t, T0, T0 + 1)
                return
            if t.kind != "Name" then .no("this assignment", s)
            .need(t)
            .need(s.kids[2])
            tv = .var_of(t)
            if not .scalar(.ty(t))
                .need(b)
                .gen(b, T0)
                .store_var(tv, T0)
                return
            r = .target_reg(tv)  # левый операнд — сама переменная: читается до записи результата
            .arith(b.kids[0].s, t, s.kids[2], r, T0, s.line, s)
            .store_var(tv, r)
        elif k == "If"
            .s_if(s)
        elif k == "While"
            lbody = .a.new_label("wb")
            lcond = .a.new_label("wc")
            lend = .a.new_label("we")
            .a.b(lcond)
            .a.here(lbody)
            .brk.append(lend)
            .cont.append(lcond)
            m = .mark()
            .assume(s.kids[0], true)
            .block(s.kids[1].kids)
            .undo(m)
            .brk.pop()
            .cont.pop()
            .a.here(lcond)
            .cjump(s.kids[0], lbody, true, T0)
            .a.here(lend)
        elif k == "For"
            .for_range(s)
        elif k == "Return"
            v = s.kids[0]
            if not isn(v)
                if deep(.c.tys[v.ty]).id != UNIT.id
                    .need(v)
                    .ret_val(v)
                    return
                if v.kind == "Call" then .call(v, T0)
            .epilogue()
        elif k == "Break"
            .a.b(.brk[len(.brk) - 1])
        elif k == "Continue"
            .a.b(.cont[len(.cont) - 1])
        elif k == "Pass"
            pass
        elif k == "FnDef"
            fi: Fn? = .an(s).f
            if fi != nil and not .cur().is_top then .no("nested function", s)
            pass
        else
            .no(k, s)
        pass

    # регистр, в котором удобно считать новое значение переменной v
    fn target_reg(v Var) int
        if not .in_mem(v) and .homes[v.cname].reg >= 0 then .homes[v.cname].reg else T0

    # v = e: прямо в регистр переменной, если e её не читает после записи (простое выражение без вызова)
    fn assign(v Var, e N)
        if e.kind == "IfExpr" and not .in_mem(v) and not .const_val(e.kids[0])[0]
            lelse = .a.new_label("else")
            lend = .a.new_label("end")
            .cjump(e.kids[0], lelse, false, T0)
            m = .mark()
            .assume(e.kids[0], true)
            .assign(v, e.kids[1])
            .undo(m)
            .a.b(lend)
            .a.here(lelse)
            .assume(e.kids[0], false)
            .assign(v, e.kids[2])
            .undo(m)
            .a.here(lend)
            return
        if not .in_mem(v) and .homes[v.cname].reg >= 0
            vr = .homes[v.cname].reg
            if e.kind == "BinOp" and e.kids[0].s != "and" and e.kids[0].s != "or" and .scalar(.ty(e))
                .need(e.kids[1])
                .need(e.kids[2])
                .arith(e.kids[0].s, e.kids[1], e.kids[2], vr, T0, e.line, e)
                return
            if e.kind == "Compare" and len(e.kids[1].kids) == 1 and not .has_call(e)
                op = e.kids[1].kids[0]
                .a.cset(vr, .compare(e.kids[0], op.kids[0].s, op.kids[1], T0, e))
                return
        r = T0
        if not .in_mem(v) and .homes[v.cname].reg >= 0 and .direct(e)
            r = .homes[v.cname].reg
        .gen(e, r)
        .store_var(v, r)

    # e можно считать прямо в регистр переменной: операнды читаются до записи результата, других
    # регистров (кроме x16/x17) не нужно
    fn direct(e N) bool
        if e.kind == "Name" or e.kind == "Num" or e.kind == "Const" then return true
        if e.kind == "BinOp" and e.kids[0].s != "and" and e.kids[0].s != "or" and e.kids[1].kind == "Name" and .scalar(.ty(e))
            return .direct_right(e.kids[0].s, e.kids[2])
        false

    # правый операнд, при котором op считается без промежуточных регистров
    fn direct_right(op str, right N) bool
        if right.kind == "Name" then return .an(right).var != nil
        ok, c = .const_val(right)
        if not ok then return false
        if op == "+" or op == "-" then return c >= -4095 and c <= 4095
        if op == "/" or op == "//" or op == "%" then return c > 0
        if op == "&" then return c > 0 and c < IMAX and log2(c + 1) > 0
        false

    # return e: if-выражение разветвляется на два return
    fn ret_val(v N)
        if v.kind == "IfExpr" and .const_val(v.kids[0])[0]
            .ret_val(if .const_val(v.kids[0])[1] != 0 then v.kids[1] else v.kids[2])
            return
        if v.kind == "IfExpr"
            lelse = .a.new_label("else")
            .cjump(v.kids[0], lelse, false, T0)
            m = .mark()
            .assume(v.kids[0], true)
            .ret_val(v.kids[1])
            .undo(m)
            .a.here(lelse)
            .assume(v.kids[0], false)
            .ret_val(v.kids[2])
            .undo(m)
            return
        if .tail_call(v) then return
        got = .opnd(v, T0)
        .mv(0, got)
        .epilogue()

    # return f(...): аргументы — в промежуточные регистры, кадр снят, переход в f вместо вызова
    # (функция без других вызовов остаётся листовой, рекурсия в хвосте не растит стек)
    fn tail_call(v N) bool
        if v.kind != "Call" or .inl then return false
        a = .an(v)
        if a.ckind != "fn" or a.f == nil then return false
        fi: Fn = a.f
        if ext_name(fi) != "" or .inlinable(v, fi, T0) then return false
        if fi.std and not fi.cname.startswith("f_std__nrt__") then return false
        if fi.parent != nil or fi.owner != nil or fi.allparams or fi.is_async or fi.cache then return false
        args = a.bound
        if len(args) > TN - T0 + 1 or .live or .holds then return false
        for arg in args
            if .has_call(arg) or not .word(.ty(arg)) then return false
        rt = deep(fi.ret)
        if rt.id == UNIT.id or not .word(rt) then return false
        for p in fi.params
            if not .word(deep(p.ty)) then return false
        for i, arg in enumerate(args)
            .gen(arg, T0 + i)
        .restore()
        for i in 0..len(args) - 1
            .a.mov(i, T0 + i)
        .a.b("t:" + fi.cname)
        .want(fi)
        true

    fn s_if(s N)
        lend = .a.new_label("fi")
        base = .mark()
        branches = s.kids[0].kids
        all_exit = true
        for br in branches
            lnext = .a.new_label("elif")
            .cjump(br.kids[0], lnext, false, T0)
            m = .mark()
            .assume(br.kids[0], true)
            .block(br.kids[1].kids)
            .undo(m)
            if .exits(br.kids[1].kids)
                pass
            else
                all_exit = false
                .a.b(lend)
            .a.here(lnext)
            .assume(br.kids[0], false)
        has_else = not isn(s.kids[1]) and len(s.kids[1].kids) > 0
        if has_else
            .block(s.kids[1].kids)
        .a.here(lend)
        .undo(base)
        if all_exit and not has_else  # дальше — только когда все условия ложны
            for br in branches
                .assume(br.kids[0], false)
        pass

    # a, b = x, y: сначала все значения, потом присваивания
    fn swap(targets [N], values [N], s N)
        if len(targets) != len(values) then .no("this assignment", s)
        if .swap_fast(targets, values, s) then return
        .chk(T0 + len(values) - 1, s)
        regs: [int] = []
        for i, v in enumerate(values)
            .need(v)
            if targets[i].kind != "Name" then .no("this assignment", s)
            .gen(v, T0 + i)
            later = false
            for j in i + 1..len(values) - 1
                if .has_call(values[j]) then later = true
            regs.append(.protect(T0 + i, later))
        for i, t in enumerate(targets)
            .store_var(.var_of(t), regs[i])
        i = len(regs) - 1
        while i >= 0
            .release(regs[i])
            i -= 1

    # без вызовов: переменные-источники не копируются, остальное — во временные регистры, затем
    # параллельная пересылка (цикл разрывается через x16)
    fn swap_fast(targets [N], values [N], s N) bool
        seen: {str: bool} = {}
        for i, t in enumerate(targets)
            if t.kind != "Name" or .has_call(values[i]) then return false
            v = .var_of(t)
            if v.cname in seen then return false
            seen[v.cname] = true
        dsts: [int] = []
        srcs: [int] = []
        tmp = T0
        for i, val in enumerate(values)
            .need(val)
            src = -1
            if val.kind == "Name" and .an(val).var != nil
                sv: Var = .an(val).var
                if not .in_mem(sv) and .homes[sv.cname].reg >= 0 then src = .homes[sv.cname].reg
            if src < 0
                .chk(tmp, s)
                .gen(val, tmp)
                src = tmp
                tmp += 1
            dsts.append(-1)
            srcs.append(src)
        for i, t in enumerate(targets)  # в память — сразу: такие места ничьими источниками не бывают
            tv = .var_of(t)
            if .in_mem(tv) or .homes[tv.cname].reg < 0
                .store_var(tv, srcs[i])
                srcs[i] = -1
            else
                dsts[i] = .homes[tv.cname].reg
        while true
            pending = [i for i in 0..len(dsts) - 1 if srcs[i] >= 0 and dsts[i] != srcs[i]]
            if not pending then break
            done = false
            for i in pending
                if not done
                    busy = false
                    for j in pending
                        if j != i and srcs[j] == dsts[i] then busy = true
                    if not busy
                        .mv(dsts[i], srcs[i])
                        srcs[i] = -1
                        done = true
            if not done  # цикл: значение одного приёмника — в x16
                d = dsts[pending[0]]
                .a.mov(16, d)
                for j in pending
                    if srcs[j] == d then srcs[j] = 16
        true

    fn hidden() (Var, Var)
        .nhid += 1
        (Var("#k", INT, "local", "#k{.nhid}"), Var("#hi", INT, "local", "#hi{.nhid}"))

    # for x in lo..hi: hi вычисляется один раз, x получает копию счётчика
    fn for_range(s N)
        it = s.kids[1]
        if .an(s).kind == "list" or .an(s).kind == "str"
            .for_seq(s)
            return
        if .an(s).kind != "range" or it.kind != "Range" then .no("for over this", it)
        if s.kids[0].kind != "Name" then .no("this loop target", s.kids[0])
        .need(it.kids[0])
        .need(it.kids[1])
        kv, hv = .hidden()
        target = .var_of(s.kids[0])
        hi_c = .small(it.kids[1])
        if hi_c < 0  # как в C: сначала верхняя граница, потом нижняя
            .gen(it.kids[1], T0)
            .store_var(hv, T0)
        body = s.kids[2].kids
        changed: {str: bool} = {}
        for st in body
            .assigned_in(st, changed)
        # счётчик — сама переменная цикла, если тело её не меняет и она в регистре
        fast = not .in_mem(target) and .homes[target.cname].reg >= 0 and target.cname not in changed
        if fast then kv = target
        lend = .a.new_label("fe")
        lnext = .a.new_label("fn")
        ltop = .a.new_label("ft")
        .gen(it.kids[0], T0)
        if hi_c >= 0
            .a.cmp_imm(T0, hi_c)
        else
            h = .load_var(hv, T0 + 1)
            .a.cmp(T0, h)
        .a.bcond(GT, lend)  # ни одного витка: переменная цикла не меняется
        .store_var(kv, T0)
        .a.here(ltop)
        if not fast
            k2 = .load_var(kv, T0)
            .store_var(target, k2)
        .brk.append(lend)
        .cont.append(lnext)
        .block(body)
        .brk.pop()
        .cont.pop()
        .a.here(lnext)
        # cmp k, hi; k += 1; b.lt top — сложение не трогает флаги, выход при k == hi
        k3 = .loop_cmp(kv, hv, hi_c)
        kr = .homes[kv.cname].reg
        if kr >= 0
            .a.add_imm(kr, k3, 1)
        else
            .a.add_imm(T0 + 2, k3, 1)
            .store_var(kv, T0 + 2)
        .a.bcond(LT, ltop)
        if fast then .a.sub_imm(kr, kr, 1)  # после последнего витка переменная равна hi
        .a.here(lend)

    # for x in список или строка: индекс k, длина читается на каждом витке (как в C)
    fn for_seq(s N)
        it = s.kids[1]
        if s.kids[0].kind != "Name" then .no("this loop target", s.kids[0])
        .need(it)
        kv, hv = .hidden()
        target = .var_of(s.kids[0])
        is_s = .an(s).kind == "str"
        .gen(it, T0)
        .store_var(hv, T0)
        .a.movz(T0, 0, 0)
        .store_var(kv, T0)
        lend = .a.new_label("fe")
        lnext = .a.new_label("fn")
        ltop = .a.new_label("ft")
        lcond = .a.new_label("fc")
        .a.b(lcond)
        .a.here(ltop)
        q = .load_var(hv, T0)
        k = .load_var(kv, T0 + 1)
        tr = .target_reg(target)
        if tr == T0 then tr = T0 + 2
        if is_s
            .a.add(16, q, k)
            .a.ldrb(16, 16, 8)
            .a.adr(17, .a.chars())
            .a.add_lsl(tr, 17, 16, 4)
        else
            .a.ldr(16, q, 16)
            .a.ldr_x(tr, 16, k)
        .store_var(target, tr)
        .brk.append(lend)
        .cont.append(lnext)
        .block(s.kids[2].kids)
        .brk.pop()
        .cont.pop()
        .a.here(lnext)
        k2 = .load_var(kv, T0)
        kr = .target_reg(kv)
        .a.add_imm(kr, k2, 1)
        .store_var(kv, kr)
        .a.here(lcond)
        q2 = .load_var(hv, T0)
        k3 = .load_var(kv, T0 + 1)
        .a.ldr(16, q2, 0)
        .a.cmp(k3, 16)
        .a.bcond(LT, ltop)
        .a.here(lend)

    fn loop_cmp(kv Var, hv Var, hi_c int) int
        k = .load_var(kv, T0)
        if hi_c >= 0
            .a.cmp_imm(k, hi_c)
        else
            h = .load_var(hv, T0 + 1)
            .a.cmp(k, h)
        k

    # ---------- функции ----------

    # числа вне -4095..4095 в телах циклов (кроме масок 2**k - 1 и множителей 2..5: для них свои команды)
    fn loop_consts(n N, inside bool, out [int])
        k = n.kind
        if inside and k == "Num" and .ty(n).id == INT.id
            ok, v = .const_val(n)
            if ok and (v > 4095 or v < -4095) and v < IMAX and log2(v + 1) <= 0 and log2(v) <= 0 and v not in out
                out.append(v)
        if k == "For"
            for i, c in enumerate(n.kids)
                .loop_consts(c, inside or i == 2, out)
            return
        if k == "While"
            for c in n.kids
                .loop_consts(c, true, out)
            return
        if k == "FnDef" then return
        for c in n.kids
            .loop_consts(c, inside, out)

    fn count_for_n(n N) int
        c = if n.kind == "For" then 1 else 0
        for k in n.kids
            c += .count_for_n(k)
        c

    fn assigned_in(n N, out {str: bool})
        k = n.kind
        targets: [N] = []
        if k == "Assign"
            targets = n.kids[0].kids
        elif k == "AugAssign" or k == "AnnAssign" or k == "For"
            targets = [n.kids[0]]
        for t in targets
            names = if t.kind == "TupleLit" then t.kids[0].kids else [t]
            for x in names
                if x.kind == "Name" and x.an != 0 and .an(x).var != nil
                    v: Var = .an(x).var
                    out[v.cname] = true
        for c in n.kids
            .assigned_in(c, out)

    # глобальные переменные, которые упоминает функция (они остаются в памяти)
    fn globals_in(n N)
        if n.kind == "Name" and n.an != 0 and .an(n).var != nil
            v: Var = .an(n).var
            if v.kind == "global" then .shared[v.cname] = true
        for k in n.kids
            .globals_in(k)

    fn prologue()
        if .frame == 0 then return
        .a.stp_pre(FP, arm64.LR, SP, -.frame)
        .a.add_imm(FP, SP, 0)
        i = 0
        while i < .nsave
            if i + 1 < .nsave
                .a.stp(VREG[i], VREG[i + 1], SP, 16 + 8 * i)
            else
                .a.str_(VREG[i], SP, 16 + 8 * i)
            i += 2

    fn epilogue()
        .restore()
        .a.ret()

    # восстановить сохраняемые регистры и снять кадр
    fn restore()
        if .frame != 0
            i = 0
            while i < .nsave
                if i + 1 < .nsave
                    .a.ldp(VREG[i], VREG[i + 1], SP, 16 + 8 * i)
                else
                    .a.ldr(VREG[i], SP, 16 + 8 * i)
                i += 2
            .a.ldp_post(FP, arm64.LR, SP, .frame)

    # один проход генерации функции; leaf — переменные в x0..x8
    fn pass_fn(fi Fn, label str, top bool, leaf bool)
        .fi = fi
        .trusted = fi.cname.startswith("f_std__nrt__")  # рантайм: адреса и счётчики не переполняются
        .homes = {}
        .nhid = 0
        .leaf = leaf
        .holds = []
        .live = []
        .facts = {}
        .fstack = []
        .inl = []
        .ncalls = 0
        .mut = {}
        for s in fi.body
            .assigned_in(s, .mut)
        names: [Var] = []
        for p in fi.params
            if not .word(deep(p.ty)) then .no("parameter type {checker.show(deep(p.ty))}", fi.node)
            names.append(fi.locals[p.name])
        for v in fi.locals.values()
            if v.kind == "local"
                if not .word(deep(v.ty)) then .no("variable type {checker.show(deep(v.ty))}", fi.node)
                names.append(v)
        for v in fi.extra
            names.append(v)
        if top  # глобальные, которых не касается ни одна функция, живут в регистрах верхнего уровня
            for v in .c.globals.values()
                if v.mod == fi.mod and v.cname not in .shared then names.append(v)
        nfor = 0
        for s in fi.body
            nfor += .count_for_n(s)
        for i in 1..nfor
            names.append(Var("#k", INT, "local", "#k{i}"))
            names.append(Var("#hi", INT, "local", "#hi{i}"))
        pool: [int] = []
        if leaf
            for i in 0..len(fi.params) - 1
                pool.append(i)
            pool.append(8)
            i = 7
            while i >= len(fi.params)
                pool.append(i)
                i -= 1
        .nvreg = 0
        .nslots = 0
        for v in names
            if v.cname in .homes then continue
            if len(pool) > 0
                .homes[v.cname] = Home(pool.pop(0), -1)
            elif .nvreg < len(VREG)
                .homes[v.cname] = Home(VREG[.nvreg], -1)
                .nvreg += 1
            else
                .homes[v.cname] = Home(-1, .nslots)
                .nslots += 1
        # большие константы внутри циклов — в регистры, один раз при входе
        .cregs = {}
        big: [int] = []
        for st in fi.body
            .loop_consts(st, false, big)
        for bv in big
            if len(.cregs) < 4 and bv not in .cregs
                if len(pool) > 0
                    .cregs[bv] = pool.pop(0)
                elif .nvreg + 2 < len(VREG)  # оставить регистры для значений, живущих через вызов
                    .cregs[bv] = VREG[.nvreg]
                    .nvreg += 1
        .invariant_ranges(fi)
        if .measuring
            .maxv = .nvreg
            .used_tslot = false
        .tslot = .slot_base + 8 * .nslots
        .a.here(label)
        .prologue()
        for i, p in enumerate(fi.params)
            .store_var(fi.locals[p.name], i)
        for cv, reg in .cregs.items()
            .a.mov_imm(reg, cv)
        .block(fi.body)
        ret = deep(fi.ret)
        if not .exits(fi.body)
            if ret.id != UNIT.id and not top
                .a.b(.stub("Error", "{fi.name}() ended without returning a value", last_line(fi)))
            else
                .epilogue()
        .emit_stubs()

    fn gen_fn(fi Fn, label str, top bool)
        main = .a
        .measuring = true
        .frame = 16
        .nsave = 0
        .slot_base = 16
        .a = Asm()
        .pass_fn(fi, label, top, false)
        leaf = .ncalls == 0 and not top
        if leaf
            .a = Asm()
            .pass_fn(fi, label, top, true)
        .a = main
        .measuring = false
        .nsave = .maxv
        .slot_base = 16 + 8 * ((.nsave + 1) // 2 * 2)
        bytes = .slot_base + 8 * .nslots + (if .used_tslot then 8 * (TN - T0 + 1) else 0)
        .frame = (bytes + 15) // 16 * 16
        if leaf and .nsave == 0 and .nslots == 0 then .frame = 0
        if .frame > 504 then .no("this many variables in {fi.name}()", fi.node)
        .pass_fn(fi, label, top, leaf)

    # ---------- рантайм на ассемблере ----------

    fn runtime()
        a = .a
        buf = a.bslot("outbuf", OUTBUF)
        pos = a.bslot("outpos", 8)
        a.dslot("write")
        a.dslot("exit")
        # rt_flush: write(1, outbuf, outpos); outpos = 0
        a.here("t:rt_flush")
        a.push_frame()
        a.addr(1, buf)
        a.ldr_label(2, pos)
        a.movz(0, 1, 0)
        a.ldr_label(16, "d:write")
        a.blr(16)
        a.str_label(ZR, pos, 16)
        a.pop_frame()
        a.ret()
        # rt_put(x0 = адрес, x1 = длина)
        a.here("t:rt_put")
        a.push_frame()
        a.addr(4, buf)
        a.ldr_label(3, pos)
        a.mov_imm(5, OUTBUF)
        a.here("t:rt_put_loop")
        a.cbz(1, "t:rt_put_done")
        a.cmp(3, 5)
        a.bcond(arm64.LO, "t:rt_put_room")
        a.str_label(3, pos, 16)
        a.sub_imm(SP, SP, 16)
        a.str_(0, SP, 0)
        a.str_(1, SP, 8)
        a.bl_("t:rt_flush")
        a.ldr(0, SP, 0)
        a.ldr(1, SP, 8)
        a.add_imm(SP, SP, 16)
        a.addr(4, buf)
        a.movz(3, 0, 0)
        a.mov_imm(5, OUTBUF)
        a.here("t:rt_put_room")
        a.ldrb(6, 0, 0)
        a.strb_r(6, 4, 3)
        a.add_imm(0, 0, 1)
        a.add_imm(3, 3, 1)
        a.sub_imm(1, 1, 1)
        a.b("t:rt_put_loop")
        a.here("t:rt_put_done")
        a.str_label(3, pos, 16)
        a.pop_frame()
        a.ret()
        # rt_put_int(x0): десятичная запись в 32 байта кадра
        a.here("t:rt_put_int")
        a.push_frame()
        a.sub_imm(SP, SP, 32)
        a.add_imm(4, SP, 32)  # конец буфера
        a.mov(5, 4)
        a.mov(2, 0)
        a.cmp_imm(0, 0)
        a.bcond(GE, "t:rt_pi_loop")
        a.negs(2, 0)  # для INT64_MIN даёт то же число: делим без знака
        a.here("t:rt_pi_loop")
        a.movz(6, 10, 0)
        a.udiv(7, 2, 6)
        a.msub(3, 7, 6, 2)
        a.add_imm(3, 3, 48)
        a.sub_imm(5, 5, 1)
        a.strb(3, 5, 0)
        a.mov(2, 7)
        a.cbnz(2, "t:rt_pi_loop")
        a.cmp_imm(0, 0)
        a.bcond(GE, "t:rt_pi_out")
        a.movz(3, 45, 0)
        a.sub_imm(5, 5, 1)
        a.strb(3, 5, 0)
        a.here("t:rt_pi_out")
        a.mov(0, 5)
        a.sub(1, 4, 5)
        a.bl_("t:rt_put")
        a.add_imm(SP, FP, 0)
        a.pop_frame()
        a.ret()
        # rt_put_bool(x0)
        a.here("t:rt_put_bool")
        a.cbz(0, "t:rt_pb_f")
        a.adr(0, a.cstr(bytes_of("True")))
        a.movz(1, 4, 0)
        a.b("t:rt_put")
        a.here("t:rt_pb_f")
        a.adr(0, a.cstr(bytes_of("False")))
        a.movz(1, 5, 0)
        a.b("t:rt_put")
        # rt_put_str(x0 = строка Sip), rt_die_str(x0 = строка Sip)
        a.here("t:rt_put_str")
        a.ldr(1, 0, 0)
        a.add_imm(0, 0, 8)
        a.b("t:rt_put")
        a.here("t:rt_die_str")
        a.ldr(1, 0, 0)
        a.add_imm(0, 0, 8)
        a.b("t:rt_die")
        # rt_die(x0 = текст, x1 = длина): вывод, текст в stderr, exit(1)
        a.here("t:rt_die")
        a.mov(19, 0)
        a.mov(20, 1)
        a.bl_("t:rt_flush")
        a.movz(0, 2, 0)
        a.mov(1, 19)
        a.mov(2, 20)
        a.ldr_label(16, "d:write")
        a.blr(16)
        a.movz(0, 1, 0)
        a.ldr_label(16, "d:exit")
        a.blr(16)

    fn program(out str)
        root = .ld.files[0][1]
        if .c.mainfn != nil
            m: Fn = .c.mainfn
            if m.params then .no("fn main with arguments", m.node)
        if .c.has_tests then .no("test blocks", nil)
        for v in .c.globals.values()
            if v.mod == root and not .word(deep(v.ty)) then .no("global of type {checker.show(deep(v.ty))}", nil)
        for f in .c.fns.values()
            if not f.is_top
                for st in f.body
                    .globals_in(st)
        for f in .c.methods
            for st in f.body
                .globals_in(st)
        # точка входа: верхний уровень корневого модуля, main, сброс вывода, exit(0)
        .a.here("t:_start")
        .a.add_imm(16, SP, 0)
        .a.str_label(16, .a.bslot("stack_top", 8), 17)
        .a.push_frame()
        tops = [t for t in .c.tops if t.mod == root]
        for t in tops
            .a.bl_("t:" + t.cname)
        if .c.mainfn != nil
            m: Fn = .c.mainfn
            .a.bl_("t:" + m.cname)
            .want(m)
        .a.bl_("t:rt_flush")
        .a.movz(0, 0, 0)
        .a.ldr_label(16, "d:exit")
        .a.blr(16)
        .runtime()
        for t in tops
            .gen_fn(t, "t:" + t.cname, true)
        .drain()
        if .nrt("alloc").cname in .seen  # есть куча: сборщику нужны сохраняемые регистры в стеке
            a = .a
            a.here("t:rt_roots")
            a.push_frame()
            a.sub_imm(SP, SP, 80)
            for i in 0..4
                a.stp(VREG[2 * i], VREG[2 * i + 1], SP, 16 * i)
            a.add_imm(0, SP, 0)
            col = .nrt("collect")
            a.bl_("t:" + col.cname)
            .want(col)
            a.add_imm(SP, SP, 80)
            a.pop_frame()
            a.ret()
            .drain()
        ident = cgen.stem(out)
        macho.emit_file(.a, "t:_start", IMPORTS, out, ident)

    fn drain()
        while .queue
            f = .queue.pop(0)
            .gen_fn(f, "t:" + f.cname, false)

fn build(c checker.Checker, ld modules.Loader, file str, out str)
    NGen(c, ld, file, Asm()).program(out)
