# Компилятор Sip без Python: проверка типов, генерация C и вызов clang (перенос siplang/compiler.py).
#
#   sipc build FILE.sip [-o OUT]   исполняемый файл; единицы C модулей берутся из кэша, если не менялись
#   sipc run FILE.sip [ARGS...]    собирает в кэш (~/.cache/sip) и запускает
#   sipc c FILE.sip                печатает сгенерированный C
#   sipc native FILE.sip [-o OUT]  исполняемый файл arm64 без C и clang (пока подмножество языка, см. ngen.sip)
#
# Стандартная библиотека и рантайм ищутся в --std, $SIP_STD или в siplang/std в текущей папке, папке
# исходника или их родителях.

import os
import path
import modules
import checker
import cgen
import ngen
from modules import SipErr
from checker import UNIT

VERSION = "0.5.0"
CFLAGS = ["-O3", "-march=native", "-fwrapv", "-fno-math-errno", "-w"]

# ---------- мелочи ----------

# FNV-1a (32 бита) + CRC-32: ключ кэша из 16 шестнадцатеричных цифр
fn fnv(s str) int
    h = 2166136261
    for i in 0..len(s) - 1
        h = ((h ^ ord(s[i])) * 16777619) & 4294967295
    h

fn digest(s str) str = "{fnv(s):08x}{cgen.crc32(s):08x}"

# аргумент для sh: в одинарных кавычках
fn q(s str) str = "'" + s.replace("'", "'\\''") + "'"

fn cache_dir() str
    base = os.env("SIP_CACHE")
    if base != nil then return base
    xdg: str = os.env("XDG_CACHE_HOME") or ""
    if xdg != "" then return path.join(xdg, "sip")
    home: str = os.env("HOME") or "/tmp"
    path.join(home, ".cache", "sip")

fn find_cc() str
    cc = os.env("SIP_CC")
    if cc != nil then return cc
    for name in ["clang", "cc", "gcc"]
        got = os.output("command -v {name} 2>/dev/null").strip()
        if got != "" then return got
    fail SipErr("C compiler not found: install clang (or set SIP_CC)", "sip", 0, 0)

fn find_std(given str, file str) str
    if given != "" then return path.abs(given)
    env: str = os.env("SIP_STD") or ""
    if env != "" then return path.abs(env)
    for start in [os.cwd(), path.dirname(path.abs(file))]
        d = start
        while true
            cand = path.join(d, "siplang", "std")
            if os.isdir(cand) then return cand
            if d == "/" or d == "" then break
            d = path.dirname(d)
    fail SipErr("standard library not found: pass --std DIR or set SIP_STD", "sip", 0, 0)

# строки-пометки генератора: // sip-lib: ..., // sip-csrc: ..., // sip-flag: ...
fn marks(code str, what str) [str]
    out: [str] = []
    pre = "// sip-{what}: "
    for line in code.split("\n")
        if line.startswith(pre) then out.append(line[len(pre):])
    out

fn libs(code str) [str]
    out = marks(code, "flag") + marks(code, "lib")
    if "\n#define SIP_USE_HTTP 1\n" in code then out.append("-lcurl")
    if "\n#define SIP_USE_ASYNC 1\n" in code then out.append("-pthread")
    out

fn cmdline(args [str]) str = " ".join([q(a) for a in args])

fn c_quote(s str) str = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

# ---------- Sip -> C ----------

fn compile_units(file str, std str) [(str, str)]
    ld = modules.Loader(std)
    body = ld.load_root(file, read(file))
    c = checker.Checker(file, std, ld, tys=[UNIT])
    c.check(body)
    runtime = read(path.normalize(std + "/../native/sip_rt.h"))
    cgen.generate_units(c, file, ld, runtime)

fn build_native(file str, std str, out str)
    ld = modules.Loader(std)
    body = ld.load_root(file, read(file))
    c = checker.Checker(file, std, ld, tys=[UNIT])
    c.check(body)
    ngen.build(c, ld, file, out)

# ---------- C -> исполняемый файл ----------

type Job(name str, code str, obj str, flags [str], user bool)

