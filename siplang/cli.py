"""Командная строка: sip run | build | check | c."""

import os
import re
import sys

from .compiler import build_cached, cc_build, cc_build_units, compile_file, compile_units
from .errors import SipError

USAGE = """\
usage:
  sip init NAME                create a package: NAME/sip.toml and NAME/main.sip
  sip run [FILE.sip] [args...] compile (cached) and run (also: sip FILE.sip);
                               without FILE: main.sip of the package (sip.toml) here
  sip build FILE.sip [-o OUT] [--whole]
                               build a native executable; each module is a separate
                               C unit cached by content (--whole: one unit, cross-module
                               inlining, full rebuild)
  sip check FILE.sip...        check syntax and types only
  sip test [PATH...] [-k TEXT] [-v]
                               run `test "name"` blocks of each file (default: the
                               package here, or this folder); -k: only names containing TEXT
  sip fmt [PATH...] [--check]  format files in place (--check: list unformatted, exit 1)
  sip lsp                      language server over stdio (diagnostics, hover,
                               go to definition, completion, formatting)
  sip c FILE.sip [-o OUT.c]    print the generated C

Env: SIP_CC (C compiler, default clang), SIP_CACHE (build cache dir)."""


def _err(msg: str) -> int:
    print(msg, file=sys.stderr)
    return 1


def _out_arg(args: list[str], flags=()):
    out, files = None, []
    it = iter(args)
    for a in it:
        if a in flags:
            continue
        if a in ("-o", "--out"):
            out = next(it, None)
            if out is None:
                raise SipError("-o needs a file name", 0, 0, "sip")
        else:
            files.append(a)
    if len(files) != 1:
        raise SipError("expected exactly one .sip file", 0, 0, "sip")
    return files[0], out


def package_main() -> str:
    """main.sip пакета, в папке которого (или ниже) запущен sip."""
    from .modules import find_package
    pkg = find_package(os.getcwd())
    if pkg is None:
        raise SipError("no .sip file given and no sip.toml here or above (create one: sip init NAME)", 0, 0, "sip")
    main = os.path.join(pkg.root, "main.sip")
    if not os.path.isfile(main):
        raise SipError(f"package '{pkg.name}' has no main.sip", 0, 0, pkg.toml)
    return main


def cmd_init(args: list[str]) -> int:
    if len(args) != 1:
        return _err("usage: sip init NAME")
    name = args[0]
    from .modules import NAME_RE
    pkg = os.path.basename(os.path.abspath(name))
    if not NAME_RE.match(pkg):
        return _err(f"package name '{pkg}' must be a valid identifier (letters, digits, _)")
    if os.path.exists(os.path.join(name, "sip.toml")):
        return _err(f"{name}/sip.toml already exists")
    os.makedirs(name, exist_ok=True)
    with open(os.path.join(name, "sip.toml"), "w", encoding="utf-8") as f:
        f.write(f'[package]\nname = "{pkg}"\n\n[deps]\n'
                '# util = { path = "../util" }\n'
                '# colors = { git = "https://github.com/user/colors.git", rev = "v1.0.0" }\n')
    main = os.path.join(name, "main.sip")
    if not os.path.exists(main):
        with open(main, "w", encoding="utf-8") as f:
            f.write('fn main(name = "world")\n    print "Hello, {name}!"\n')
    print(f"created {name}/sip.toml and {name}/main.sip; run: cd {name} && sip run")
    return 0


def cmd_run(path: str, args: list[str]) -> int:
    exe = build_cached(path)
    sys.stdout.flush()
    os.execv(exe, [os.path.splitext(os.path.basename(path))[0], *args])


def cmd_build(args: list[str]) -> int:
    path, out = _out_arg(args, ("--whole",))
    out = out or os.path.splitext(path)[0]
    if "--whole" in args:
        cc_build(compile_file(path), out)
    else:
        with open(path, encoding="utf-8") as f:
            units, _ = compile_units(f.read(), path)
        st = cc_build_units(units, out)
        print(f"{len(units)} unit(s): {st['compiled']} compiled, {st['cached']} cached", file=sys.stderr)
    print(out)
    return 0


