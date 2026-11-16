# Ассемблер arm64 (AArch64): машинные слова, метки и поправки.
#
# Код — список 32-битных слов. Ссылки на метки (переходы, адреса строк и данных) записываются
# поправками и заполняются в resolve, когда известны адреса: сначала генератор пишет код, потом
# запись Mach-O раскладывает секции и зовёт resolve.
#
# Метки: "t:имя" — код, "c:имя" — константы в __TEXT (строки), "d:имя" — данные в __DATA (ячейки
# импортов), "b:имя" — обнулённая память (глобальные переменные, буфер вывода).
#
# Регистры — числа 0..30; 31 — это XZR или SP, смотря по команде. Сдвигов в Sip нет, поэтому поля
# команды собираются умножением на степени двойки.

P2 = [2 ** i for i in 0..62]

FP = 29
LR = 30
SP = 31
ZR = 31

# условия для b.cond и cset
EQ = 0
NE = 1
HS = 2
LO = 3
VS = 6
VC = 7
HI = 8
LS = 9
GE = 10
LT = 11
GT = 12
LE = 13

fn sh(x int, n int) int = x * P2[n]

type Fix(at int, label str, kind str)

type Asm(code [int] = [], tl {str: int} = {}, fixes [Fix] = [], consts [int] = [], cl {str: int} = {},
         data [int] = [], dl {str: int} = {}, bss int = 0, bl {str: int} = {}, nlabel int = 0, lpos int = -1)

    fn emit(w int)
        .code.append(w)

    fn pos() int = len(.code)

    fn new_label(hint str) str
        .nlabel += 1
        "t:{hint}{.nlabel}"

    fn here(label str)
        .tl[label] = len(.code)
        .lpos = len(.code)

    fn fix(label str, kind str, w int)
        .fixes.append(Fix(len(.code), label, kind))
        .code.append(w)

    # строка в __TEXT,__const (одна копия на текст); метка "c:..."
    fn cstr(bytes [int]) str
        key = "c:" + ",".join([str(b) for b in bytes])
        if key in .cl then return key
        .cl[key] = len(.consts)
        .consts.extend(bytes)
        key

    # 8-байтовая ячейка в __DATA (для адресов функций libSystem)
    fn dslot(name str) str
        label = "d:" + name
        if label not in .dl
            .dl[label] = len(.data)
            .data.extend([0, 0, 0, 0, 0, 0, 0, 0])
        label

    # n обнулённых байт (выровнено на 16)
    fn bslot(name str, n int) str
        label = "b:" + name
        if label not in .bl
            .bl[label] = .bss
            .bss += (n + 15) // 16 * 16
        label

    # ---------- команды ----------

    fn movz(rd int, imm int, hw int)
        .emit(3531603968 + sh(hw, 21) + sh(imm, 5) + rd)

    fn movk(rd int, imm int, hw int)
        .emit(4068474880 + sh(hw, 21) + sh(imm, 5) + rd)

    fn movn(rd int, imm int, hw int)
        .emit(2457862144 + sh(hw, 21) + sh(imm, 5) + rd)

    # rd = v (любое 64-битное число): movz или movn и movk для остальных кусков
    fn mov_imm(rd int, v int)
        parts = [(v // P2[16 * i]) & 65535 for i in 0..3]
        ones = len([p for p in parts if p == 65535])
        zeros = len([p for p in parts if p == 0])
        if ones > zeros
            first = -1
            for i in 0..3
                if parts[i] != 65535 and first < 0 then first = i
            if first < 0
                .movn(rd, 0, 0)
                return
            .movn(rd, parts[first] ^ 65535, first)
            for i in first + 1..3
                if parts[i] != 65535 then .movk(rd, parts[i], i)
            return
        first = -1
        for i in 0..3
            if parts[i] != 0 and first < 0 then first = i
        if first < 0
            .movz(rd, 0, 0)
            return
        .movz(rd, parts[first], first)
        for i in first + 1..3
            if parts[i] != 0 then .movk(rd, parts[i], i)

    fn rrr(base int, rd int, rn int, rm int)
        .emit(base + sh(rm, 16) + sh(rn, 5) + rd)

    fn add(rd int, rn int, rm int) = .rrr(2332033024, rd, rn, rm)
    fn adds(rd int, rn int, rm int) = .rrr(2868903936, rd, rn, rm)
    fn sub(rd int, rn int, rm int) = .rrr(3405774848, rd, rn, rm)
    fn subs(rd int, rn int, rm int) = .rrr(3942645760, rd, rn, rm)
    fn and_(rd int, rn int, rm int) = .rrr(2315255808, rd, rn, rm)
    fn orr(rd int, rn int, rm int) = .rrr(2852126720, rd, rn, rm)
    fn eor(rd int, rn int, rm int) = .rrr(3388997632, rd, rn, rm)
    fn mul(rd int, rn int, rm int) = .rrr(2600500224, rd, rn, rm)
    fn smulh(rd int, rn int, rm int) = .rrr(2604694528, rd, rn, rm)
    fn sdiv(rd int, rn int, rm int) = .rrr(2596277248, rd, rn, rm)

    # rd = ra - rn * rm
    fn msub(rd int, rn int, rm int, ra int)
        .emit(2600501248 + sh(rm, 16) + sh(ra, 10) + sh(rn, 5) + rd)

    # rd = rm (orr rd, xzr, rm); с SP нельзя — для него add_imm(rd, SP, 0)
    fn mov(rd int, rm int)
        if rd != rm then .rrr(2852127712, rd, 0, rm)

    # dst = src, где src — промежуточный регистр, который дальше не читается: если его только что записала
    # простая команда (mov, add/sub, movz/movn, cset) и сюда нет перехода, она сразу пишет в dst
    fn mov_tmp(dst int, src int)
        n = len(.code)
        fixed = len(.fixes) > 0 and .fixes[len(.fixes) - 1].at == n - 1
        if dst != src and n > 0 and .lpos != n and not fixed
            w = .code[n - 1]
            if (w & 31) == src and .retargetable(w)
                .code[n - 1] = w - src + dst
                return
        .mov(dst, src)

    # последняя команда — mul rd, rn, rm с rd == src (и сюда нет перехода): заменить на madd r, rn, rm, ra
    fn fuse_madd(r int, src int, ra int) bool
        n = len(.code)
        fixed = len(.fixes) > 0 and .fixes[len(.fixes) - 1].at == n - 1
        if n == 0 or .lpos == n or fixed then return false
        w = .code[n - 1]
        if (w & 4292934656) != 2600500224 or (w & 31) != src or ra == src then return false
        rn = (w // 32) & 31
        rm = (w // 65536) & 31
        if rn == src or rm == src then return false
        .code[n - 1] = 2600468480 + sh(rm, 16) + sh(ra, 10) + sh(rn, 5) + r
        true

    fn retargetable(w int) bool
        m21 = w & 4280287232  # 0xFF200000: регистровые формы
        m23 = w & 4286578688  # 0xFF800000: непосредственные
        if m21 == 2852126720 or m21 == 2332033024 or m21 == 3405774848 then return true  # orr, add, sub
        if m21 == 3388997632 or m21 == 2315255808 then return true  # eor, and
        if m21 == 2600468480 or m21 == 2583691264 then return true  # mul, madd, smulh; sdiv, csel, cset
        if m23 == 2449473536 or m23 == 2466250752 then return true  # and (imm), asr
        if m23 == 2432696320 or m23 == 3506438144 then return (w // 32) & 31 != 31  # add/sub imm (не sp)
        if m23 == 3531603968 or m23 == 2457862144 then return true  # movz, movn
        (w & 4294905824) == 2594113504  # cset

    fn add_imm(rd int, rn int, imm int)
        .emit(2432696320 + sh(imm, 10) + sh(rn, 5) + rd)

    fn sub_imm(rd int, rn int, imm int)
        .emit(3506438144 + sh(imm, 10) + sh(rn, 5) + rd)

    fn adds_imm(rd int, rn int, imm int)
        .emit(2969567232 + sh(imm, 10) + sh(rn, 5) + rd)

    fn subs_imm(rd int, rn int, imm int)
        .emit(4043309056 + sh(imm, 10) + sh(rn, 5) + rd)

    fn negs(rd int, rm int) = .rrr(3942645760, rd, ZR, rm)

    fn eor1(rd int, rn int)  # rd = rn ^ 1
        .emit(3527409664 + sh(rn, 5) + rd)

    fn mvn(rd int, rm int) = .rrr(2854224864, rd, 0, rm)

    fn udiv(rd int, rn int, rm int) = .rrr(2596276224, rd, rn, rm)

    fn cmp(rn int, rm int) = .rrr(3942645791, 0, rn, rm)

    fn cmp_imm(rn int, imm int)
        .emit(4043309087 + sh(imm, 10) + sh(rn, 5))

    fn cmn_imm(rn int, imm int)
        .emit(2969567263 + sh(imm, 10) + sh(rn, 5))

    # cmp rn, rm, asr #63 — после mul и smulh: не равно — переполнение
    fn cmp_asr63(rn int, rm int) = .rrr(3951098911, 0, rn, rm)

    # если cond: флаги от rn - imm, иначе флаги = nzcv
    fn ccmp_imm(rn int, imm int, nzcv int, cond int)
        .emit(4198500352 + sh(imm, 16) + sh(cond, 12) + sh(rn, 5) + nzcv)

    fn cset(rd int, cond int)
        .emit(2594113504 + sh(cond ^ 1, 12) + rd)

    # загрузка и запись 8 байт по [rn + off], off кратно 8
    fn ldr(rt int, rn int, off int)
        .emit(4181721088 + sh(off // 8, 10) + sh(rn, 5) + rt)

    fn str_(rt int, rn int, off int)
        .emit(4177526784 + sh(off // 8, 10) + sh(rn, 5) + rt)

    # байт: [rn + rm]
    fn ldrb_r(rt int, rn int, rm int) = .rrr(945842176, rt, rn, rm)
    fn strb_r(rt int, rn int, rm int) = .rrr(941647872, rt, rn, rm)

    fn ldrb(rt int, rn int, off int)
        .emit(960495616 + sh(off, 10) + sh(rn, 5) + rt)

    # байт: [rn + off]
    fn strb(rt int, rn int, off int)
        .emit(956301312 + sh(off, 10) + sh(rn, 5) + rt)

    # пара регистров: [rn + off], [rn + off]! (pre) и [rn], off (post); off кратно 8, -512..504
    fn pair(base int, rt int, rt2 int, rn int, off int)
        .emit(base + sh((off // 8) & 127, 15) + sh(rt2, 10) + sh(rn, 5) + rt)

    fn stp(rt int, rt2 int, rn int, off int) = .pair(2835349504, rt, rt2, rn, off)
    fn stp_pre(rt int, rt2 int, rn int, off int) = .pair(2843738112, rt, rt2, rn, off)
    fn ldp(rt int, rt2 int, rn int, off int) = .pair(2839543808, rt, rt2, rn, off)
    fn ldp_post(rt int, rt2 int, rn int, off int) = .pair(2831155200, rt, rt2, rn, off)

    # rd = rn >> k (арифметический сдвиг)
    fn asr(rd int, rn int, k int)
        .emit(2470509568 + sh(k, 16) + sh(rn, 5) + rd)

    # rd = rn & (2**k - 1), 1 <= k <= 63
    fn and_low(rd int, rn int, k int)
        .emit(2453667840 + sh(k - 1, 10) + sh(rn, 5) + rd)

    # rd = если cond, то rn, иначе rm
    fn csel(rd int, rn int, rm int, cond int)
        .emit(2592079872 + sh(rm, 16) + sh(cond, 12) + sh(rn, 5) + rd)

    fn push_frame()  # stp x29, x30, [sp, #-16]!; mov x29, sp
        .emit(2847898621)
        .emit(2432697341)

    fn pop_frame()  # ldp x29, x30, [sp], #16
        .emit(2831252477)

    fn ret()
        .emit(3596551104)

    fn blr(rn int)
        .emit(3594452992 + sh(rn, 5))

    fn b(label str) = .fix(label, "b26", 335544320)
    fn bl_(label str) = .fix(label, "b26", 2483027968)
    fn bcond(cond int, label str) = .fix(label, "b19", 1409286144 + cond)
    fn cbz(rt int, label str) = .fix(label, "b19", 3019898880 + rt)
    fn cbnz(rt int, label str) = .fix(label, "b19", 3036676096 + rt)

    # переход, если бит bit (0..31) регистра rt равен нулю (tbz) или единице (tbnz); ±32 КБ
    fn tbz(rt int, bit int, label str) = .fix(label, "b14", 905969664 + sh(bit, 19) + rt)
    fn tbnz(rt int, bit int, label str) = .fix(label, "b14", 922746880 + sh(bit, 19) + rt)

    # rd = адрес метки (код или строка в __TEXT: в пределах ±1 МБ)
    fn adr(rd int, label str) = .fix(label, "adr", 268435456 + rd)

    # адрес метки данных: adrp + add
    fn addr(rd int, label str)
        .fix(label, "adrp", 2415919104 + rd)
        .fix(label, "lo12", 2432696320 + sh(rd, 5) + rd)

    # загрузка 8 байт из ячейки данных: adrp + ldr
    fn ldr_label(rt int, label str)
        .fix(label, "adrp", 2415919104 + rt)
        .fix(label, "lo12x8", 4181721088 + sh(rt, 5) + rt)

    # запись 8 байт в ячейку данных; tmp — регистр для адреса страницы
    fn str_label(rt int, label str, tmp int)
        .fix(label, "adrp", 2415919104 + tmp)
        .fix(label, "lo12x8", 4177526784 + sh(tmp, 5) + rt)

    # ---------- поправки ----------

    # адрес метки; t, c, d, b — адреса начала кода, констант, данных и обнулённой памяти
    fn addr_of(label str, t int, c int, d int, b int) int
        k = label[0]
        if k == "t"
            if label not in .tl then fail ValueError("undefined label {label}")
            return t + 4 * .tl[label]
        if k == "c" then return c + .cl[label]
        if k == "d" then return d + .dl[label]
        b + .bl[label]

    fn resolve(t int, c int, dt int, b int)
        for f in .fixes
            pc = t + 4 * f.at
            target = .addr_of(f.label, t, c, dt, b)
            w = .code[f.at]
            d = target - pc
            if f.kind == "b26"
                if d % 4 != 0 or d < -134217728 or d >= 134217728 then fail ValueError("branch out of range: {f.label}")
                w = w + ((d // 4) & 67108863)
            elif f.kind == "b14"
                if d % 4 != 0 or d < -32768 or d >= 32768 then fail ValueError("branch out of range: {f.label}")
                w = w + sh((d // 4) & 16383, 5)
            elif f.kind == "b19"
                if d % 4 != 0 or d < -1048576 or d >= 1048576 then fail ValueError("branch out of range: {f.label}")
                w = w + sh((d // 4) & 524287, 5)
            elif f.kind == "adr"
                if d < -1048576 or d >= 1048576 then fail ValueError("adr out of range: {f.label}")
                w = w + sh(d & 3, 29) + sh((d // 4) & 524287, 5)
            elif f.kind == "adrp"
                pd = target // 4096 - pc // 4096
                w = w + sh(pd & 3, 29) + sh((pd // 4) & 524287, 5)
            elif f.kind == "lo12"
                w = w + sh(target & 4095, 10)
            else  # lo12x8
                if target % 8 != 0 then fail ValueError("unaligned data: {f.label}")
                w = w + sh((target & 4095) // 8, 10)
            .code[f.at] = w
