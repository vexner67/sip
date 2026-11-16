# Генератор C из проверенного дерева Sip: перенос siplang/cgen.py.
#
# Выражения превращаются в выражения C. Если для выражения нужны инструкции (генератор списка,
# строка с подстановками), они выводятся перед текущей инструкцией во временные переменные.
# Короткое вычисление and, or и if-выражений сохраняется: такие инструкции попадают внутрь условия.
# Вывод совпадает с siplang/cgen.py байт в байт (это проверяет selfhost/parity.py).

import os
import path
import checker
import creg
import modules
import parser
from parser import N
from checker import Ty, Fn, Var, Ann, PInfo, INT, FLOAT, BOOL, STR, UNIT, RANGE, PTR, prune, is_gen, base_of
from checker import fields_of, variants_of, list_t, dict_t, tuple_t, fn_t, fn_params, fn_ret, meths, show
from creg import deep, key, ctype, is_ref, fmt_call, opt_has, opt_val, nil_code, repr_call, eq_expr, cmp_fn, hash_fn
from creg import c_bytes, is_p, opt_t, set_t, task_t
from modules import SipErr, isn, nm, flag

NOANN = Ann()

type Line(d int, t str)

type Cap(lines [Line], depth int)

fn err_id(t Ty) int = 1000 + crc32(key(t)) % 1000000000

# ---------- CRC-32 (как zlib.crc32): номер вида ошибки для типа-значения ----------

