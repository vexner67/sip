"""Командная строка: sip run | build | check | c."""

import os
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
        if cmd.endswith(".sip"):
            return cmd_run(cmd, rest)
    except SipError as e:
        return _err(str(e))
    except OSError as e:
        return _err(f"{e.filename or cmd}: {e.strerror}")
    return _err(f"unknown command '{cmd}'\n{USAGE}")
