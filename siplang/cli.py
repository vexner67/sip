"""Командная строка: sip run | build | check | c."""

import os
import sys

from .compiler import build_cached, cc_build, compile_file
from .errors import SipError

USAGE = """\
usage:
  sip run FILE.sip [args...]   compile (cached) and run (also: sip FILE.sip)
  sip build FILE.sip [-o OUT]  build a native executable
  sip check FILE.sip...        check syntax and types only
  sip c FILE.sip [-o OUT.c]    print the generated C

Env: SIP_CC (C compiler, default clang), SIP_CACHE (build cache dir)."""


def _err(msg: str) -> int:
    print(msg, file=sys.stderr)
    return 1


def _out_arg(args: list[str]):
    out, files = None, []
    it = iter(args)
    for a in it:
        if a in ("-o", "--out"):
            out = next(it, None)
            if out is None:
                raise SipError("-o needs a file name", 0, 0, "sip")
        else:
            files.append(a)
    if len(files) != 1:
        raise SipError("expected exactly one .sip file", 0, 0, "sip")
    return files[0], out


def cmd_run(path: str, args: list[str]) -> int:
    exe = build_cached(path)
    sys.stdout.flush()
    os.execv(exe, [os.path.splitext(os.path.basename(path))[0], *args])


def cmd_build(args: list[str]) -> int:
    path, out = _out_arg(args)
    out = out or os.path.splitext(path)[0]
    cc_build(compile_file(path), out)
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
    from .lexer import tokenize
    from .parser import Parser
    failed = 0
    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                src = f.read()
            check_program(Parser(tokenize(src, path), path).parse_module(), path)
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
            if not rest:
                return _err("run needs a file")
            return cmd_run(rest[0], rest[1:])
        if cmd == "build":
            return cmd_build(rest)
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
