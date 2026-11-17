# Запись исполняемого файла Mach-O для arm64 (macOS) без ld и codesign.
#
# Раскладка: заголовок и команды загрузки, затем __TEXT (__text — код, __const — строки), __DATA
# (__data — ячейки импортов, __bss — обнулённая память) и __LINKEDIT (байткод привязки dyld, пустая
# таблица символов, подпись). Импорты из libSystem (write, exit) dyld кладёт в ячейки __data по
# байткоду LC_DYLD_INFO_ONLY. Ядро arm64 запускает только подписанный код, поэтому в конце файла —
# ad-hoc подпись: CodeDirectory с SHA-256 каждой страницы по 4 КБ.

import os
from arm64 import Asm, P2

PAGE = 16384
BASE = 4294967296  # 0x100000000: под __PAGEZERO
M32 = 4294967295

# ---------- байты ----------

fn align(x int, a int) int = (x + a - 1) // a * a

type Buf(b [int] = [])

    fn u8(x int)
        .b.append(x & 255)

    fn u32(x int)
        for i in 0..3
            .b.append((x // P2[8 * i]) & 255)

    fn u64(x int)
        .u32(x & M32)
        .u32(x // P2[32])

    fn be32(x int)
        for i in 0..3
            .b.append((x // P2[8 * (3 - i)]) & 255)

    fn be64(x int)
        .be32(x // P2[32])
        .be32(x & M32)

    fn name(s str, n int)  # строка, дополненная нулями до n байт
        for i in 0..n - 1
            .b.append(if i < len(s) then ord(s[i]) else 0)

    fn bytes(xs [int])
        .b.extend(xs)

    fn pad(n int)  # нули до длины n
        while len(.b) < n
            .b.append(0)

    fn uleb(x int)
        v = x
        while true
            byte = v & 127
            v = v // 128
            if v == 0
                .b.append(byte)
                return
            .b.append(byte + 128)

# ---------- SHA-256 ----------

K = [1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221,
     3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580,
     3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986,
     2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895,
     666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037,
     2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344,
     430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779,
     1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298]

fn rotr(x int, n int) int = (x // P2[n]) | ((x * P2[32 - n]) & M32)

# SHA-256 байтов data[lo:hi]
fn sha256(data [int], lo int, hi int) [int]
    n = hi - lo
    m = data[lo:hi]
    m.append(128)
    while len(m) % 64 != 56
        m.append(0)
    bits = n * 8
    for i in 0..7
        m.append((bits // P2[8 * (7 - i)]) & 255)
    h = [1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225]
    w = [0] * 64
    for blk in 0..len(m) // 64 - 1
        o = blk * 64
        for i in 0..15
            j = o + 4 * i
            w[i] = m[j] * 16777216 + m[j + 1] * 65536 + m[j + 2] * 256 + m[j + 3]
        for i in 16..63
            x = w[i - 15]
            y = w[i - 2]
            s0 = rotr(x, 7) ^ rotr(x, 18) ^ (x // 8)
            s1 = rotr(y, 17) ^ rotr(y, 19) ^ (y // 1024)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M32
        a = h[0]
        b = h[1]
        c = h[2]
        d = h[3]
        e = h[4]
        f = h[5]
        g = h[6]
        hh = h[7]
        for i in 0..63
            t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ ((e ^ M32) & g)) + K[i] + w[i]) & M32
            t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) & M32
            hh = g
            g = f
            f = e
            e = (d + t1) & M32
            d = c
            c = b
            b = a
            a = (t1 + t2) & M32
        h[0] = (h[0] + a) & M32
        h[1] = (h[1] + b) & M32
        h[2] = (h[2] + c) & M32
        h[3] = (h[3] + d) & M32
        h[4] = (h[4] + e) & M32
        h[5] = (h[5] + f) & M32
        h[6] = (h[6] + g) & M32
        h[7] = (h[7] + hh) & M32
    out = Buf()
    for x in h
        out.be32(x)
    out.b

# ---------- файл ----------

fn seg(o Buf, name str, vm int, vmsize int, off int, size int, prot int, nsects int)
    o.u32(25)  # LC_SEGMENT_64
    o.u32(72 + 80 * nsects)
    o.name(name, 16)
    o.u64(vm)
    o.u64(vmsize)
    o.u64(off)
    o.u64(size)
    o.u32(prot)
    o.u32(prot)
    o.u32(nsects)
    o.u32(0)

fn sect(o Buf, name str, segname str, addr int, size int, off int, align2 int, flags int)
    o.name(name, 16)
    o.name(segname, 16)
    o.u64(addr)
    o.u64(size)
    o.u32(off)
    o.u32(align2)
    o.u32(0)
    o.u32(0)
    o.u32(flags)
    o.u32(0)
    o.u32(0)
    o.u32(0)

LC_SIZE = 72 + 232 + 232 + 72 + 48 + 24 + 80 + 32 + 24 + 56 + 24 + 16
NCMDS = 12

# imports — имена функций libSystem без "_"; их ячейки — a.dslot(имя). entry — метка точки входа.
fn emit_file(a Asm, entry str, imports [str], path str, ident str)
    for name in imports
        a.dslot(name)
    text_off = align(32 + LC_SIZE, 16)
    const_off = align(text_off + 4 * len(a.code), 16)
    text_size = align(const_off + len(a.consts), PAGE)
    data_off = text_size
    data_len = max(len(a.data), 8)
    data_size = align(data_len, PAGE)
    bss_addr = BASE + data_off + align(data_len, 16)
    data_vmsize = align(align(data_len, 16) + a.bss, PAGE)
    link_off = data_off + data_size
    a.resolve(BASE + text_off, BASE + const_off, BASE + data_off, bss_addr)
    if os.env("SIP_NMAP") != nil  # отладка: смещения меток кода в файле (для sample и lldb)
        lines = ["{text_off + 4 * at} {name}" for name, at in a.tl.items()]
        write(path + ".map", "\n".join(sorted(lines)) + "\n")

    # __LINKEDIT: привязка, строки символов, подпись
    link = Buf()
    for name in imports
        link.u8(17)  # SET_DYLIB_ORDINAL_IMM 1
        link.u8(64)  # SET_SYMBOL_TRAILING_FLAGS_IMM 0
        link.name("_" + name, len(name) + 2)
        link.u8(81)  # SET_TYPE_IMM pointer
        link.u8(114)  # SET_SEGMENT_AND_OFFSET_ULEB сегмент 2 (__DATA)
        link.uleb(a.dl["d:" + name])
        link.u8(144)  # DO_BIND
    link.u8(0)
    bind_size = len(link.b)
    link.pad(align(bind_size, 8))
    str_off = len(link.b)
    link.pad(str_off + 8)
    sig_off = link_off + align(len(link.b), 16)
    nslots = (sig_off + 4095) // 4096
    ident_len = len(ident) + 1
    cd_len = 88 + ident_len + 32 * nslots
    sig_len = 20 + cd_len
    link_size = sig_off + sig_len - link_off

    o = Buf()
    o.u32(4277009103)  # MH_MAGIC_64
    o.u32(16777228)  # CPU_TYPE_ARM64
    o.u32(0)
    o.u32(2)  # MH_EXECUTE
    o.u32(NCMDS)
    o.u32(LC_SIZE)
    o.u32(2097285)  # NOUNDEFS | DYLDLINK | TWOLEVEL | PIE
    o.u32(0)
    seg(o, "__PAGEZERO", 0, BASE, 0, 0, 0, 0)
    seg(o, "__TEXT", BASE, text_size, 0, text_size, 5, 2)
    sect(o, "__text", "__TEXT", BASE + text_off, 4 * len(a.code), text_off, 4, 2147484672)
    sect(o, "__const", "__TEXT", BASE + const_off, len(a.consts), const_off, 4, 0)
    seg(o, "__DATA", BASE + data_off, data_vmsize, data_off, data_size, 3, 2)
    sect(o, "__data", "__DATA", BASE + data_off, data_len, data_off, 4, 0)
    sect(o, "__bss", "__DATA", bss_addr, a.bss, 0, 4, 1)
    seg(o, "__LINKEDIT", BASE + data_off + data_vmsize, align(link_size, PAGE), link_off, link_size, 1, 0)
    o.u32(2147483682)  # LC_DYLD_INFO_ONLY
    o.u32(48)
    o.u32(0)
    o.u32(0)
    o.u32(link_off)
    o.u32(bind_size)
    for i in 0..5
        o.u32(0)
    o.u32(2)  # LC_SYMTAB
    o.u32(24)
    o.u32(link_off + str_off)
    o.u32(0)
    o.u32(link_off + str_off)
    o.u32(8)
    o.u32(11)  # LC_DYSYMTAB
    o.u32(80)
    o.pad(len(o.b) + 72)
    o.u32(14)  # LC_LOAD_DYLINKER
    o.u32(32)
    o.u32(12)
    o.name("/usr/lib/dyld", 20)
    o.u32(2147483688)  # LC_MAIN
    o.u32(24)
    o.u64(a.tl[entry] * 4 + text_off)
    o.u64(0)
    o.u32(12)  # LC_LOAD_DYLIB
    o.u32(56)
    o.u32(24)
    o.u32(2)
    o.u32(65536)
    o.u32(65536)
    o.name("/usr/lib/libSystem.B.dylib", 32)
    o.u32(50)  # LC_BUILD_VERSION
    o.u32(24)
    o.u32(1)  # macOS
    o.u32(720896)  # 11.0
    o.u32(720896)
    o.u32(0)
    o.u32(29)  # LC_CODE_SIGNATURE
    o.u32(16)
    o.u32(sig_off)
    o.u32(sig_len)
    if len(o.b) != 32 + LC_SIZE then fail ValueError("mach-o: load commands size {len(o.b)}")

    o.pad(text_off)
    for w in a.code
        o.u32(w)
    o.pad(const_off)
    o.bytes(a.consts)
    o.pad(data_off)
    o.bytes(a.data)
    o.pad(link_off)
    o.bytes(link.b)
    o.pad(sig_off)

    # подпись: SuperBlob с одним CodeDirectory
    o.be32(4208856256)  # CSMAGIC_EMBEDDED_SIGNATURE
    o.be32(sig_len)
    o.be32(1)
    o.be32(0)  # CSSLOT_CODEDIRECTORY
    o.be32(20)
    o.be32(4208856066)  # CSMAGIC_CODEDIRECTORY
    o.be32(cd_len)
    o.be32(132096)  # версия 0x20400
    o.be32(131074)  # ADHOC | LINKER_SIGNED
    o.be32(88 + ident_len)  # hashOffset
    o.be32(88)  # identOffset
    o.be32(0)  # nSpecialSlots
    o.be32(nslots)
    o.be32(sig_off)  # codeLimit
    o.u8(32)  # hashSize
    o.u8(2)  # SHA-256
    o.u8(0)
    o.u8(12)  # страница 4 КБ
    o.be32(0)
    o.be32(0)
    o.be32(0)
    o.be32(0)
    o.be64(0)
    o.be64(0)  # execSegBase
    o.be64(text_size)  # execSegLimit
    o.be64(1)  # CS_EXECSEG_MAIN_BINARY
    o.name(ident, ident_len)
    for i in 0..nslots - 1
        o.bytes(sha256(o.b, i * 4096, min(i * 4096 + 4096, sig_off)))
    write(path, os.bytes(o.b))
    os.chmod(path, 493)