# единицы C -> объектные файлы (из кэша, если текст не менялся) -> исполняемый файл; [собрано, из кэша]
fn build_units(units [(str, str)], out str) [int]
    cc = find_cc()
    objdir = path.join(cache_dir(), "obj")
    os.mkdir(objdir, true)
    root = units[0][1]
    jobs: [Job] = []
    objs: [str] = []
    for name, code in units
        jobs.append(Job(name, code, "", CFLAGS, false))
    for src in marks(root, "csrc")
        if not os.isfile(src) then fail SipErr("{src}: No such file or directory", "sip", 0, 0)
        # #line: ошибки clang указывают на сам файл пользователя
        jobs.append(Job(path.stem(src) + "_c", "#line 1 {c_quote(src)}\n{read(src)}", "", CFLAGS + marks(root, "flag"), true))
    todo: [Job] = []
    for j in jobs
        h = digest("\n".join([VERSION, cc] + j.flags + [j.code]))
        j.obj = path.join(objdir, "{j.name}-{h}.o")
        objs.append(j.obj)
        if not os.exists(j.obj) then todo.append(j)
    if todo
        tag = "tmp{os.pid()}"
        script: [str] = []
        for j in todo
            write(j.obj + ".{tag}.c", j.code)
            tmp = j.obj + ".{tag}"
            script.append("( {cmdline([cc] + j.flags + ['-c', tmp + '.c', '-o', tmp])} 2> {q(tmp + '.err')} && mv {q(tmp)} {q(j.obj)} ) &")
        script.append("wait")
        sh = path.join(objdir, "build.{tag}.sh")
        write(sh, "\n".join(script) + "\n")
        os.run("sh {q(sh)}")
        os.remove(sh)
        keep = os.env("SIP_KEEP_C") != nil
        failed = ""
        user = false
        for j in todo
            tmp = j.obj + ".{tag}"
            if not os.exists(j.obj) and failed == ""
                failed = read(tmp + ".err").strip()
                user = j.user
            if not keep then os.remove(tmp + ".c")
            if os.exists(tmp + ".err") then os.remove(tmp + ".err")
        if failed != ""
            what = "C compiler failed" + (if user then "" else " (this is a bug in sip)")
            fail SipErr(what + ":\n" + failed[:4000], "sip", 0, 0)
    d = path.dirname(path.abs(out))
    os.mkdir(d, true)
    err = out + ".link.err"
    user = len(marks(root, "lib")) + len(marks(root, "csrc")) > 0
    status = os.run("{cmdline([cc] + CFLAGS + objs + ['-o', out, '-lm'] + libs(root))} 2> {q(err)}")
    text = if os.exists(err) then read(err).strip() else ""
    if os.exists(err) then os.remove(err)
    if status != 0
        what = "C compiler failed" + (if user then "" else " (this is a bug in sip)")
        fail SipErr(what + ":\n" + text[:4000], "sip", 0, 0)
    [len(todo), len(jobs) - len(todo)]

# собирает в кэш и возвращает путь к бинарнику (имя — по хэшу всего C)
fn build_cached(file str, std str) str
    units = compile_units(file, std)
    h = digest("\n".join([VERSION] + [code for _, code in units]))
    exe = path.join(cache_dir(), "{path.stem(file)}-{h}")
    if not os.exists(exe)
        tmp = exe + ".tmp{os.pid()}"
        build_units(units, tmp)
        os.rename(tmp, exe)
    exe

fn where(p str, line int, col int) str
    if line == 0 then return p
    if col == 0 then return "{p}:{line}"
    "{p}:{line}:{col}"

fn usage()
    print "usage: sipc build FILE.sip [-o OUT] | sipc run FILE.sip [ARGS...] | sipc c FILE.sip | sipc native FILE.sip [-o OUT]  [--std DIR]"
    exit(2)

fn main(cmd str, *rest str, std = "")
    if not rest then usage()
    file = rest[0]
    try
        sd = find_std(std, file)
        if cmd == "c"
            out: [str] = []
            for name, text in compile_units(file, sd)
                out.append("// ---- {name}.c ----\n{text}")
            write("/dev/stdout", "".join(out))
        elif cmd == "build" or cmd == "native"
            dst = path.stem(file)
            i = 1
            while i < len(rest)
                if rest[i] == "-o" and i + 1 < len(rest)
                    dst = rest[i + 1]
                    i += 2
                else
                    fail SipErr("unexpected argument: {rest[i]}", "sip", 0, 0)
            if cmd == "native"
                build_native(file, sd, dst)
                print dst
                return
            units = compile_units(file, sd)
            got = build_units(units, dst)
            print "{len(units)} unit(s): {got[0]} compiled, {got[1]} cached"
            print dst
        elif cmd == "run"
            exe = build_cached(file, sd)
            exit(os.run(cmdline([exe] + rest[1:])))
        else
            usage()
    catch SipErr e
        print "{where(e.file, e.line, e.col)}: {e.msg}"
        exit(1)