def cmd_c(args: list[str]) -> int:
    path, out = _out_arg(args)
    code = compile_file(path)
    if out:
        with open(out, "w", encoding="utf-8") as f:
            f.write(code)
    else:
        sys.stdout.write(code)
    return 0


def cmd_check(paths: list[str]) -> int:
    if not paths:
        return _err("check needs at least one file")
    from .checker import check_program
    from .modules import load_program
    failed = 0
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                src = f.read()
            module, srcmap = load_program(path, src)
            check_program(module, path, srcmap)
        except SipError as e:
            print(e, file=sys.stderr)
            failed += 1
        except OSError as e:
            print(f"{path}: {e.strerror}", file=sys.stderr)
            failed += 1
    if not failed:
        print(f"ok: {len(paths)} file(s)")
    return 1 if failed else 0


TEST_RE = re.compile(r"^test\s+[\"']", re.M)


def sip_files(paths: list[str]) -> list[str]:
    """Файлы .sip: сами файлы и всё в папках (кроме скрытых)."""
    out = []
    for p in paths:
        if os.path.isdir(p):
            for d, dirs, files in os.walk(p):
                dirs[:] = sorted(x for x in dirs if not x.startswith("."))
                out += [os.path.normpath(os.path.join(d, f)) for f in sorted(files) if f.endswith(".sip")]
        else:
            out.append(p)
    return out


def default_root() -> str:
    from .modules import find_package
    pkg = find_package(os.getcwd())
    return pkg.root if pkg is not None else "."


def cmd_test(args: list[str]) -> int:
    import subprocess
    paths, extra = [], []
    it = iter(args)
    for a in it:
        if a == "-k":
            k = next(it, None)
            if k is None:
                return _err("-k needs a text")
            extra.append(k)
        elif a == "-v":
            extra.append("-v")
        else:
            paths.append(a)
    files = []
    for f in sip_files(paths or [default_root()]):
        try:
            with open(f, encoding="utf-8") as fh:
                if TEST_RE.search(fh.read()):
                    files.append(f)
        except OSError as e:
            return _err(f"{f}: {e.strerror}")
    if not files:
        return _err("no tests found (write: test \"name\" and an indented block)")
    failed = 0
    for f in files:
        name = os.path.relpath(f)
        try:
            exe = build_cached(f, tests=True)
        except SipError as e:
            print(e, file=sys.stderr)
            failed += 1
            continue
        sys.stdout.flush()
        r = subprocess.run([name, *extra], executable=exe)
        failed += r.returncode != 0
    if len(files) > 1:
        print(f"{len(files) - failed} of {len(files)} files passed" if failed else f"all {len(files)} files passed")
    return 1 if failed else 0


def cmd_fmt(args: list[str]) -> int:
    from .fmt import format_source
    check = "--check" in args
    paths = [a for a in args if a != "--check"]
    bad = 0
    for f in sip_files(paths or [default_root()]):
        try:
            with open(f, encoding="utf-8") as fh:
                src = fh.read()
            out = format_source(src, f)
        except SipError as e:
            print(e, file=sys.stderr)
            bad += 1
            continue
        if out == src:
            continue
        if check:
            print(f"{f}: not formatted")
            bad += 1
        else:
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(out)
            print(f"formatted {f}")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(USAGE)
        return 0
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "run":
            if not rest or not rest[0].endswith(".sip"):
                return cmd_run(package_main(), rest)
            return cmd_run(rest[0], rest[1:])
        if cmd == "build":
            if not any(a.endswith(".sip") for a in rest):
                rest = [package_main(), *rest]
            return cmd_build(rest)
        if cmd == "init":
            return cmd_init(rest)
        if cmd == "c":
            return cmd_c(rest)
        if cmd == "check":
            return cmd_check(rest)
        if cmd == "test":
            return cmd_test(rest)
        if cmd == "fmt":
            return cmd_fmt(rest)
        if cmd == "lsp":
            from .lsp import serve
            return serve()
        if cmd.endswith(".sip"):
            return cmd_run(cmd, rest)
    except SipError as e:
        return _err(str(e))
    except OSError as e:
        return _err(f"{e.filename or cmd}: {e.strerror}")
    return _err(f"unknown command '{cmd}'\n{USAGE}")