fn crc_table() [int]
    out: [int] = []
    for n in 0..255
        c = n
        for _ in 0..7
            c = if (c & 1) == 1 then 3988292384 ^ (c // 2) else c // 2
        out.append(c)
    out

CRC = crc_table()

fn crc32(s str) int
    c = 4294967295
    for i in 0..len(s) - 1
        c = CRC[(c ^ ord(s[i])) & 255] ^ (c // 256)
    c ^ 4294967295

# ---------- мелочи ----------

fn is_word(ch str) bool
    b = ord(ch)
    (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b >= 128

fn is_digit(ch str) bool = ch >= "0" and ch <= "9"

# ^[A-Za-z_][A-Za-z_0-9]*$ или ^-?[0-9.]+(LL)?$
fn simple(code str) bool
    if code == "" then return false
    if not is_digit(code[0]) and code[0] != "-" and code[0] != "."
        for i in 0..len(code) - 1
            b = ord(code[i])
            if not ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95)
                return false
        return true
    s = if code[0] == "-" then code[1:] else code
    if s.endswith("LL") then s = s[:len(s) - 2]
    if s == "" then return false
    for i in 0..len(s) - 1
        if not (is_digit(s[i]) or s[i] == ".") then return false
    true

# имена C в тексте (\b[A-Za-z_][A-Za-z0-9_]*\b)
fn idents(code str) {str}
    out: {str} = set()
    i = 0
    n = len(code)
    while i < n
        if is_word(code[i])
            j = i
            while j < n and is_word(code[j])
                j += 1
            if not is_digit(code[i])
                w = code[i:j]
                ok = true
                for q in 0..len(w) - 1
                    if ord(w[q]) >= 128 then ok = false
                if ok then out.add(w)
            i = j
        else
            i += 1
    out

fn basename(p str) str
    i = p.rfind("/")
    if i >= 0 then p[i + 1:] else p

fn stem(p str) str
    b = basename(p)
    i = b.rfind(".")
    if i > 0 then b[:i] else b

fn last_word(p str) str
    ws = p.split()
    w = ws[len(ws) - 1]
    while w.startswith("*")
        w = w[1:]
    w

fn is_ext(fnode N) bool = len(fnode.kids) == 9

fn kids(n N) [N] = n.kids

# разбор строкового литерала Sip (как ast.literal_eval в Python): escape-последовательности -> байты UTF-8
fn hexval(ch str) int
    b = ord(ch)
    if b >= 48 and b <= 57 then return b - 48
    if b >= 97 and b <= 102 then return b - 87
    if b >= 65 and b <= 70 then return b - 55
    -1

fn unescape(raw str) str
    out: [str] = []
    i = 0
    n = len(raw)
    while i < n
        ch = raw[i]
        if ch != "\\" or i + 1 >= n
            out.append(ch)
            i += 1
            continue
        c = raw[i + 1]
        if c == "n"
            out.append("\n")
        elif c == "t"
            out.append("\t")
        elif c == "r"
            out.append("\r")
        elif c == "\\"
            out.append("\\")
        elif c == "'"
            out.append("'")
        elif c == "\""
            out.append("\"")
        elif c == "a"
            out.append(chr(7))
        elif c == "b"
            out.append(chr(8))
        elif c == "f"
            out.append(chr(12))
        elif c == "v"
            out.append(chr(11))
        elif c == "\n"
            pass
        elif c >= "0" and c <= "7"
            v = 0
            j = i + 1
            while j < n and j < i + 4 and raw[j] >= "0" and raw[j] <= "7"
                v = v * 8 + ord(raw[j]) - 48
                j += 1
            out.append(chr(v))
            i = j
            continue
        elif c == "x" or c == "u" or c == "U"
            w = 8
            if c == "x" then w = 2
            if c == "u" then w = 4
            v = 0
            ok = i + 2 + w <= n
            if ok
                for j in (i + 2)..(i + 1 + w)
                    h = hexval(raw[j])
                    if h < 0 then ok = false else v = v * 16 + h
            if ok
                out.append(chr(v))
                i = i + 2 + w
                continue
            out.append("\\" + c)
        else
            out.append("\\" + c)
        i += 2
    "".join(out)

# ---------- генератор ----------

type CGen(c checker.Checker, file str, ld modules.Loader, reg creg.Registry, uses_http bool = false,
          uses_async bool = false, lam_rets [Ty] = [], uid int = 0, fn_code [str] = [], protos [str] = [],
          statics [str] = [], wrappers {str: bool} = {}, insts {str: bool} = {}, ninsts int = 0,
          pend_f [Fn] = [], pend_a [[Ty]] = [], pend_n [str] = [], isuf str = "", vtables {str: bool} = {},
          fi Fn? = nil, lines [Line] = [], depth int = 1, decls [str] = [], ctl [str] = [], split bool = false)

    # ---------- общее ----------

    fn err(msg str, node N?)
        line = if node == nil then 0 else node.line
        fail SipErr(msg, .file, line, 0)

    fn an(n N) Ann = if n.an == 0 then NOANN else .c.ans[n.an]

    fn rty(n N) Ty = .c.tys[n.ty]

    # тип значения, которое даёт ex(node): с учётом преобразований T <-> T?
    fn ty(n N) Ty
        a = .an(n)
        if a.cty != nil
            ct: Ty = a.cty
            return deep(ct)
        deep(.rty(n))

    fn ct(t Ty) str
        .reg.need(t)
        ctype(t)

    fn k(t Ty) str = .reg.need(t)

    fn fresh(prefix str = "t") str
        .uid += 1
        "_{prefix}{.uid}"

    fn tmp(ctp str, prefix str = "t") str
        name = .fresh(prefix)
        .decls.append("{ctp} {name};")
        name

    fn emit(text str)
        .lines.append(Line(.depth, text))

    fn cap_start() Cap
        c = Cap(.lines, .depth)
        .lines = []
        c

    fn cap_end(c Cap) [Line]
        got = .lines
        .lines = c.lines
        .depth = c.depth
        [Line(l.d - c.depth, l.t) for l in got]

    fn replay(ls [Line])
        for l in ls
            .lines.append(Line(.depth + l.d, l.t))

    fn spill(code str, t Ty) str
        if simple(code) then return code
        name = .tmp(.ct(t))
        .emit("{name} = {code};")
        name

    fn cur() Fn
        f: Fn = .fi
        f

    # ---------- программа ----------

    fn all_fns() [Fn] = [fi for fi in .c.fns.values()] + .c.methods

    # единица компиляции: функции и глобальные переменные модулей mods (см. cgen.py)
    fn unit(mods {str}, root bool, split bool) [str]
        .split = split
        defined: {str} = set()
        for fi in .all_fns()
            if not fi.allparams and fi.mod in mods
                .gen_fn(fi)  # обобщённые — по экземпляру на каждый набор типов, когда их вызовут
                defined.add(fi.cname)
        for top in .c.tops
            if top.mod in mods
                .gen_fn(top, true)
                defined.add(top.cname)
        main = if root then .gen_main() else ""
        while .pend_f
            f = .pend_f.pop(0)
            a = .pend_a.pop(0)
            n = .pend_n.pop(0)
            .gen_instance(f, a, n)
        storage = if split then "" else "static "
        root_file = .ld.files[0][1]
        globals: [str] = []
        for v in .c.globals.values()
            if v.mod in mods
                globals.append("{if v.mod != root_file then storage else 'static '}{.ct(v.ty)} {v.cname};")
                defined.add(v.cname)
        jimpls = .reg.json_impls()
        externs = if split then .externs(defined, "\n".join(.statics + jimpls + .fn_code + [main])) else []
        src: [str] = []
        for i, fp in enumerate(.ld.files)
            off, p = fp
            lines = .ld.srcs[i]
            if p in mods
                src.append("{storage}const char *const SIP_SRC_{i}[] = {{")
                src.extend(["    {c_bytes(line)}," for line in lines])
                src.append("}};")
                src.append("{storage}const int SIP_NSRC_{i} = {len(lines)};")
            elif root  # строки других модулей — в их единицах: правка модуля не меняет эту
                src.append("extern const char *const SIP_SRC_{i}[];")
                src.append("extern const int SIP_NSRC_{i};")
        if root
            src.append("const sip_srcfile SIP_FILES[] = {{")
            for i, fp in enumerate(.ld.files)
                off, p = fp
                src.append("    {{{off}, {c_bytes(p)}, &SIP_NSRC_{i}, SIP_SRC_{i}, {if .c.is_std(p) then 1 else 0}}},")
            src.append("}};")
            src.append("const int SIP_NFILES = {len(.ld.files)};")
        [.reg.code(), "/* ---- программа ---- */"] + globals + externs + .statics + src + .protos + jimpls + .fn_code + [main]

    # объявления функций и переменных из других единиц, которые упоминаются в code
    fn externs(defined {str}, code str) [str]
        out: [str] = []
        fns: {str: Fn} = {}
        for fi in .all_fns() + .c.tops
            if not fi.allparams then fns[fi.cname] = fi
        vars: {str: Var} = {}
        for v in .c.globals.values()
            vars[v.cname] = v
        names: [str] = []
        for w in idents(code)
            if (w in fns or w in vars) and w not in defined then names.append(w)
        for name in sorted(names)
            if name in vars
                out.append("extern {.ct(vars[name].ty)} {name};")
                continue
            obj = fns[name]
            ps: [str] = []
            if obj.owner != nil
                ow: Ty = obj.owner
                ps.append(.ct(ow))
            ps.extend([.ct(p.ty) for p in obj.params])
            ret = deep(obj.ret)
            if obj.is_async then ret = task_t(ret)
            pj = ", ".join(ps)
            out.append("{.ct(ret)} {name}({if pj == '' then 'void' else pj});")
        out

    # static, если функцию не вызывают из других единиц компиляции
    fn linkage(fi Fn) str
        # главный модуль никто не импортирует: его функции static, и clang волен их встраивать и выкидывать
        if .split and fi.parent == nil and not fi.allparams and fi.mod != .ld.files[0][1] then return ""
        "static "

    fn gen_main() str
        .begin(.c.tops[len(.c.tops) - 1])
        if .c.mainfn != nil
            m: Fn = .c.mainfn
            usage = stem(.file)
            star = if "*" in m.stars then m.stars["*"] else -1
            for idx, p in enumerate(m.params)
                name = p.name
                t = p.ty
                fl = name.replace("_", "-")
                if prune(t).k == "opt" then t = prune(t).a[0]
                if idx == star
                    usage = usage + " [{name.upper()}...]"
                elif p.default == nil
                    usage = usage + " {name.upper()}"
                elif is_p(t, BOOL)
                    usage = usage + " [--{fl}]"
                else
                    usage = usage + " [--{fl} {name.upper()}]"
            u = c_bytes(usage)
            .emit("sip_args_init(argc, argv);")
            .emit("sip_args_help({u});")
            args: [str] = []
            pos = 0
            rest_var = ""
            rest_t = UNIT
            rest_flag = ""
            for idx, p in enumerate(m.params)
                name = p.name
                flg = c_bytes(name.replace("_", "-"))
                full = deep(p.ty)
                pt = if full.k == "opt" then prune(full.a[0]) else full
                conv = .arg_conv(pt)
                var = .tmp(.ct(full), "a")
                if idx == star
                    rest_var = var  # заполняется после флагов: им нужны свои значения
                    rest_t = full
                    rest_flag = flg
                elif p.default == nil
                    s = "sip_positional({pos}, {c_bytes(name)}, {u})"
                    pos += 1
                    .emit("{var} = " + (if conv != "" then "{conv}({s}, {flg}, {u});" else "sip_cstr({s});"))
                elif is_p(pt, BOOL) and full.id == pt.id
                    d: N = p.default
                    .emit("{var} = sip_flag_bool({flg}, {.ex(d)});")
                else
                    d: N = p.default
                    s = .tmp("const char *", "s")
                    .emit("{s} = sip_flag({flg}, {u});")
                    val = if conv != "" then "{conv}({s}, {flg}, {u})" else "sip_cstr({s})"
                    .emit("{var} = {s} ? {.convert(val, pt, full, 0)} : {.ex(d)};")
                args.append(var)
            if rest_var != ""
                k = .k(rest_t)
                et = deep(rest_t.a[0])
                conv = .arg_conv(et)
                s = .tmp("const char *", "s")
                val = if conv != "" then "{conv}({s}, {rest_flag}, {u})" else "sip_cstr({s})"
                .emit("{rest_var} = {k}_new(0);")
                .emit("while (({s} = sip_rest_next()) != NULL) {k}_push({rest_var}, {val});")
            .emit("sip_args_done(" + u + ");")
            call = "{m.cname}({', '.join(args)})"
            if m.is_async  # async fn main: сразу выполнить задачу
                call = "{.k(task_t(deep(m.ret)))}_await({call}, {m.node.line})"
            .emit(call + ";")
        body = .finish()
        ("int main(int argc, char **argv) {{\n" +
            "    sip_gc_init(__builtin_frame_address(0));\n" +
            "    static char sip_outbuf[1 << 16];\n" +
            "    setvbuf(stdout, sip_outbuf, _IOFBF, sizeof sip_outbuf);\n" +
            "    (void)argc; (void)argv;\n" +
            "".join(["    {t.cname}();\n" for t in .c.tops]) +
            body +
            "    fflush(stdout);\n" +
            "    return 0;\n" +
            "}}\n")

    fn arg_conv(t Ty) str
        if is_p(t, INT) then return "sip_arg_int"
        if is_p(t, FLOAT) then return "sip_arg_float"
        if is_p(t, BOOL) then return "sip_arg_bool"
        ""

    fn begin(fi Fn)
        .fi = fi
        .lines = []
        .decls = []
        .depth = 1
        .ctl = []

    fn finish() str
        out = ["    {d}" for d in .decls]
        out.extend(["    " * l.d + l.t for l in .lines])
        "\n".join(out) + (if out then "\n" else "")

    fn in_std(node N) bool = .in_std_line(node.line)

    fn in_std_line(line int) bool
        if line == 0 then return false
        f, _ = .ld.locate(line)
        .c.is_std(f)

    # вызов функции рантайма на Sip (std/rt.sip); line — для ошибок: они указывают на код пользователя
    fn rt(name str, args [str], line int = 0) str
        if line != 0 and not .in_std_line(line) then .emit("sip_std_line = {line};")
        "f_std__rt__{name}({', '.join(args)})"

    fn c_name(ct str) str
        if ct == "int8_t" then return "i8"
        if ct == "int16_t" then return "i16"
        if ct == "int32_t" then return "i32"
        if ct == "uint8_t" then return "u8"
        if ct == "uint16_t" then return "u16"
        if ct == "uint32_t" then return "u32"
        if ct == "uint64_t" then return "u64"
        if ct == "size_t" then return "usize"
        ct

    fn c_range(ct str) (str, str)
        if ct == "int8_t" then return ("INT8_MIN", "INT8_MAX")
        if ct == "int16_t" then return ("INT16_MIN", "INT16_MAX")
        if ct == "int32_t" then return ("INT32_MIN", "INT32_MAX")
        if ct == "uint8_t" then return ("0", "UINT8_MAX")
        if ct == "uint16_t" then return ("0", "UINT16_MAX")
        if ct == "uint32_t" then return ("0", "UINT32_MAX")
        if ct == "uint64_t" or ct == "size_t" then return ("0", "")
        ("", "")

    # обёртка extern fn: значения Sip -> типы C, вызов, результат -> значение Sip
    fn gen_extern(fi Fn)
        n = fi.node
        ext = n.kids[8]
        sip_abi = ext.kids[0].s == "sip"
        dn = checker.dname(n)
        csym = ext.kids[1].s
        line = n.line
        params: [str] = []
        cparams: [str] = []
        args: [str] = []
        pre: [str] = []
        for p, cn in zip(fi.params, ext.kids[2].kids)
            name = p.name
            c = if isn(cn) then "" else cn.s
            pt = deep(p.ty)
            v = "v_{name}"
            params.append("{.ct(p.ty)} {v}")
            if sip_abi
                args.append(v)
                continue
            if pt.id == INT.id
                ctp = if c != "" then c else "int64_t"
                lo, hi = .c_range(ctp)
                if lo != ""
                    cond = "{v} < {lo}" + (if hi != "" then " || {v} > {hi}" else "")
                    msg = c_bytes("argument '{name}' of {dn}() does not fit in C {.c_name(ctp)}")
                    pre.append("if (SIP_UNLIKELY({cond})) sip_raise(SIP_E_OverflowError, SIP_LIT({msg}), {line});")
                cparams.append(ctp)
                args.append("({ctp}){v}")
            elif pt.id == FLOAT.id
                cd = if c != "" then c else "double"
                cparams.append(cd)
                args.append("({cd}){v}")
            elif pt.id == BOOL.id
                cparams.append("bool")
                args.append(v)
            elif pt.id == STR.id
                cparams.append("const char *")
                args.append("sip_ffi_cstr({v})")
            elif pt.k == "opt" and is_p(pt.a[0], STR)
                cparams.append("const char *")
                args.append("({v}.has ? sip_ffi_cstr({v}.v) : NULL)")
            else  # ptr, ptr?
                cparams.append("void *")
                args.append(v)
        rt = deep(fi.ret)
        body = pre[:]
        cretn = ext.kids[3]
        cret0 = if isn(cretn) then "" else cretn.s
        if sip_abi
            call = "{csym}({', '.join(args)})"
            if rt.k == "opt" and is_p(rt.a[0], STR)
                body.append("sip_str r = {call};")
                body.append("return r.p ? (({.ct(rt)}){{true, r}}) : {nil_code(rt)};")
            elif rt.id == UNIT.id
                body.append("{call};")
            else
                body.append("return {call};")
        else
            cret = "void *"
            if rt.id == UNIT.id
                cret = "void"
            elif rt.id == INT.id
                cret = if cret0 != "" then cret0 else "int64_t"
            elif rt.id == FLOAT.id
                cret = if cret0 != "" then cret0 else "double"
            elif rt.id == BOOL.id
                cret = "bool"
            elif rt.id == STR.id or (rt.k == "opt" and is_p(rt.a[0], STR))
                cret = "const char *"
            sym = "sipc_{fi.cname}"
            cj = ", ".join(cparams)
            .fn_code.append("extern {cret} {sym}({if cj == '' then 'void' else cj}) " +
                            "__asm__(SIP_SYM({c_bytes(csym)}));\n")
            call = "{sym}({', '.join(args)})"
            null = c_bytes("{dn}() returned NULL")
            if rt.id == UNIT.id
                body.append("{call};")
            else
                body.append("{cret} r = {call};")
                if rt.id == INT.id and (cret == "uint64_t" or cret == "size_t")
                    msg = c_bytes("{dn}() result does not fit in int")
                    body.append("if (SIP_UNLIKELY(r > (uint64_t)INT64_MAX)) " +
                                "sip_raise(SIP_E_OverflowError, SIP_LIT({msg}), {line});")
                if rt.id == STR.id or rt.id == PTR.id
                    body.append("if (SIP_UNLIKELY(!r)) sip_raise(SIP_E_NilError, SIP_LIT({null}), {line});")
                if rt.id == STR.id
                    body.append("return sip_from_c(r);")
                elif rt.k == "opt" and is_p(rt.a[0], STR)
                    body.append("return r ? (({.ct(rt)}){{true, sip_from_c(r)}}) : {nil_code(rt)};")
                elif rt.id == INT.id or rt.id == FLOAT.id
                    body.append("return ({.ct(rt)})r;")
                else
                    body.append("return r;")
        pj = ", ".join(params)
        sig = "{.linkage(fi)}{.ct(rt)} {fi.cname}({if pj == '' then 'void' else pj})"
        .protos.append(sig + ";")
        .fn_code.append(sig + " {{\n" + "".join(["    {b}\n" for b in body]) + "}}\n")

    fn gen_fn(fi Fn, top = false)
        if is_ext(fi.node)
            .gen_extern(fi)
            return
        .begin(fi)
        vol = if fi.has_try then "volatile " else ""
        params: [str] = []
        if fi.owner != nil
            ow: Ty = fi.owner
            params.append("{.ct(ow)} self")
        if fi.parent != nil
            params.append("void *envp")
            if fi.captures
                .decls.append("struct env_{fi.cname} *env = envp;")
                for v in fi.captures.values()
                    .decls.append("{.ct(v.ty)} {v.cname} = env->{v.cname};")
            rv: Var = fi.recvar
            .decls.append("{.ct(rv.ty)} {rv.cname} = {{{fi.cname}, envp}};")
        for p in fi.params
            var = fi.locals[p.name]
            if fi.has_try
                params.append("{.ct(p.ty)} p_{p.name}")
                .decls.append("volatile {.ct(p.ty)} {var.cname} = p_{p.name};")
            else
                params.append("{.ct(p.ty)} {var.cname}")
        if not top
            for var in fi.locals.values()
                if var.kind == "local" then .decls.append("{vol}{.ct(var.ty)} {var.cname} = {{0}};")
        for var in fi.extra
            .decls.append("{.ct(var.ty)} {var.cname} = {{0}};")
        .block(fi.body)
        ret = deep(fi.ret)
        if ret.id != UNIT.id
            .emit("sip_raise(SIP_E_Error, SIP_LIT(\"{fi.name}() ended without returning a value\"), " +
                  "{.last_line(fi)});")
        rt = .ct(ret)
        name = fi.cname + (if fi.cache then "_impl" else "") + (if fi.is_async then "_body" else "")
        link = if name == fi.cname then .linkage(fi) else "static "
        pj = ", ".join(params)
        sig = "{link}{rt} {name}({if pj == '' then 'void' else pj})"
        .protos.append(sig + ";")
        .fn_code.append(sig + " {{\n" + .finish() + "}}\n")
        if fi.is_async then .gen_async(fi, params, name, ret)
        if fi.cache then .gen_cache(fi, params)

    # имя C экземпляра fi для настоящих типов targs (генерируется позже)
    fn instance(fi Fn, targs [Ty]) str
        args = [deep(a) for a in targs]
        base = if fi.cname0 != "" then fi.cname0 else fi.cname
        name = base + "__" + "_".join([key(a) for a in args])
        if name not in .insts
            if .ninsts > 5000
                .err("{fi.name}(): too many instances of a generic function (recursion over growing types?)", fi.node)
            .insts[name] = true
            .ninsts += 1
            .pend_f.append(fi)
            .pend_a.append(args)
            .pend_n.append(name)
        name

    fn gen_instance(fi Fn, args [Ty], name str)
        if fi.cname0 == "" then fi.cname0 = fi.cname
        checker.SUBST.clear()
        for P, a in zip(fi.allparams, args)
            checker.SUBST[P.id] = a
        fi.cname = name
        .isuf = name[len(fi.cname0):]
        .gen_fn(fi)
        fi.cname = fi.cname0
        .isuf = ""
        checker.SUBST.clear()

    # имя функции C для вызова (экземпляр, если функция обобщённая)
    fn call_name(e N) str
        a = .an(e)
        fi: Fn = a.f
        if not fi.allparams then return fi.cname
        .instance(fi, a.targs)

    # метод fi настоящего типа rt (для T: Shape и таблиц интерфейсов)
    fn method_name(fi Fn, rt Ty) str
        if not fi.allparams then return fi.cname
        .instance(fi, rt.a[:])

    # таблица методов интерфейса it для типа rt: адрес static const структуры
    fn vtable(it Ty, rt Ty) str
        ik = .k(it)
        rk = .k(rt)
        name = "vt_{ik}__{rk}"
        if name in .vtables then return "&{name}"
        .vtables[name] = true
        rc = .ct(rt)
        slots: [str] = []
        for mname in it.imethods
            sig = it.imethods[mname]
            fi = meths(rt)[mname]
            cname = .method_name(fi, rt)
            pdecl = ", ".join(["void *o"] + ["{.ct(p.ty)} p{i}" for i, p in enumerate(sig.params)])
            args = ", ".join(["({rc})o"] + ["p{i}" for i in 0..len(sig.params) - 1])
            thunk = "vtm_{ik}__{rk}_{mname}"
            fsig = "static {.ct(sig.ret)} {thunk}({pdecl})"
            .protos.append(fsig + ";")
            body = if is_p(deep(sig.ret), UNIT) then "{cname}({args});" else "return {cname}({args});"
            .fn_code.append("{fsig} {{ {body} }}\n")
            slots.append(thunk)
        rthunk = "vtr_{ik}__{rk}"
        .protos.append("static void {rthunk}(sip_sb *b, void *o);")
        .fn_code.append("static void {rthunk}(sip_sb *b, void *o) {{ {fmt_call(rt, 'b', '(' + rc + ')o')} }}\n")
        slots.append(rthunk)
        .protos.append("static const struct {ik}_vt {name};")
        .fn_code.append("static const struct {ik}_vt {name} = {{{', '.join(slots)}}};\n")
        "&{name}"

    # async fn f(a, b): f(a, b) только создаёт задачу, тело (f_body) выполнит await
    fn gen_async(fi Fn, params [str], body_name str, ret Ty)
        .uses_async = true
        tk = .k(task_t(ret))
        ft = .k(fn_t([], ret))
        names = [last_word(p) for p in params]
        env = "aenv_{fi.cname}"
        fj = " ".join([p + ";" for p in params])
        fields = if fj == "" then "char _unused;" else fj
        call = "{body_name}({', '.join(['e->' + n for n in names])})"
        thunk = ("static {.ct(ret)} athunk_{fi.cname}(void *envp) {{ struct {env} *e = envp; (void)e; " +
                "{if ret.id == UNIT.id then '' else 'return '}{call}; }}")
        pj = ", ".join(params)
        sig = "{.linkage(fi)}{tk} {fi.cname}({if pj == '' then 'void' else pj})"
        .protos.append("struct {env} {{ {fields} }};")
        .protos.append(sig + ";")
        sets = " ".join(["e->{n} = {n};" for n in names])
        .fn_code.append(thunk + "\n" + sig + " {{ struct {env} *e = sip_alloc(sizeof *e); {sets} " +
                        "return {tk}_new(({ft}){{athunk_{fi.cname}, e}}); }}\n")

    fn e_Await(e N) str
        a = .an(e)
        v = e.kids[0]
        if a.gather == ""
            if a.kind == "value" then return .ex(v)
            tt = .ty(v)
            return "{.k(tt)}_await({.ex(v)}, {e.line})"
        .uses_async = true
        rs: Ty = a.res
        res = deep(rs)
        tt = task_t(res)
        tk = .k(tt)
        arg = v.kids[1].kids[0]
        lt = .ty(arg)
        lst = .spill(.ex(arg), lt)
        ts = .tmp("sip_task **", "ts")
        i = .tmp("int64_t", "i")
        .emit("{ts} = sip_alloc((size_t)({lst}->n ? {lst}->n : 1) * sizeof(sip_task *));")
        if a.gather == "fns"
            .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {ts}[{i}] = &{tk}_new({lst}->d[{i}])->base;")
        else
            .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {ts}[{i}] = &{lst}->d[{i}]->base;")
        .emit("sip_gather({ts}, {lst}->n, {e.line});")
        if res.id == UNIT.id then return "((void)0)"
        out_t = list_t(res)
        ok = .k(out_t)
        out = .tmp(ok, "r")
        .emit("{out} = {ok}_new({lst}->n);")
        .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {ok}_push({out}, (({tk}){ts}[{i}])->result);")
        out

    fn last_line(fi Fn) int
        body = fi.node.kids[3].kids
        if body then body[len(body) - 1].line else fi.node.line

    fn gen_cache(fi Fn, params [str])
        names = [if not fi.has_try then fi.locals[p.name].cname else "p_{p.name}" for p in fi.params]
        types = [p.ty for p in fi.params]
        kt = if len(types) == 1 then types[0] else tuple_t(types)
        dk = .k(dict_t(kt, fi.ret))
        kc = .ct(kt)
        keyexpr = if len(types) == 1 then names[0] else "(({kc}){{{', '.join(names)}}})"
        rt = .ct(fi.ret)
        memo = "memo_{fi.cname}"
        .statics.append("static {dk} {memo};")
        sig = "{.linkage(fi)}{rt} {fi.cname}({', '.join(params)})"
        .protos.append(sig + ";")
        .fn_code.append("\n".join([
            "{sig} {{",
            "    {kc} key = {keyexpr};",
            "    if (SIP_UNLIKELY(!{memo})) {memo} = {dk}_new();",
            "    int64_t j = {dk}_find({memo}, key, {hash_fn(kt)}(key));",
            "    if (j >= 0) return {memo}->e[j].v;",
            "    {rt} r = {fi.cname}_impl({', '.join(names)});",
            "    {dk}_set({memo}, key, r);",
            "    return r;",
            "}}",
            ""]))

    # ---------- инструкции ----------

    fn block(stmts [N])
        for s in stmts
            .stmt(s)

    fn sub(stmts [N])
        .depth += 1
        .block(stmts)
        .depth -= 1

    fn stmt(s N)
        k = s.kind
        if k == "ExprStmt"
            .s_ExprStmt(s)
        elif k == "Assign"
            .s_Assign(s)
        elif k == "AnnAssign"
            .store(s.kids[0], .ex(s.kids[2]), .ty(s.kids[2]))
        elif k == "AugAssign"
            .s_AugAssign(s)
        elif k == "If"
            .s_If(s)
        elif k == "While"
            .s_While(s)
        elif k == "For"
            .s_For(s)
        elif k == "Return"
            .s_Return(s)
        elif k == "Break"
            .emit(.pops(true) + "break;")
        elif k == "Continue"
            .emit(.pops(true) + "continue;")
        elif k == "Pass"
            pass
        elif k == "FnDef"
            .s_FnDef(s)
        elif k == "Fail"
            .s_Fail(s)
        elif k == "Assert"
            .s_Assert(s)
        elif k == "Try"
            .s_Try(s)
        elif k == "With"
            .s_With(s)
        elif k == "Match"
            .s_Match(s)
        else
            .err("cannot generate {k}", s)
        pass

    fn s_ExprStmt(s N)
        e = s.kids[0]
        code = .ex(e)
        if code == "" then return
        if e.kind == "Call" or is_p(.rty(e), UNIT)
            .emit(code + ";")
        else
            .emit("(void)({code});")

    # присваивание code в target; code уже вычислен (или прост)
    fn store(target N, code str, vt Ty)
        k = target.kind
        if k == "Name"
            v: Var = .an(target).var
            .emit("{v.cname} = {code};")
        elif k == "TupleLit"
            tv = .spill(code, vt)
            items = deep(vt).a
            for i, item in enumerate(target.kids[0].kids)
                .store(item, "{tv}.f{i}", items[i])
        elif k == "SelfAttr"
            .emit("self->f_{nm(target)} = {code};")
        elif k == "Attr"
            .emit("({.ex(target.kids[0])})->f_{target.kids[1].s} = {code};")
        elif k == "Index"
            ot = .ty(target.kids[0])
            obj = .ex(target.kids[0])
            idx = .ex(target.kids[1])
            if target.s == "list"
                .emit("*{.k(ot)}_ref({obj}, {idx}, {target.line}) = {code};")
            else
                .emit("{.k(ot)}_set({obj}, {idx}, {code});")
        else
            .err("cannot assign here", target)
        pass

    fn s_Assign(s N)
        value = s.kids[1]
        targets = s.kids[0].kids
        vt = .ty(value)
        code = .ex(value)
        if len(targets) > 1 or targets[0].kind != "Name" then code = .spill(code, vt)
        for t in targets
            .store(t, code, vt)

    fn s_AugAssign(s N)
        a = .an(s)
        if a.n3 != nil
            aa: N = a.n3
            .s_Assign(aa)
            return
        b: N = a.n2
        t = s.kids[0]
        vt = .ty(s.kids[2])
        val = .spill(.ex(s.kids[2]), vt)
        tt = .ty(t)
        lv = ""
        if t.kind == "Name"
            v: Var = .an(t).var
            lv = v.cname
        elif t.kind == "SelfAttr"
            lv = "self->f_{nm(t)}"
        elif t.kind == "Attr"
            obj = .spill(.ex(t.kids[0]), .ty(t.kids[0]))
            lv = "{obj}->f_{t.kids[1].s}"
        elif t.kind == "Index"
            ot = .ty(t.kids[0])
            codes = .eval_args([t.kids[0], t.kids[1]])
            ptr = .tmp(.ct(tt) + " *", "p")
            .emit("{ptr} = {.k(ot)}_ref({codes[0]}, {codes[1]}, {t.line});")
            lv = "(*{ptr})"
        else
            .err("cannot assign here", t)
        .emit("{lv} = {.binop_code(b.kids[0].s, tt, vt, .ty(b), lv, val, s.line)};")

    fn truthy(code str, t0 Ty) str
        t = deep(t0)
        if t.id == BOOL.id then return code
        if t.id == INT.id then return "({code} != 0)"
        if t.id == FLOAT.id then return "({code} != 0.0)"
        if t.id == STR.id then return "(({code}).n != 0)"
        if t.id == RANGE.id
            r = .spill(code, t)
            return "({r}.hi >= {r}.lo)"
        if t.k == "opt"
            v = .spill(code, t)
            inner = deep(t.a[0])
            if is_gen(inner) or inner.k == "fn" then return opt_has(t, v)
            return "({opt_has(t, v)} && {.truthy(opt_val(t, v), inner)})"
        if is_gen(t) or t.k == "fn" then return "true"
        "(({code})->n != 0)"

    fn cond(node N) str = .truthy(.ex(node), .ty(node))

    fn s_If(s N)
        opened = 0
        for i, br in enumerate(s.kids[0].kids)
            cp = .cap_start()
            code = .cond(br.kids[0])
            pre = .cap_end(cp)
            if i == 0
                .replay(pre)
                .emit("if ({code}) {{")
            elif not pre
                .emit("}} else if ({code}) {{")
            else
                .emit("}} else {{")
                .depth += 1
                opened += 1
                .replay(pre)
                .emit("if ({code}) {{")
            .sub(br.kids[1].kids)
        if not isn(s.kids[1]) and s.kids[1].kids
            .emit("}} else {{")
            .sub(s.kids[1].kids)
        .emit("}}")
        for _ in 1..opened
            .depth -= 1
            .emit("}}")

    fn s_While(s N)
        cp = .cap_start()
        code = .cond(s.kids[0])
        pre = .cap_end(cp)
        .ctl.append("loop")
        if not pre
            .emit("while ({code}) {{")
        else
            .emit("for (;;) {{")
            .depth += 1
            .replay(pre)
            .emit("if (!{code}) break;")
            .depth -= 1
        .sub(s.kids[1].kids)
        .emit("}}")
        .ctl.pop()

    # цикл по range, списку, словарю или строке; on_elem(code, type) пишет тело
    fn loop(kind str, it N, on_elem fn(str, Ty))
        t = .ty(it)
        k = .tmp("int64_t", "i")
        elem = ""
        et = INT
        if kind == "range"
            lo = ""
            hi = ""
            if it.kind == "Range"
                lo = .ex(it.kids[0])
                hi = .spill(.ex(it.kids[1]), INT)
            else
                r = .spill(.ex(it), RANGE)
                lo = "{r}.lo"
                hi = "{r}.hi"
            .emit("for ({k} = {lo}; {k} <= {hi}; {k}++) {{")
            elem = k
        elif kind == "list"
            lst = .spill(.ex(it), t)
            .emit("for ({k} = 0; {k} < {lst}->n; {k}++) {{")
            elem = "{lst}->d[{k}]"
            et = t.a[0]
        elif kind == "set"
            d = .spill(.ex(it), t)
            .emit("for ({k} = 0; {k} < {d}->n; {k}++) {{")
            elem = "{d}->e[{k}].k"
            et = t.a[0]
        elif kind == "dict_keys" or kind == "dict_items"
            d = .spill(.ex(it), t)
            .emit("for ({k} = 0; {k} < {d}->n; {k}++) {{")
            if kind == "dict_keys"
                elem = "{d}->e[{k}].k"
                et = t.a[0]
            else
                et = tuple_t([t.a[0], t.a[1]])
                elem = "(({.ct(et)}){{{d}->e[{k}].k, {d}->e[{k}].v}})"
        elif kind == "str"
            sv = .spill(.ex(it), STR)
            .emit("for ({k} = 0; {k} < {sv}.n; {k}++) {{")
            elem = "((sip_str){{{sv}.p + {k}, 1}})"
            et = STR
        else
            .err("bad loop kind {kind}", it)
        .depth += 1
        on_elem(elem, et)
        .depth -= 1
        .emit("}}")

    fn bind(target N, code str, t Ty)
        if target.kind == "Name"
            v: Var = .an(target).var
            .emit("{v.cname} = {code};")
        else
            .store(target, code, t)

    fn s_For(s N)
        .loop(.an(s).kind, s.kids[1], fn(elem str, et Ty)
            .bind(s.kids[0], elem, et)
            .ctl.append("loop")
            .block(s.kids[2].kids)
            .ctl.pop()
            pass
        )

    # код выхода из блоков try и with при return/break/continue (изнутри наружу)
    fn pops(until_loop bool) str
        out = ""
        i = len(.ctl) - 1
        while i >= 0
            c = .ctl[i]
            if c == "loop" and until_loop then break
            if c == "try"
                out = out + "sip_try_pop(); "
            elif c.startswith("with:")
                out = out + "sip_try_pop(); {c[5:]}; "
            i -= 1
        out

    # with x as y: y = x.enter() (если есть), в конце — x.exit(), в том числе при ошибке
    fn s_With(s N)
        closes: [str] = []
        a = .an(s)
        for item, info in zip(s.kids[0].kids, a.withs)
            ctx = .tmp(.ct(info.ct), "ctx")
            .emit("{ctx} = {.ex(item.kids[0])};")
            if info.var != nil
                v: Var = info.var
                if info.enter != nil
                    en: Fn = info.enter
                    .emit("{v.cname} = {en.cname}({ctx});")
                else
                    .emit("{v.cname} = {ctx};")
            elif info.enter != nil
                en: Fn = info.enter
                .emit("{en.cname}({ctx});")
            exit_code = "((void)0)"
            if info.exit_fn != nil
                ex: Fn = info.exit_fn
                exit_code = "{ex.cname}({ctx})"
            t = .tmp("sip_try", "try")
            .emit("sip_try_push(&{t});")
            .emit("if (setjmp({t}.jb) == 0) {{")
            .depth += 1
            .ctl.append("with:" + exit_code)
            closes.append(exit_code)
        .block(s.kids[1].kids)
        i = len(closes) - 1
        while i >= 0
            exit_code = closes[i]
            .ctl.pop()
            .emit("sip_try_pop(); {exit_code};")
            .depth -= 1
            .emit("}} else {{")
            .emit("    {exit_code};")
            .emit("    sip_reraise();")
            .emit("}}")
            i -= 1

    fn s_Return(s N)
        n = .pops(false)
        value = s.kids[0]
        if isn(value) or is_p(deep(.rty(value)), UNIT)
            if not isn(value)
                code = .ex(value)
                if code != "" then .emit(code + ";")
            .emit(n + "return;")
            return
        code = .ex(value)
        if n != "" then code = .spill(code, if .lam_rets then .lam_rets[len(.lam_rets) - 1] else .cur().ret)
        .emit(n + "return {code};")

    fn s_FnDef(s N)
        fi: Fn = .an(s).f
        base = fi.cname
        fi.cname = base + .isuf  # своя копия в каждом экземпляре обобщённой функции
        .nested_fn(s, fi)
        fi.cname = base

    fn nested_fn(s N, fi Fn)
        caps = [v for v in fi.captures.values()]
        if caps
            fields = " ".join(["{.ct(v.ty)} {v.cname};" for v in caps])
            .statics.append("struct env_{fi.cname} {{ {fields} }};")
        sfi = .fi
        slines = .lines
        sdecls = .decls
        sdepth = .depth
        sctl = .ctl
        .gen_fn(fi)
        .fi = sfi
        .lines = slines
        .decls = sdecls
        .depth = sdepth
        .ctl = sctl
        sv: Var = .an(s).var
        fk = .k(sv.ty)
        env = "NULL"
        if caps
            env = .tmp("struct env_{fi.cname} *", "env")
            .emit("{env} = sip_alloc(sizeof *{env});")
            for v in caps
                .emit("{env}->{v.cname} = {v.cname};")
        .emit("{sv.cname} = (({fk}){{{fi.cname}, {env}}});")

    fn to_str(code str, t0 Ty) str
        t = deep(t0)
        if t.id == STR.id then return code
        if t.id == INT.id then return "sip_int_to_str({code})"
        sb = .tmp("sip_sb", "sb")
        .emit("{sb} = sip_sb_new();")
        .emit(fmt_call(t, "&{sb}", code))
        "sip_sb_done(&{sb})"

    fn s_Fail(s N)
        a = .an(s)
        if a.kind != ""
            msg = "SIP_LIT(\"\")"
            if a.n != nil
                mn: N = a.n
                msg = .to_str(.ex(mn), .ty(mn))
            .emit("sip_raise(SIP_E_{a.kind}, {msg}, {s.line});")
            return
        v = s.kids[0]
        code = .ex(v)
        if a.t != nil
            t: Ty = a.t
            obj = .spill(code, t)
            .emit("sip_raise_obj({err_id(.ty(v))}, {obj}, {.to_str(obj, .ty(v))}, {s.line});")
            return
        .emit("sip_raise(SIP_E_Error, {.to_str(code, .ty(v))}, {s.line});")

    fn s_Assert(s N)
        e = s.kids[0]
        msgn = s.kids[1]
        if isn(msgn) and e.kind == "Compare" and len(e.kids[1].kids) == 1
            op = e.kids[1].kids[0].kids[0].s
            anynil = false
            for f in .an(e).flags
                if f then anynil = true
            if op in ["==", "!=", "<", "<=", ">", ">="] and not anynil
                .assert_compare(s, e)
                return
        c = .cond(e)
        .emit("if (SIP_UNLIKELY(!{c})) {{")
        .depth += 1
        msg = if isn(msgn) then "SIP_LIT(\"assertion failed\")" else .to_str(.ex(msgn), .ty(msgn))
        .emit("sip_raise(SIP_E_AssertionError, {msg}, {s.line});")
        .depth -= 1
        .emit("}}")

    # assert a == b печатает оба значения: AssertionError: [1, 2] != [1, 3]
    fn assert_compare(s N, e N)
        o = e.kids[1].kids[0]
        op = o.kids[0].s
        right = o.kids[1]
        lt = .ty(e.kids[0])
        rt = .ty(right)
        codes = .eval_args([e.kids[0], right])
        a = .spill(codes[0], lt)
        b = .spill(codes[1], rt)
        .emit("if (SIP_UNLIKELY(!{.cmp_code(op, lt, rt, a, b)})) {{")
        .depth += 1
        sb = .tmp("sip_sb", "sb")
        .emit("{sb} = sip_sb_new();")
        mid = ""
        if op == "==" or op == "!="
            mid = if op == "==" then " != " else " == "
        else
            .emit("sip_sb_put(&{sb}, \"not \", 4);")
            mid = " {op} "
        .emit(repr_call(lt, "&{sb}", a))
        .emit("sip_sb_put(&{sb}, \"{mid}\", {len(mid)});")
        .emit(repr_call(rt, "&{sb}", b))
        .emit("sip_raise(SIP_E_AssertionError, sip_sb_done(&{sb}), {s.line});")
        .depth -= 1
        .emit("}}")

    fn s_Try(s N)
        t = .tmp("sip_try", "try")
        .emit("sip_try_push(&{t});")
        .emit("if (setjmp({t}.jb) == 0) {{")
        .ctl.append("try")
        .sub(s.kids[0].kids)
        .ctl.pop()
        .depth += 1
        .emit("sip_try_pop();")
        .depth -= 1
        .emit("}} else {{")
        .depth += 1
        for i, h in enumerate(s.kids[1].kids)
            ha = .an(h)
            c = ""
            if ha.t != nil
                et: Ty = ha.t
                c = "sip_err_kind == {err_id(et)}"
                if ha.i >= 0 then c = c + " && (({.ct(et)})sip_err_obj)->tag == {ha.i}"
            elif isn(h.kids[0]) or h.kids[0].s == "Exception"
                c = "1"
            else
                c = "sip_kind_matches(sip_err_kind, SIP_E_{h.kids[0].s})"
            .emit((if i == 0 then "if" else "}} else if") + " ({c}) {{")
            .depth += 1
            if not isn(h.kids[1])
                hv: Var = ha.var
                if ha.t != nil
                    et: Ty = ha.t
                    .emit("{hv.cname} = ({.ct(et)})sip_err_obj;")
                else
                    .emit("{hv.cname} = sip_err_msg;")
            .block(h.kids[2].kids)
            .depth -= 1
        .emit("}} else {{")
        .emit("    sip_reraise();")
        .emit("}}")
        .depth -= 1
        .emit("}}")

    fn s_Match(s N)
        st = .ty(s.kids[0])
        subj = .spill(.ex(s.kids[0]), st)
        end = .fresh("match_end")
        for arm in s.kids[1].kids
            tests: [str] = []
            binds: [str] = []
            .pat(arm.kids[0], subj, st, tests, binds, true)
            .emit("if ({if tests then ' && '.join(tests) else '1'}) {{")
            .depth += 1
            for b in binds
                .emit(b)
            if not isn(arm.kids[1])
                g = .cond(arm.kids[1])
                .emit("if ({g}) {{")
                .sub(arm.kids[2].kids)
                .depth += 1
                .emit("goto {end};")
                .depth -= 1
                .emit("}}")
            else
                .block(arm.kids[2].kids)
                .emit("goto {end};")
            .depth -= 1
            .emit("}}")
        .emit("{end}:;")

    # образец p для значения path типа t: условия -> tests, присваивания -> binds
    # unwrap = false — значение T? уже проверено на nil (второй заход того же образца)
    fn pat(p N, path str, t0 Ty, tests [str], binds [str], unwrap bool)
        t = deep(t0)
        k = p.kind
        a = .an(p)
        if k == "PWild" then return
        if a.is_nil
            tests.append("(!{opt_has(t, path)})")
            return
        if a.unwrap and unwrap and t.k == "opt"
            tests.append(opt_has(t, path))
            .pat(p, opt_val(t, path), t.a[0], tests, binds, false)
            return
        if k == "PCapture"
            v: Var = a.var
            binds.append("{v.cname} = {path};")
            return
        if k == "PLit"
            tests.append(eq_expr(t, path, .ex(p.kids[0])))
            return
        if k == "PClass"
            base = path
            sep = "->"
            fields: {str: Ty} = {}
            if t.k == "sum"
                tests.append("{path}->tag == {a.i}")
                base = "{path}->u.{nm(p)}"
                sep = "."
                for f in variants_of(t)[nm(p)]
                    fields[f.name] = f.ty
            else
                fields = fields_of(t)
            subs = p.kids[1].kids
            for fname, sp in zip(a.strs, subs)
                .pat(sp, "{base}{sep}f_{fname}", fields[fname], tests, binds, true)
            kws = p.kids[2].kids
            for fname, kv in zip(a.strs2, kws)
                .pat(kv.kids[1], "{base}{sep}f_{fname}", fields[fname], tests, binds, true)
            return
        if k == "PTuple"
            for i, sp in enumerate(p.kids[0].kids)
                if i < len(t.a) then .pat(sp, "({path}).f{i}", t.a[i], tests, binds, true)
            return
        if k == "PList"
            items = p.kids[0].kids
            star = items and items[len(items) - 1].kind == "PStar"
            fixed = len(items) - (if star then 1 else 0)
            tests.append("{path}->n {if star then '>=' else '=='} {fixed}")
            for i in 0..fixed - 1
                .pat(items[i], "{path}->d[{i}]", t.a[0], tests, binds, true)
            if star
                sv: Var = .an(items[len(items) - 1]).var
                binds.append("{sv.cname} = {.k(t)}_slice({path}, {fixed}, 0, true, false);")
            return
        if k == "POr"
            alts: [str] = []
            for alt in p.kids[0].kids
                st: [str] = []
                sb: [str] = []
                .pat(alt, path, t, st, sb, true)
                alts.append("(" + (if st then " && ".join(st) else "1") + ")")
            tests.append("(" + " || ".join(alts) + ")")
            return
        .err("unsupported pattern", p)

    # ---------- выражения ----------

    fn ex(e N) str
        code = .dispatch(e)
        a = .an(e)
        if a.cty != nil and code != ""
            to: Ty = a.cty
            code = .convert(code, .rty(e), to, e.line)
        code

    fn dispatch(e N) str
        k = e.kind
        if k == "Name" then return .e_Name(e)
        if k == "Num" then return .e_Num(e)
        if k == "Str" then return .e_Str(e)
        if k == "Call" then return .e_Call(e)
        if k == "Attr" then return "({.ex(e.kids[0])})->f_{e.kids[1].s}"
        if k == "SelfAttr" then return "self->f_{nm(e)}"
        if k == "Index" then return .e_Index(e)
        if k == "BinOp" then return .e_BinOp(e)
        if k == "Compare" then return .e_Compare(e)
        if k == "Const" then return .e_Const(e)
        if k == "Unary" then return .e_Unary(e)
        if k == "IfExpr" then return .e_IfExpr(e)
        if k == "ListLit" then return .e_ListLit(e)
        if k == "TupleLit"
            codes = .eval_args(e.kids[0].kids)
            return "(({.ct(.rty(e))}){{{', '.join(codes)}}})"
        if k == "DictLit" then return .e_DictLit(e)
        if k == "SetLit" then return .e_SetLit(e)
        if k == "Range"
            codes = .eval_args([e.kids[0], e.kids[1]])
            return "((sip_range){{{codes[0]}, {codes[1]}}})"
        if k == "Comp" then return .e_Comp(e)
        if k == "Lambda" then return .e_Lambda(e)
        if k == "Await" then return .e_Await(e)
        .err("cannot generate {k}", e)
        ""

    fn convert(code0 str, raw0 Ty, to0 Ty, line int) str
        code = code0
        raw = deep(raw0)
        to = deep(to0)
        inner = if to.k == "opt" then to.a[0] else to
        if inner.k == "iface" and raw.k != "iface" and raw.k != "opt"
            code = "(({.ct(inner)}){{(void *)({code}), {.vtable(inner, raw)}}})"
            raw = inner
        if raw.k == "opt" and to.k != "opt" then return "unwrap_{.k(raw)}({code}, {line})"
        if to.k == "opt" and raw.k != "opt"
            .k(to)
            return if is_ref(to.a[0]) then code else "(({ctype(to)}){{true, {code}}})"
        code

    fn call_fn(f str, args [str]) str = "{f}.fn({f}.env{''.join([', ' + a for a in args])})"

    # есть ли в выражении вызов (тогда важен порядок вычисления)
    fn has_call(n N) bool
        k = n.kind
        if k == "Call" or k == "Comp" then return true
        if k == "Str"
            for p in n.kids[0].kids
                if p.kind == "Interp" then return true
            return false
        if k == "TName" or k == "TList" or k == "TDict" or k == "TTuple" then return false
        for c in n.kids
            if .has_call(c) then return true
        false

    # аргументы вычисляются слева направо, как в Python
    fn eval_args(nodes [N]) [str]
        codes: [str] = []
        for n in nodes
            cp = .cap_start()
            code = .ex(n)
            pre = .cap_end(cp)
            if pre and codes
                codes = [.spill(c, .ty(nodes[i])) for i, c in enumerate(codes)]
            .replay(pre)
            codes.append(code)
        calls = 0
        for n in nodes
            if .has_call(n) then calls += 1
        if calls >= 2 then codes = [.spill(c, .ty(nodes[i])) for i, c in enumerate(codes)]
        codes

    fn e_Num(e N) str
        text = nm(e).replace("_", "")
        if is_p(.rty(e), FLOAT)
            if text.find(".") < 0 and text.lower().find("e") < 0 then text = text + ".0"
            return text
        digits = text
        while len(digits) > 1 and digits.startswith("0")
            digits = digits[1:]
        if len(digits) > 19 or (len(digits) == 19 and digits >= "9223372036854775808")
            .err("integer literal is too large for int (64-bit)", e)
        big = len(digits) > 10 or (len(digits) == 10 and digits > "2147483647")
        if big then "{text}LL" else text

    fn e_Str(e N) str
        parts = e.kids[0].kids
        plain = true
        for p in parts
            if p.kind == "Interp" then plain = false
        if plain
            return "SIP_LIT({c_bytes(unescape(''.join([p.s for p in parts])))})"
        sb = .tmp("sip_sb", "sb")
        .emit("{sb} = sip_sb_new();")
        .str_parts(e, "&{sb}")
        "sip_sb_done(&{sb})"

    fn str_parts(e N, sb str)
        for part in e.kids[0].kids
            if part.kind != "Interp"
                data = unescape(part.s)
                if data != "" then .emit("sip_sb_put({sb}, {c_bytes(data)}, {len(data)});")
                continue
            ex = part.kids[0]
            code = .ex(ex)
            t = .ty(ex)
            if isn(part.kids[1])
                .emit(fmt_call(t, sb, code))
            else
                fmt, kind = .spec(part.kids[1].s, t, ex)
                if kind == "float" and t.id == INT.id then code = "(double)({code})"
                .emit("sip_fmt_{kind}({sb}, {c_bytes(fmt)}, {code});")

    # ([<>])?([+ ])?(0)?(\d+)?(\.\d+)?([dfFeEgGxXos%])?
    fn spec(sp str, t Ty, node N) (str, str)
        i = 0
        n = len(sp)
        align = ""
        sign = ""
        zero = ""
        width = ""
        prec = ""
        typ = ""
        if i < n and (sp[i] == "<" or sp[i] == ">")
            align = sp[i]
            i += 1
        if i < n and (sp[i] == "+" or sp[i] == " ")
            sign = sp[i]
            i += 1
        if i < n and sp[i] == "0"
            zero = "0"
            i += 1
        while i < n and is_digit(sp[i])
            width = width + sp[i]
            i += 1
        if i + 1 < n and sp[i] == "." and is_digit(sp[i + 1])
            prec = "."
            i += 1
            while i < n and is_digit(sp[i])
                prec = prec + sp[i]
                i += 1
        if i < n and "dfFeEgGxXos%".find(sp[i]) >= 0
            typ = sp[i]
            i += 1
        if i != n then .err("unsupported format spec ':{sp}'", node)
        flags = (if align == "<" or (align == "" and t.id == STR.id) then "-" else "") + sign + zero
        if t.id == STR.id
            if (typ != "" and typ != "s") or prec != "" then .err("format ':{sp}' does not apply to str", node)
            return ("%{flags}{width}.*s", "str")
        if "fFeEgG".find(typ) >= 0 and typ != "" or (t.id == FLOAT.id and typ == "") or prec != ""
            if typ == "%" then .err("format '%' is not supported", node)
            return ("%{flags}{width}{prec}{if typ == '' then 'g' else typ}", "float")
        if typ == "" or typ == "d" or typ == "x" or typ == "X" or typ == "o"
            return ("%{flags}{width}ll{if typ == '' then 'd' else typ}", "int")
        .err("unsupported format spec ':{sp}'", node)
        ("", "")

    fn e_Const(e N) str
        v = nm(e)
        if v == "None"
            .k(.rty(e))
            return nil_code(.rty(e))
        if v == "True" then "true" else "false"

    fn e_Name(e N) str
        a = .an(e)
        if a.var != nil
            v: Var = a.var
            return v.cname
        if a.f != nil
            fi: Fn = a.f
            return .fn_value(fi, deep(.rty(e)))
        if a.kind == "variant"
            st: Ty = a.t
            return "{.k(st)}_new_{a.name}()"
        a.name

    # обычная функция как значение: обёртка с пустым окружением
    fn fn_value(fi Fn, ft Ty) str
        fk = .k(ft)
        name = "fnv_{fi.cname}"
        if name not in .wrappers
            .wrappers[name] = true
            ps = ["{.ct(t)} p{i}" for i, t in enumerate(fn_params(ft))]
            call = "{fi.cname}({', '.join(['p' + str(i) for i in 0..len(ps) - 1])})"
            body = if is_p(deep(fn_ret(ft)), UNIT) then "{call};" else "return {call};"
            sig = "static {.ct(fn_ret(ft))} {name}({', '.join(['void *env'] + ps)})"
            .protos.append(sig + ";")
            .fn_code.append("{sig} {{ (void)env; {body} }}\n")
        "(({fk}){{{name}, NULL}})"

    fn e_Lambda(e N) str
        a = .an(e)
        ft = deep(.rty(e))
        fk = .k(ft)
        lid = "{a.lid}{.isuf}"
        name = "lam_{lid}"
        caps = [v for v in a.captures.values()]
        if caps
            fields = " ".join(["{.ct(v.ty)} {v.cname};" for v in caps])
            .statics.append("struct env_{lid} {{ {fields} }};")
        # тело лямбды — отдельная функция C со своим состоянием генератора
        slines = .lines
        sdecls = .decls
        sdepth = .depth
        sctl = .ctl
        .lines = []
        .decls = []
        .depth = 1
        .ctl = []
        if caps
            .decls.append("struct env_{lid} *env = envp;")
            for v in caps
                .decls.append("{.ct(v.ty)} {v.cname} = env->{v.cname};")
        vol = if a.has_try then "volatile " else ""
        for v in a.extra + a.locals
            .decls.append("{vol}{.ct(v.ty)} {v.cname} = {{0}};")
        ret = deep(fn_ret(ft))
        if not isn(e.kids[3])
            .lam_rets.append(ret)
            .block(e.kids[3].kids)
            .lam_rets.pop()
            if ret.id != UNIT.id
                .emit("sip_raise(SIP_E_Error, SIP_LIT(\"the lambda ended without returning a value\"), {e.line});")
        else
            code = .ex(e.kids[1])
            if ret.id == UNIT.id
                if code != "" then .emit(code + ";")
            else
                .emit("return {code};")
        body = .finish()
        .lines = slines
        .decls = sdecls
        .depth = sdepth
        .ctl = sctl
        params = ["void *envp"] + ["{.ct(v.ty)} {v.cname}" for v in a.pvars]
        sig = "static {.ct(fn_ret(ft))} {name}({', '.join(params)})"
        .protos.append(sig + ";")
        .fn_code.append(sig + " {{\n" + body + "}}\n")
        if not caps then return "(({fk}){{{name}, NULL}})"
        env = .tmp("struct env_{lid} *", "env")
        .emit("{env} = sip_alloc(sizeof *{env});")
        for v in caps
            .emit("{env}->{v.cname} = {v.cname};")
        "(({fk}){{{name}, {env}}})"

    fn e_Index(e N) str
        kind = e.s
        obj = e.kids[0]
        ot = .ty(obj)
        if kind == "tuple" then return "({.ex(obj)}).f{.an(e).i}"
        if kind == "slice_list" or kind == "slice_str"
            sl = e.kids[1]
            parts = [obj]
            if not isn(sl.kids[0]) then parts.append(sl.kids[0])
            if not isn(sl.kids[1]) then parts.append(sl.kids[1])
            codes = .eval_args(parts)
            j = 1
            lo = "0"
            hi = "0"
            if not isn(sl.kids[0])
                lo = codes[j]
                j += 1
            if not isn(sl.kids[1]) then hi = codes[j]
            flags = "{if isn(sl.kids[0]) then 'false' else 'true'}, {if isn(sl.kids[1]) then 'false' else 'true'}"
            f = if kind == "slice_list" then "{.k(ot)}_slice" else "sip_str_slice"
            return "{f}({codes[0]}, {lo}, {hi}, {flags})"
        codes = .eval_args([obj, e.kids[1]])
        if kind == "list" or kind == "dict" then return "{.k(ot)}_get({codes[0]}, {codes[1]}, {e.line})"
        "sip_str_at({codes[0]}, {codes[1]}, {e.line})"

    fn e_Call(e N) str
        a = .an(e)
        kind = a.ckind
        if kind == "fn"
            args = .eval_args(a.bound)
            fi: Fn = a.f
            if fi.std and not .in_std(e) then .emit("sip_std_line = {e.line};")  # ошибки внутри std — на этой строке
            return "{.call_name(e)}({', '.join(args)})"
        if kind == "method"
            codes = .eval_args([e.kids[0].kids[0]] + a.bound)
            return "{.call_name(e)}({', '.join(codes)})"
        if kind == "imethod"
            rt = deep(.ty(e.kids[0].kids[0]))
            codes = .eval_args([e.kids[0].kids[0]] + a.bound)
            if rt.k == "iface"  # через таблицу методов
                r = .spill(codes[0], rt)
                return "{r}.vt->m_{a.name}({', '.join([r + '.o'] + codes[1:])})"
            return "{.method_name(meths(rt)[a.name], rt)}({', '.join(codes)})"
        if kind == "ctor"
            rt: Ty = a.t
            return "{.k(rt)}_new({', '.join(.eval_args(a.bound))})"
        if kind == "variant"
            st: Ty = a.t
            return "{.k(st)}_new_{a.name}({', '.join(.eval_args(a.bound))})"
        if kind == "closure"
            codes = .eval_args([e.kids[0]] + a.bound)
            f = .spill(codes[0], .ty(e.kids[0]))
            return .call_fn(f, codes[1:])
        if kind == "builtin" then return .builtin(e, a.name)
        if kind == "bmethod"
            rn: N = a.n
            rt = deep(.ty(rn))
            if rt.id == STR.id then return .str_method(e, a.name)
            if rt.k == "list" then return .list_method(e, rt, a.name)
            if rt.k == "set" then return .set_method(e, rt, a.name)
            return .dict_method(e, rt, a.name)
        .err("bad call kind '{kind}'", e)
        ""

    fn binop_code(op str, lt0 Ty, rt0 Ty, res0 Ty, lc str, rc str, line int) str
        lt = deep(lt0)
        rt = deep(rt0)
        res = deep(res0)
        both_int = lt.id == INT.id and rt.id == INT.id
        num = (lt.id == INT.id or lt.id == FLOAT.id) and (rt.id == INT.id or rt.id == FLOAT.id)
        if (op == "+" or op == "-" or op == "*") and both_int
            f = if op == "+" then "add" elif op == "-" then "sub" else "mul"
            return "sip_{f}({lc}, {rc}, {line})"
        if (op == "+" or op == "-" or op == "*") and num then return "({lc} {op} {rc})"
        if op == "/"
            if both_int then return "sip_floordiv({lc}, {rc}, {line})"
            return "sip_fdiv({lc}, {rc}, {line})"
        if op == "//"
            return if both_int then "sip_floordiv({lc}, {rc}, {line})" else "sip_ffloordiv({lc}, {rc}, {line})"
        if op == "%" then return if both_int then "sip_mod({lc}, {rc}, {line})" else "sip_fmod({lc}, {rc}, {line})"
        if op == "**" then return if both_int then "sip_ipow({lc}, {rc}, {line})" else "pow({lc}, {rc})"
        if op == "+" and lt.id == STR.id then return "sip_str_concat({lc}, {rc})"
        if op == "*" and lt.id == STR.id then return .rt("str_repeat", [lc, rc], line)
        if op == "+" and lt.k == "list" then return "{.k(res)}_concat({lc}, {rc})"
        if op == "*" and lt.k == "list" then return "{.k(lt)}_repeat({lc}, {rc}, {line})"
        if op == "|" and lt.k == "dict" then return "{.k(res)}_merge({lc}, {rc})"
        if lt.k == "set"
            f = if op == "|" then "union" elif op == "&" then "inter" elif op == "-" then "diff" else "xor"
            return "{.k(lt)}_{f}({lc}, {rc})"
        if op == "|" or op == "&" or op == "^" then return "({lc} {op} {rc})"
        .err("bad operator {op}", nil)
        ""

    fn e_BinOp(e N) str
        op = e.kids[0].s
        if op == "and" or op == "or" then return .logic(e)
        codes = .eval_args([e.kids[1], e.kids[2]])
        .binop_code(op, .ty(e.kids[1]), .ty(e.kids[2]), .rty(e), codes[0], codes[1], e.line)

    fn logic(e N) str
        res = deep(.rty(e))
        a = .an(e)
        op = e.kids[0].s
        left = e.kids[1]
        right = e.kids[2]
        if a.logic_bool
            lc = .cond(left)
            cp = .cap_start()
            rc = .cond(right)
            pre = .cap_end(cp)
            if not pre then return "({lc} {if op == 'and' then '&&' else '||'} {rc})"
            t = .tmp("bool")
            .emit("{t} = {lc};")
            .emit("if ({if op == 'and' then '' else '!'}{t}) {{")
            .depth += 1
            .replay(pre)
            .emit("{t} = {rc};")
            .depth -= 1
            .emit("}}")
            return t
        if a.opt_or
            lt = .ty(left)
            lv = .spill(.ex(left), lt)
            cp = .cap_start()
            rc = .ex(right)
            pre = .cap_end(cp)
            t = .tmp(.ct(res))
            .emit("if ({.truthy(lv, lt)}) {{")
            .emit("    {t} = {opt_val(lt, lv)};")
            .emit("}} else {{")
            .depth += 1
            .replay(pre)
            .emit("{t} = {rc};")
            .depth -= 1
            .emit("}}")
            return t
        lc = .ex(left)
        cp = .cap_start()
        rc = .ex(right)
        pre = .cap_end(cp)
        lt = deep(.ty(left))
        rt = deep(.ty(right))
        if res.id == BOOL.id and lt.id == BOOL.id and rt.id == BOOL.id and not pre
            return "({lc} {if op == 'and' then '&&' else '||'} {rc})"
        t = .tmp(.ct(res))
        .emit("{t} = {lc};")
        test = .truthy(t, res)
        .emit("if ({if op == 'and' then '' else '!'}{test}) {{")
        .depth += 1
        .replay(pre)
        .emit("{t} = {rc};")
        .depth -= 1
        .emit("}}")
        t

    fn cmp_code(op str, lt0 Ty, rt0 Ty, lc str, rc str) str
        lt = deep(lt0)
        rt = deep(rt0)
        if op == "in" or op == "not in"
            neg = if op == "not in" then "!" else ""
            if rt.k == "set" then return "{neg}{.k(dict_t(rt.a[0], BOOL))}_contains({rc}, {lc})"
            if rt.k == "list" or rt.k == "dict" then return "{neg}{.k(rt)}_contains({rc}, {lc})"
            if rt.id == STR.id then return "{neg}sip_str_contains({rc}, {lc})"
            r = .spill(rc, RANGE)
            x = .spill(lc, INT)
            return "{neg}({x} >= {r}.lo && {x} <= {r}.hi)"
        lnum = lt.id == INT.id or lt.id == FLOAT.id or lt.id == BOOL.id
        rnum = rt.id == INT.id or rt.id == FLOAT.id or rt.id == BOOL.id
        if lnum and rnum then return "({lc} {op} {rc})"
        if lt.k == "set" and (op == "<=" or op == "<" or op == ">=" or op == ">")
            a0 = if op == "<=" or op == "<" then lc else rc
            b0 = if op == "<=" or op == "<" then rc else lc
            a = .spill(a0, lt)
            b = .spill(b0, lt)
            sb = "{.k(lt)}_subset({a}, {b})"
            return if op == "<=" or op == ">=" then sb else "({sb} && {a}->n < {b}->n)"
        if op == "==" then return eq_expr(lt, lc, rc)
        if op == "!=" then return "!" + eq_expr(lt, lc, rc)
        "({cmp_fn(lt)}({lc}, {rc}) {op} 0)"

    fn e_Compare(e N) str
        ops = e.kids[1].kids
        nodes = [e.kids[0]] + [o.kids[1] for o in ops]
        codes = .eval_args(nodes)
        if len(ops) > 1
            codes = [codes[0]] + [.spill(codes[i], .ty(nodes[i])) for i in 1..len(codes) - 1]
        parts: [str] = []
        flags = .an(e).flags
        for i, o in enumerate(ops)
            op = o.kids[0].s
            if i < len(flags) and flags[i]
                j = if nodes[i].kind == "Const" and nm(nodes[i]) == "None" then i + 1 else i
                ot = .ty(nodes[j])
                test = "false"
                if ot.k == "opt" then test = if is_ref(ot.a[0]) then "({codes[j]} == NULL)" else "(!({codes[j]}).has)"
                parts.append(if op == "==" or op == "is" then test else "(!{test})")
                continue
            parts.append(.cmp_code(op, .ty(nodes[i]), .ty(nodes[i + 1]), codes[i], codes[i + 1]))
        if len(parts) == 1 then parts[0] else "(" + " && ".join(parts) + ")"

    fn e_Unary(e N) str
        op = e.kids[0].s
        x = e.kids[1]
        code = .ex(x)
        if op == "not" then return "(!{.truthy(code, .ty(x))})"
        if op == "-" and deep(.ty(x)).id == INT.id then return "sip_neg({code}, {e.line})"
        "({op}{code})"

    fn branch(n N, conv bool) str
        code = .ex(n)
        if conv then .to_str(code, .ty(n)) else code

    fn e_IfExpr(e N) str
        c = .cond(e.kids[0])
        conv = .an(e).stringify
        cp = .cap_start()
        a = .branch(e.kids[1], conv)
        pa = .cap_end(cp)
        cp2 = .cap_start()
        b = .branch(e.kids[2], conv)
        pb = .cap_end(cp2)
        if not pa and not pb then return "({c} ? {a} : {b})"
        t = .tmp(.ct(.rty(e)))
        .emit("if ({c}) {{")
        .depth += 1
        .replay(pa)
        .emit("{t} = {a};")
        .depth -= 1
        .emit("}} else {{")
        .depth += 1
        .replay(pb)
        .emit("{t} = {b};")
        .depth -= 1
        .emit("}}")
        t

    fn e_ListLit(e N) str
        k = .k(.rty(e))
        lst = .tmp(k, "l")
        items = e.kids[0].kids
        .emit("{lst} = {k}_new({len(items)});")
        for item in items
            .emit("{k}_push({lst}, {.ex(item)});")
        lst

    fn e_SetLit(e N) str
        st = deep(.rty(e))
        k = .k(dict_t(st.a[0], BOOL))
        .k(st)
        d = .tmp(k, "set")
        .emit("{d} = {k}_new();")
        for item in e.kids[0].kids
            .emit("{k}_set({d}, {.ex(item)}, true);")
        d

    fn e_DictLit(e N) str
        k = .k(.rty(e))
        d = .tmp(k, "d")
        .emit("{d} = {k}_new();")
        for kv in e.kids[0].kids
            codes = .eval_args([kv.kids[0], kv.kids[1]])
            .emit("{k}_set({d}, {codes[0]}, {codes[1]});")
        d

    fn comp_loops(clauses [N], i int, inner fn())
        c = clauses[i]
        .loop(.an(c).kind, c.kids[1], fn(elem str, et Ty)
            .bind(c.kids[0], elem, et)
            for cd in c.kids[2].kids
                cp = .cap_start()
                code = .cond(cd)
                pre = .cap_end(cp)
                .replay(pre)
                .emit("if (!{code}) continue;")
            if i + 1 < len(clauses)
                .comp_loops(clauses, i + 1, inner)
            else
                inner()
            pass
        )

    fn e_Comp(e N) str
        t = .rty(e)
        k = .k(t)
        res = .tmp(.ct(t), "c")
        kind = e.kids[0].s
        clauses = e.kids[3].kids
        elt = e.kids[1]
        if kind == "set"
            dk = .k(dict_t(deep(t).a[0], BOOL))
            .emit("{res} = {dk}_new();")
            .comp_loops(clauses, 0, fn() = .emit("{dk}_set({res}, {.ex(elt)}, true);"))
        elif kind == "dict"
            .emit("{res} = {k}_new();")
            .comp_loops(clauses, 0, fn() = .emit("{k}_set({res}, {', '.join(.eval_args([e.kids[2], elt]))});"))
        else
            .emit("{res} = {k}_new(0);")
            .comp_loops(clauses, 0, fn() = .emit("{k}_push({res}, {.ex(elt)});"))
        res

    # ---------- свёртки: sum, avg, min, max, any, all ----------

    # перебор элементов списка, range или генератора без промежуточного списка
    fn each(node N, inner fn(str, Ty))
        if node.kind == "Comp" and (node.kids[0].s == "gen" or node.kids[0].s == "list")
            elt = node.kids[1]
            .comp_loops(node.kids[3].kids, 0, fn()
                code = .ex(elt)
                inner(code, .ty(elt))
                pass
            )
            return
        t = .ty(node)
        kind = if t.id == RANGE.id then "range" elif t.k == "set" then "set" else "list"
        .loop(kind, node, inner)

    fn reduce(kind str, node N, res0 Ty, line int) str
        res = deep(res0)
        end = .fresh("red_end")
        if kind == "sum"
            acc = .tmp(.ct(res), "acc")
            .emit("{acc} = 0;")
            if res.id == INT.id
                # сумма единиц (подсчёт) не переполнится раньше, чем кончится цикл; без проверки
                # такой цикл векторизуется
                .each(node, fn(c str, t Ty) = .emit(if c == "0" or c == "1" then "{acc} += {c};"
                                                    else "{acc} = sip_add({acc}, {c}, {line});"))
            else
                .each(node, fn(c str, t Ty) = .emit("{acc} += {c};"))
            return acc
        if kind == "avg"
            acc = .tmp("double", "acc")
            n = .tmp("int64_t", "n")
            .emit("{acc} = 0.0; {n} = 0;")
            .each(node, fn(c str, t Ty) = .emit("{acc} += {c}; {n}++;"))
            .emit("if (SIP_UNLIKELY({n} == 0)) sip_raise(SIP_E_ValueError, SIP_LIT(\"avg() of an empty sequence\"), {line});")
            return "({acc} / (double){n})"
        if kind == "min" or kind == "max"
            acc = .tmp(.ct(res), "acc")
            has = .tmp("bool", "has")
            .emit("{has} = false;")
            op = if kind == "min" then "<" else ">"
            .each(node, fn(c str, t Ty)
                v = .spill(c, t)
                better = .cmp_code(op, t, res, v, acc)
                .emit("if (!{has} || {better}) {{ {acc} = {v}; {has} = true; }}")
                pass
            )
            .emit("if (SIP_UNLIKELY(!{has})) sip_raise(SIP_E_ValueError, SIP_LIT(\"{kind}() of an empty sequence\"), {line});")
            return acc
        acc = .tmp("bool", "acc")
        want = kind == "any"
        .emit("{acc} = {if want then 'false' else 'true'};")
        .each(node, fn(c str, t Ty)
            test = .truthy(c, t)
            .emit("if ({if want then '' else '!'}{test}) {{ {acc} = {if want then 'true' else 'false'}; goto {end}; }}")
            pass
        )
        .emit("{end}:;")
        acc

    # ---------- встроенные функции ----------

    fn args(e N) [N] = e.kids[1].kids

    fn kw(e N) {str: N}
        out: {str: N} = {}
        for p in e.kids[2].kids
            out[p.kids[0].s] = p.kids[1]
        out

    fn builtin(e N, name str) str
        a = .args(e)
        res = .rty(e)
        l = e.line
        if name == "print"
            sb = "&sip_out_line"
            for ai, xn in enumerate(a)
                if ai > 0 then .emit("sip_sb_putc({sb}, ' ');")
                interp = false
                if xn.kind == "Str"
                    for pn in xn.kids[0].kids
                        if pn.kind == "Interp" then interp = true
                if interp
                    .str_parts(xn, sb)
                else
                    .emit(fmt_call(.ty(xn), sb, .ex(xn)))
            .emit("sip_print_line();")
            return ""
        if name == "ord" then return "sip_ord({.ex(a[0])}, {l})"
        if name == "chr" then return "sip_chr({.ex(a[0])}, {l})"
        if name == "len"
            t = .ty(a[0])
            code = .ex(a[0])
            if t.id == STR.id then return "({code}).n"
            if t.k == "tuple" then return str(len(t.a))
            if t.id == RANGE.id
                r = .spill(code, t)
                return "({r}.hi >= {r}.lo ? {r}.hi - {r}.lo + 1 : 0)"
            return "({code})->n"
        if name == "str" then return .to_str(.ex(a[0]), .ty(a[0]))
        if name == "int"
            t = .ty(a[0])
            code = .ex(a[0])
            if t.id == STR.id then return .rt("parse_int", [code], l)
            return if t.id == INT.id then code else "sip_f2i({code}, {l})"
        if name == "float"
            t = .ty(a[0])
            code = .ex(a[0])
            if t.id == STR.id then return "sip_parse_float({code}, {l})"
            return "((double)({code}))"
        if name == "bool" then return .cond(a[0])
        if name == "abs"
            code = .ex(a[0])
            return if deep(.ty(a[0])).id == INT.id then "sip_iabs({code}, {l})" else "fabs({code})"
        if name == "min" or name == "max" then return .minmax(e, name)
        if name == "sum" or name == "avg" or name == "any" or name == "all" then return .reduce(name, a[0], res, l)
        if name == "sorted"
            lt = deep(res)
            k = .k(lt)
            r = .tmp(k, "s")
            code, _ = .as_list(a[0])
            .emit("{r} = {k}_copy({code});")
            .sort_list(e, r, lt)
            return r
        if name == "list"
            t = .ty(a[0])
            code, lt = .as_list(a[0])
            return if t.k == "list" then "{.k(lt)}_copy({code})" else code
        if name == "count"
            code, _ = .as_list(a[0])
            return "{.k(res)}_count({code})"
        if name == "read" then return "sip_read({.ex(a[0])}, {l})"
        if name == "write"
            codes = .eval_args(a)
            return "sip_write({codes[0]}, {codes[1]}, {l})"
        if name == "input" then return "sip_input({if a then .ex(a[0]) else 'SIP_LIT(\"\")'})"
        if name == "round"
            if len(a) == 2
                codes = .eval_args(a)
                return "sip_round_to((double)({codes[0]}), {codes[1]})"
            return "sip_round((double)({.ex(a[0])}), {l})"
        if name == "zip"
            ac, at = .as_list(a[0])
            bc, bt = .as_list(a[1])
            x = .spill(ac, at)
            y = .spill(bc, bt)
            lt = deep(res)
            k = .k(lt)
            r = .tmp(k, "z")
            i = .tmp("int64_t", "i")
            tt = .ct(lt.a[0])
            .emit("{r} = {k}_new({x}->n < {y}->n ? {x}->n : {y}->n);")
            .emit("for ({i} = 0; {i} < {x}->n && {i} < {y}->n; {i}++) {k}_push({r}, (({tt}){{{x}->d[{i}], {y}->d[{i}]}}));")
            return r
        if name == "enumerate"
            ac, at = .as_list(a[0])
            x = .spill(ac, at)
            lt = deep(res)
            k = .k(lt)
            r = .tmp(k, "en")
            i = .tmp("int64_t", "i")
            .emit("{r} = {k}_new({x}->n);")
            .emit("for ({i} = 0; {i} < {x}->n; {i}++) {k}_push({r}, (({.ct(lt.a[0])}){{{i}, {x}->d[{i}]}}));")
            return r
        if name == "set" then return .b_set(e)
        if name == "exit"
            code = if a then .ex(a[0]) else "0"
            .emit("fflush(stdout);")
            return "exit((int)({code}))"
        if name.startswith("math.") then return .b_math(e, name[5:])
        if name == "random.random" then return "sip_rand_float()"
        if name == "random.randint"
            codes = .eval_args(a)
            return "sip_rand_int({codes[0]}, {codes[1]}, {l})"
        if name == "random.uniform"
            ab = [.spill("(double)({c})", FLOAT) for c in .eval_args(a)]
            return "({ab[0]} + ({ab[1]} - {ab[0]}) * sip_rand_float())"
        if name == "random.seed" then return "sip_rand_seed((uint64_t)({.ex(a[0])}))"
        if name == "random.choice"
            lt = .ty(a[0])
            lst = .spill(.ex(a[0]), lt)
            return "{.k(lt)}_get({lst}, {lst}->n ? sip_rand_int(0, {lst}->n - 1, {l}) : (sip_raise(SIP_E_IndexError, SIP_LIT(\"cannot choose from an empty list\"), {l}), 0), {l})"
        if name == "random.shuffle"
            lt = .ty(a[0])
            lst = .spill(.ex(a[0]), lt)
            i = .tmp("int64_t", "i")
            j = .tmp("int64_t", "j")
            x = .tmp(.ct(lt.a[0]), "x")
            .emit("for ({i} = {lst}->n - 1; {i} > 0; {i}--) {{ {j} = sip_rand_int(0, {i}, 0); {x} = {lst}->d[{i}]; {lst}->d[{i}] = {lst}->d[{j}]; {lst}->d[{j}] = {x}; }}")
            return "((void)0)"
        if name == "time.time" then return "sip_time_now()"
        if name == "time.perf_counter" then return "sip_perf_counter()"
        if name == "time.sleep" then return "sip_sleep((double)({.ex(a[0])}))"
        if name == "json.parse"
            f = .json_fn("jparse", deep(res), e, name)
            return "{f}({.ex(a[0])}, {l})"
        if name == "json.read"
            f = .json_fn("jparse", deep(res), e, name)
            return "{f}(sip_read({.ex(a[0])}, {l}), {l})"
        if name == "json.stringify"
            f = .json_fn("jdump", .ty(a[0]), e, name)
            v = .spill(.ex(a[0]), .ty(a[0]))
            return "{f}({v}, {.kwarg(e, 'indent', '-1')})"
        if name == "json.write"
            p = .spill(.ex(a[0]), STR)
            f = .json_fn("jdump", .ty(a[1]), e, name)
            v = .spill(.ex(a[1]), .ty(a[1]))
            return "sip_write({p}, {f}({v}, {.kwarg(e, 'indent', '2')}), {l})"
        if name == "http.get" then return .http_call(e, "GET")
        if name == "http.post" then return .http_call(e, "POST")
        if name == "http.response_json"
            f = .json_fn("jparse", deep(res), e, name)
            return "{f}(({.ex(a[0])})->f_text, {l})"
        if name == "csv.parse"
            f = .json_fn("csvread", deep(res), e, name)
            text = .spill(.ex(a[0]), STR)
            return "{f}({text}, {.kwarg(e, 'delimiter', 'SIP_LIT(\",\")')}, {l})"
        if name == "csv.read"
            f = .json_fn("csvread", deep(res), e, name)
            text = .spill("sip_read({.ex(a[0])}, {l})", STR)
            return "{f}({text}, {.kwarg(e, 'delimiter', 'SIP_LIT(\",\")')}, {l})"
        if name == "csv.write"
            p = .spill(.ex(a[0]), STR)
            f = .json_fn("csvdump", .ty(a[1]), e, name)
            rows = .spill(.ex(a[1]), .ty(a[1]))
            return "sip_write({p}, {f}({rows}, {.kwarg(e, 'delimiter', 'SIP_LIT(\",\")')}, {l}), {l})"
        .err("unknown builtin {name}", e)
        ""

    fn b_math(e N, f str) str
        a = .args(e)
        codes = .eval_args(a)
        l = e.line
        if f == "log"
            ds = ["(double)({c})" for c in codes]
            if len(ds) == 1 then return "sip_log({ds[0]}, {l})"
            return "(sip_log({ds[0]}, {l}) / sip_log({ds[1]}, {l}))"
        xs: [str] = []
        for i, c in enumerate(codes)
            xs.append(if f != "gcd" and .ty(a[i]).id == INT.id then "(double)({c})" else c)
        if f == "sqrt" then return "sip_sqrt({xs[0]}, {l})"
        if f == "floor" or f == "ceil" or f == "trunc" then return "sip_f2i({f}({xs[0]}), {l})"
        if f == "gcd" then return "sip_gcd({xs[0]}, {xs[1]})"
        "{f}({', '.join(xs)})"

    fn json_fn(kind str, t Ty, e N, name str) str
        if kind != "jdump" and not .in_std_line(e.line)
            .emit("sip_std_line = {e.line};")  # ошибки разбора из rt.sip — на строке пользователя
        try
            if kind == "jparse" then return .reg.jparse(t)
            if kind == "jdump" then return .reg.jdump(t)
            if kind == "csvread" then return .reg.csvread(t)
            return .reg.csvdump(t)
        catch creg.JsonTypeError ex
            .err("{name}(): {ex.msg}", e)
        ""

    fn kwarg(e N, name str, default str) str
        for p in e.kids[2].kids
            if p.kids[0].s == name then return .ex(p.kids[1])
        default

    fn minmax(e N, name str) str
        a = .an(e)
        args = .args(e)
        if a.minmax_seq and a.n2 != nil then return .minmax_key(e, name)
        if a.minmax_seq then return .reduce(name, args[0], .rty(e), e.line)
        res = deep(.rty(e))
        codes = [.spill(c, .ty(args[i])) for i, c in enumerate(.eval_args(args))]
        acc = .tmp(.ct(res), "acc")
        .emit("{acc} = {codes[0]};")
        op = if name == "min" then "<" else ">"
        for i in 1..len(codes) - 1
            .emit("if ({.cmp_code(op, .ty(args[i]), res, codes[i], acc)}) {acc} = {codes[i]};")
        acc

    fn minmax_key(e N, name str) str
        res = deep(.rty(e))
        kn: N = .an(e).n2
        acc = .tmp(.ct(res), "acc")
        ft = .ty(kn)
        kt = deep(fn_ret(ft))
        best = .tmp(.ct(kt), "bk")
        has = .tmp("bool", "has")
        .emit("{has} = false;")
        f = .spill(.ex(kn), ft)
        op = if name == "min" then "<" else ">"
        .each(.args(e)[0], fn(c str, t Ty)
            v = .spill(c, t)
            kv = .spill(.call_fn(f, [v]), kt)
            better = .cmp_code(op, kt, kt, kv, best)
            .emit("if (!{has} || {better}) {{ {acc} = {v}; {best} = {kv}; {has} = true; }}")
            pass
        )
        .emit("if (SIP_UNLIKELY(!{has})) sip_raise(SIP_E_ValueError, SIP_LIT(\"{name}() of an empty sequence\"), {e.line});")
        acc

    # сортировка списка на месте; с key: ключи считаются один раз, порядок равных сохраняется
    fn sort_list(e N, lst str, lt Ty)
        k = .k(lt)
        rev = .spill(.kwarg(e, "reverse", "false"), BOOL)
        a = .an(e)
        if a.n2 == nil
            .emit("{k}_sort({lst}, {rev});")
            return
        sk: N = a.n2
        st: Ty = a.t2
        f = .spill(.ex(sk), .ty(sk))
        kt = deep(st)
        pt = tuple_t([kt, INT])
        pk = .k(list_t(pt))
        pairs = .tmp(pk, "kp")
        i = .tmp("int64_t", "i")
        buf = .tmp("{.ct(lt.a[0])} *", "buf")
        # (ключ, ±номер): при reverse номера отрицательны, и равные остаются в исходном порядке
        .emit("{pairs} = {pk}_new({lst}->n);")
        .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {pk}_push({pairs}, (({.ct(pt)}){{{.call_fn(f, [lst + '->d[' + i + ']'])}, {rev} ? -{i} : {i}}}));")
        .emit("{pk}_sort({pairs}, {rev});")
        .emit("{buf} = malloc((size_t)({lst}->n ? {lst}->n : 1) * sizeof *{buf});")
        .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {buf}[{i}] = {lst}->d[{rev} ? -{pairs}->d[{i}].f1 : {pairs}->d[{i}].f1];")
        .emit("if ({lst}->n) memcpy({lst}->d, {buf}, (size_t){lst}->n * sizeof *{buf});")
        .emit("free({buf});")

    # список из списка, range, строки, множества или словаря (ключи)
    fn as_list(node N) (str, Ty)
        t = .ty(node)
        if t.k == "list" then return (.ex(node), t)
        el = if t.id == RANGE.id then INT elif t.id == STR.id then STR else t.a[0]
        lt = list_t(el)
        k = .k(lt)
        if t.k == "set" then return ("{.k(dict_t(t.a[0], BOOL))}_keys({.ex(node)})", list_t(t.a[0]))
        if t.k == "dict" then return ("{.k(t)}_keys({.ex(node)})", lt)
        r = .tmp(k, "l")
        .emit("{r} = {k}_new(0);")
        .loop(if t.id == RANGE.id then "range" else "str", node, fn(c str, et Ty) = .emit("{k}_push({r}, {c});"))
        (r, lt)

    fn http_call(e N, method str) str
        .uses_http = true
        kw = .kw(e)
        url = .spill(.ex(.args(e)[0]), STR)
        h = .tmp("struct curl_slist *", "h")
        .emit("{h} = NULL;")
        hd = ""
        if "headers" in kw
            dt = dict_t(STR, STR)
            hd = .spill(.ex(kw["headers"]), dt)
            i = .tmp("int64_t", "i")
            .emit("for ({i} = 0; {i} < {hd}->n; {i}++) {h} = sip_http_header({h}, {hd}->e[{i}].k, {hd}->e[{i}].v);")
        body = "NULL"
        if "json" in kw
            v = kw["json"]
            f = .json_fn("jdump", .ty(v), e, .an(e).name)
            b = .tmp("sip_str", "body")
            .emit("{b} = {f}({.ex(v)}, -1);")
            has = if hd != "" then "{.k(dict_t(STR, STR))}_contains({hd}, SIP_LIT(\"Content-Type\"))" else "false"
            .emit("if (!{has}) {h} = sip_http_header({h}, SIP_LIT(\"Content-Type\"), SIP_LIT(\"application/json\"));")
            body = "&{b}"
        elif "body" in kw
            b = .tmp("sip_str", "body")
            .emit("{b} = {.ex(kw['body'])};")
            body = "&{b}"
        elif method == "POST"
            b = .tmp("sip_str", "body")
            .emit("{b} = SIP_LIT(\"\");")
            body = "&{b}"
        timeout = if "timeout" in kw then "(double)({.ex(kw['timeout'])})" else "30.0"
        wrap = .reg.http_wrap(checker.RESPONSE)
        "{wrap}(sip_http_do(\"{method}\", {url}, {body}, {h}, {timeout}, {e.line}))"

    # оператор C: target = значение литерала (поле по умолчанию) в отдельном блоке
    fn const_code(node N, target str) str
        sl = .lines
        sd = .decls
        sdp = .depth
        .lines = []
        .decls = []
        .depth = 0
        code = .ex(node)
        body = .decls + [l.t for l in .lines] + ["{target} = {code};"]
        .lines = sl
        .decls = sd
        .depth = sdp
        "{{ " + " ".join(body) + " }}"

    fn b_set(e N) str
        st = deep(.rty(e))
        dk = .k(dict_t(st.a[0], BOOL))
        .k(st)
        r = .tmp(dk, "set")
        .emit("{r} = {dk}_new();")
        a = .args(e)
        if a
            t = .ty(a[0])
            kind = if t.id == RANGE.id then "range" elif t.id == STR.id then "str" elif t.k == "set" then "set" elif t.k == "dict" then "dict_keys" else "list"
            .loop(kind, a[0], fn(c str, et Ty) = .emit("{dk}_set({r}, {c}, true);"))
        r

    # ---------- методы str, list, dict, set ----------

    fn recv(e N) N
        r: N = .an(e).n
        r

    fn recv_args(e N) [str] = .eval_args([.recv(e)] + .args(e))

    fn str_method(e N, m str) str
        c = .recv_args(e)
        if m == "lower" then return .rt("str_map", [c[0], "false"])
        if m == "upper" then return .rt("str_map", [c[0], "true"])
        if m == "strip" then return "sip_str_strip({c[0]}, 1, 1)"
        if m == "lstrip" then return "sip_str_strip({c[0]}, 1, 0)"
        if m == "rstrip" then return "sip_str_strip({c[0]}, 0, 1)"
        if m == "isdigit" then return .rt("str_all", [c[0], "0"])
        if m == "isalpha" then return .rt("str_all", [c[0], "1"])
        if m == "isspace" then return .rt("str_all", [c[0], "2"])
        if m == "isalnum" then return .rt("str_all", [c[0], "3"])
        if m == "startswith" then return "sip_str_startswith({c[0]}, {c[1]})"
        if m == "endswith" then return "sip_str_endswith({c[0]}, {c[1]})"
        if m == "find" then return "sip_str_find({c[0]}, {c[1]})"
        if m == "rfind" then return .rt("str_rfind", c)
        if m == "removeprefix" then return .rt("str_remove_affix", c + ["false"])
        if m == "removesuffix" then return .rt("str_remove_affix", c + ["true"])
        if m == "ljust" then return .rt("str_pad", c + ["0"], e.line)
        if m == "rjust" then return .rt("str_pad", c + ["1"], e.line)
        if m == "zfill" then return .rt("str_pad", c + ["2"], e.line)
        if m == "isupper" then return .rt("str_cased", [c[0], "true"])
        if m == "islower" then return .rt("str_cased", [c[0], "false"])
        if m == "capitalize" then return .rt("str_title", [c[0], "false"])
        if m == "title" then return .rt("str_title", [c[0], "true"])
        if m == "count" then return .rt("str_count", c)
        if m == "replace" then return .rt("str_replace", c)
        if m == "join" then return "{.k(.ty(.args(e)[0]))}_join({c[1]}, {c[0]})"
        if m == "split"
            s = .spill(c[0], STR)
            sep = if len(c) > 1 then .spill(c[1], STR) else ""
            return .split_into(s, sep)
        if m == "splitlines"
            s = .spill(c[0], STR)
            r = .split_into(s, "SIP_LIT(\"\\n\")")
            .k(list_t(STR))
            .emit("if ({r}->n && {r}->d[{r}->n - 1].n == 0) {r}->n--;")
            return r
        .err("unknown str method {m}", e)
        ""

    # разбиение строки на список: по пробельным символам (sep == "") или по разделителю
    fn split_into(s str, sep str) str
        k = .k(list_t(STR))
        r = .tmp(k, "sp")
        i = .tmp("int64_t", "i")
        j = .tmp("int64_t", "j")
        .emit("{r} = {k}_new(0);")
        if sep == ""
            .emit("for ({i} = 0; {i} < {s}.n;) {{")
            .emit("    while ({i} < {s}.n && sip_isspace({s}.p[{i}])) {i}++;")
            .emit("    if ({i} >= {s}.n) break;")
            .emit("    {j} = {i};")
            .emit("    while ({j} < {s}.n && !sip_isspace({s}.p[{j}])) {j}++;")
            .emit("    {k}_push({r}, ((sip_str){{{s}.p + {i}, {j} - {i}}}));")
            .emit("    {i} = {j};")
            .emit("}}")
        else
            .emit("if (SIP_UNLIKELY({sep}.n == 0)) sip_raise(SIP_E_ValueError, SIP_LIT(\"empty separator\"), 0);")
            .emit("for ({i} = 0, {j} = 0; {j} + {sep}.n <= {s}.n;) {{")
            .emit("    if (memcmp({s}.p + {j}, {sep}.p, (size_t){sep}.n) == 0) {{")
            .emit("        {k}_push({r}, ((sip_str){{{s}.p + {i}, {j} - {i}}}));")
            .emit("        {j} += {sep}.n; {i} = {j};")
            .emit("    }} else {j}++;")
            .emit("}}")
            .emit("{k}_push({r}, ((sip_str){{{s}.p + {i}, {s}.n - {i}}}));")
        r

    fn recv_fn(e N, t Ty) (str, str)
        f0 = .args(e)[0]
        codes = .eval_args([.recv(e), f0])
        (.spill(codes[0], t), .spill(codes[1], .ty(f0)))

    fn list_method(e N, t Ty, m str) str
        l = e.line
        if m == "sort"
            lst = .spill(.recv_args(e)[0], t)
            .sort_list(e, lst, t)
            return "((void)0)"
        if m == "sort_by"
            k = .k(t)
            r = .tmp(k, "s")
            .emit("{r} = {k}_copy({.ex(.recv(e))});")
            .sort_list(e, r, t)
            return r
        if m == "map"
            lst, f = .recv_fn(e, t)
            rk = .k(.rty(e))
            r = .tmp(rk, "m")
            i = .tmp("int64_t", "i")
            .emit("{r} = {rk}_new({lst}->n);")
            .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {rk}_push({r}, {.call_fn(f, [lst + '->d[' + i + ']'])});")
            return r
        if m == "filter"
            lst, f = .recv_fn(e, t)
            k = .k(t)
            r = .tmp(k, "f")
            i = .tmp("int64_t", "i")
            ft = .ty(.args(e)[0])
            .emit("{r} = {k}_new(0);")
            .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {{")
            .depth += 1
            test = .truthy(.call_fn(f, [lst + "->d[" + i + "]"]), fn_ret(ft))
            .emit("if ({test}) {k}_push({r}, {lst}->d[{i}]);")
            .depth -= 1
            .emit("}}")
            return r
        if m == "group_by"
            lst, f = .recv_fn(e, t)
            dt = deep(.rty(e))
            dk = .k(dt)
            k = .k(t)
            r = .tmp(dk, "g")
            i = .tmp("int64_t", "i")
            p = .tmp("{k} *", "p")
            .emit("{r} = {dk}_new();")
            .emit("for ({i} = 0; {i} < {lst}->n; {i}++) {{")
            .emit("    {p} = {dk}_slot({r}, {.call_fn(f, [lst + '->d[' + i + ']'])}, NULL);")
            .emit("    if (!*{p}) *{p} = {k}_new(0);")
            .emit("    {k}_push(*{p}, {lst}->d[{i}]);")
            .emit("}}")
            return r
        if m == "sum" or m == "avg" then return .reduce(m, .recv(e), .rty(e), l)
        c = .recv_args(e)
        k = .k(t)
        if m == "append" then return "{k}_push({c[0]}, {c[1]})"
        if m == "pop"
            if len(c) == 1 then return "{k}_pop({c[0]}, 0, false, {l})"
            return "{k}_pop({c[0]}, {c[1]}, true, {l})"
        if m == "insert" then return "{k}_insert({c[0]}, {c[1]}, {c[2]})"
        if m == "extend" then return "{k}_extend({c[0]}, {c[1]})"
        if m == "clear" then return "(({c[0]})->n = 0)"
        if m == "reverse" then return "{k}_reverse({c[0]})"
        if m == "copy" then return "{k}_copy({c[0]})"
        if m == "index" then return "{k}_index({c[0]}, {c[1]}, {l})"
        if m == "count"
            if len(c) == 2 then return "{k}_count({c[0]}, {c[1]})"
            return "{.k(.rty(e))}_count({c[0]})"
        if m == "first"
            lst = .spill(c[0], t)
            ot = deep(.rty(e))
            return "({lst}->n ? {.convert(lst + '->d[0]', t.a[0], ot, l)} : {nil_code(ot)})"
        if m == "join"
            sep = if len(c) > 1 then c[1] else "SIP_LIT(\"\")"
            return "{k}_join({c[0]}, {sep})"
        if m == "top"
            dk = .k(dict_t(t.a[0], INT))
            n = if len(c) > 1 then c[1] else "0"
            has = if len(c) > 1 then "true" else "false"
            return "{dk}_top({dk}_count({c[0]}), {n}, {has})"
        .err("unknown list method {m}", e)
        ""

    fn dict_method(e N, t Ty, m str) str
        l = e.line
        c = .recv_args(e)
        k = .k(t)
        if m == "pop"
            if len(c) == 2 then return "{k}_pop({c[0]}, {c[1]}, {l})"
            d = .spill(c[0], t)
            kv = .spill(c[1], t.a[0])
            r = .tmp(.ct(t.a[1]), "v")
            .emit("{r} = {c[2]};")
            .emit("if ({k}_contains({d}, {kv})) {r} = {k}_pop({d}, {kv}, {l});")
            return r
        if m == "update"
            a = .spill(c[0], t)
            b = .spill(c[1], t)
            i = .tmp("int64_t", "i")
            .emit("for ({i} = 0; {i} < {b}->n; {i}++) {k}_set({a}, {b}->e[{i}].k, {b}->e[{i}].v);")
            return "((void)0)"
        if m == "clear"
            d = .spill(c[0], t)
            return "({d}->n = 0, {k}_rehash({d}, {d}->icap ? {d}->icap : 8))"
        if m == "get"
            if len(c) == 3 then return "{k}_get_or({c[0]}, {c[1]}, {c[2]})"
            d = .spill(c[0], t)
            kv = .spill(c[1], t.a[0])
            j = .tmp("int64_t", "j")
            ot = deep(.rty(e))
            .emit("{j} = {k}_find({d}, {kv}, {hash_fn(t.a[0])}({kv}));")
            return "({j} >= 0 ? {.convert(d + '->e[' + j + '].v', t.a[1], ot, l)} : {nil_code(ot)})"
        if m == "keys" then return "{k}_keys({c[0]})"
        if m == "values" then return "{k}_values({c[0]})"
        if m == "items" then return "{k}_items({c[0]})"
        if m == "copy" then return "{k}_copy({c[0]})"
        if m == "top"
            n = if len(c) > 1 then c[1] else "0"
            has = if len(c) > 1 then "true" else "false"
            return "{k}_top({c[0]}, {n}, {has})"
        .err("unknown dict method {m}", e)
        ""

    fn set_method(e N, t Ty, m str) str
        c = .recv_args(e)
        z = ""
        k = ""
        if m == "add" or m == "discard" or m == "clear" or m == "copy" then z = .k(dict_t(t.a[0], BOOL))
        if m == "remove" or m == "update" or m == "union" or m == "intersection" or m == "difference" or m == "issubset"
            k = .k(t)
        if m == "add" then return "{z}_set({c[0]}, {c[1]}, true)"
        if m == "remove" then return "{k}_remove({c[0]}, {c[1]}, {e.line})"
        if m == "discard" then return "(void){z}_discard({c[0]}, {c[1]})"
        if m == "clear"
            d = .spill(c[0], t)
            return "({d}->n = 0, {z}_rehash({d}, {d}->icap ? {d}->icap : 8))"
        if m == "copy" then return "{z}_copy({c[0]})"
        if m == "update" then return "{k}_update({c[0]}, {c[1]})"
        if m == "union" then return "{k}_union({c[0]}, {c[1]})"
        if m == "intersection" then return "{k}_inter({c[0]}, {c[1]})"
        if m == "difference" then return "{k}_diff({c[0]}, {c[1]})"
        if m == "issubset" then return "{k}_subset({c[0]}, {c[1]})"
        .err("unknown set method {m}", e)
        ""

# ---------- сборка единиц C ----------

fn header(file str, split bool, root bool, http bool, use_async bool, runtime str) str
    parts = ["/* Generated by sip from {basename(file)}. Do not edit. */"]
    if split then parts.append("#define SIP_SPLIT 1")
    if split and root then parts.append("#define SIP_RT_IMPL 1")
    if http then parts.append("#define SIP_USE_HTTP 1")
    if use_async then parts.append("#define SIP_USE_ASYNC 1")
    parts.append(runtime)
    "\n".join(parts)

# что нужно компоновщику для extern fn: пометки // sip-lib, // sip-csrc, // sip-flag
fn native_links(c checker.Checker, ld modules.Loader) [str]
    out: [str] = []
    seen: {str} = set()
    for fi in c.fns.values()
        if not is_ext(fi.node) then continue
        lib = fi.node.kids[8].kids[0].s
        if lib == "" or lib == "sip" then continue
        mod, _ = ld.locate(fi.node.line)
        dir = path.dirname(path.abs(mod))
        line = ""
        if lib.endswith(".c")
            p = path.normalize(path.join(dir, lib))
            if not os.isfile(p)
                f, ln = ld.locate(fi.node.line)
                fail SipErr("C source '{lib}' not found (looked for {p})", f, ln, 0)
            line = "// sip-csrc: {p}"
            if p not in ld.extra then ld.extra.append(p)  # правка .c пересобирает программу
        elif lib.find("/") >= 0 or lib.endswith(".a") or lib.endswith(".so") or lib.endswith(".dylib")
            line = "// sip-lib: {path.normalize(path.join(dir, lib))}"
        else
            line = "// sip-lib: -l{lib}"
        if line not in seen
            seen.add(line)
            out.append(line)
    for pkg in ld.pkgs.values()
        for f in pkg.cflags
            line = "// sip-flag: {f}"
            if line not in seen
                seen.add(line)
                out.append(line)
    out

fn new_gen(c checker.Checker, file str, ld modules.Loader) CGen
    reg = creg.Registry(fn(n N, target str) = "")
    g = CGen(c, file, ld, reg)
    g.reg.cc = fn(n N, target str) = g.const_code(n, target)
    g

# по единице компиляции на модуль: [(имя, текст C)], первая — с main
fn generate_units(c checker.Checker, file str, ld modules.Loader, runtime str) [(str, str)]
    parts: [[str]] = []
    http = false
    use_async = false
    for i, fp in enumerate(ld.files)
        _, p = fp
        g = new_gen(c, file, ld)
        parts.append(g.unit({p}, i == 0, true))
        if g.uses_http then http = true
        if g.uses_async then use_async = true
    links = native_links(c, ld)
    units: [(str, str)] = []
    for i, fp in enumerate(ld.files)
        _, p = fp
        name = if i == 0 then path.stem(p) else "{i}_{path.stem(p)}"
        extra = if i == 0 then links else []
        units.append((name, "\n".join([header(p, true, i == 0, http, use_async, runtime)] + extra + parts[i]) + "\n"))
    units

fn where(p str, line int, col int) str
    if line == 0 then return p
    if col == 0 then return "{p}:{line}"
    "{p}:{line}:{col}"

# печатает единицы C (для сверки с siplang/cgen.py)
fn main(file str, std = "")
    sd = if std != "" then std else modules.abspath("siplang/std")
    try
        ld = modules.Loader(sd)
        body = ld.load_root(file, read(file))
        c = checker.Checker(file, sd, ld, tys=[UNIT])
        c.check(body)
        runtime = read(path.normalize(sd + "/../native/sip_rt.h"))
        out: [str] = []
        for name, text in generate_units(c, file, ld, runtime)
            out.append("=== {name} ===\n{text}")
        write("/dev/stdout", "".join(out))
    catch SipErr e
        print "{where(e.file, e.line, e.col)}: {e.msg}"
        exit(1)
