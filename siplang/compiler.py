"""Публичный API: Sip -> C -> машинный код через clang -O3."""

import hashlib
import os
import shutil
import subprocess
from pathlib import Path

from .errors import SipError

VERSION = "0.2.0"
CFLAGS = ["-O3", "-march=native", "-fwrapv", "-fno-math-errno", "-w"]


def find_cc() -> str:
    cc = os.environ.get("SIP_CC") or shutil.which("clang") or shutil.which("cc") or shutil.which("gcc")
    if not cc:
        raise SipError("C compiler not found: install clang (or set SIP_CC)", 0, 0, "sip")
    return cc


def compile_source(src: str, file: str = "<input>") -> str:
    """Sip -> текст на C. Бросает SipError с позицией в исходнике."""
    from .cgen import generate_c
    from .checker import check_program
    from .modules import load_program
    module, srcmap = load_program(file, src)
    prog = check_program(module, file, srcmap)
    return generate_c(prog, file, srcmap)


def compile_file(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return compile_source(f.read(), path)


def cc_build(c_code: str, out: str, extra: list[str] | None = None) -> None:
    out_dir = os.path.dirname(os.path.abspath(out))
    os.makedirs(out_dir, exist_ok=True)
    c_path = out + ".c"
    with open(c_path, "w", encoding="utf-8") as f:
        f.write(c_code)
    libs = ["-lcurl"] if "\n#define SIP_USE_HTTP 1\n" in c_code else []
    if "\n#define SIP_USE_ASYNC 1\n" in c_code:
        libs.append("-pthread")
    cmd = [find_cc(), *CFLAGS, *(extra or []), c_path, "-o", out, "-lm", *libs]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if os.environ.get("SIP_KEEP_C") is None:
        os.remove(c_path)
    if r.returncode != 0:
        raise SipError("C compiler failed (this is a bug in sip):\n" + r.stderr.strip()[:4000], 0, 0, "sip")


def cache_dir() -> Path:
    base = os.environ.get("SIP_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "sip")
    return Path(base)


def build_cached(path: str) -> str:
    """Собирает файл в кэш (по хэшу исходника) и возвращает путь к бинарнику."""
    with open(path, encoding="utf-8") as f:
        src = f.read()
    h = hashlib.sha256(f"{VERSION}\0{path}\0{src}".encode()).hexdigest()[:20]
    rt = (Path(__file__).parent / "native" / "sip_rt.h").read_bytes()
    gen = b"".join((Path(__file__).parent / n).read_bytes() for n in ("cgen.py", "cregistry.py", "checker.py"))
    h = hashlib.sha256(h.encode() + rt + gen).hexdigest()[:20]
    exe = cache_dir() / f"{Path(path).stem}-{h}"
    if not exe.exists():
        c_code = compile_source(src, path)
        tmp = str(exe) + f".tmp{os.getpid()}"
        cc_build(c_code, tmp)
        os.replace(tmp, exe)
    return str(exe)
