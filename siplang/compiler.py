"""Публичный API: Sip -> C -> машинный код через clang -O3.

Обычная сборка раздельная: каждый модуль — своя единица компиляции C, объектные
файлы лежат в кэше по хэшу текста, поэтому после правки одного модуля clang
пересобирает только его (и то, что изменилось из-за него). `--whole` собирает всю
программу одной единицей: clang встраивает функции между модулями, но
пересобирает всё.
"""

import hashlib
import json
import os
import shutil
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .errors import SipError

VERSION = "0.3.0"
CFLAGS = ["-O3", "-march=native", "-fwrapv", "-fno-math-errno", "-w"]


def find_cc() -> str:
    cc = os.environ.get("SIP_CC") or shutil.which("clang") or shutil.which("cc") or shutil.which("gcc")
    if not cc:
        raise SipError("C compiler not found: install clang (or set SIP_CC)", 0, 0, "sip")
    return cc


def _check(src: str, file: str):
    from .checker import check_program
    from .modules import load_program
    module, srcmap = load_program(file, src)
    return check_program(module, file, srcmap), srcmap


def compile_source(src: str, file: str = "<input>") -> str:
    """Sip -> текст на C одной единицей. Бросает SipError с позицией в исходнике."""
    from .cgen import generate_c
    prog, srcmap = _check(src, file)
    return generate_c(prog, file, srcmap)


def compile_units(src: str, file: str = "<input>"):
    """Sip -> [(имя, текст C)] по единице на модуль и список файлов программы."""
    from .cgen import generate_units
    prog, srcmap = _check(src, file)
    return generate_units(prog, file, srcmap), srcmap.sources()


def compile_file(path: str) -> str:
    with open(path, encoding="utf-8") as f:
        return compile_source(f.read(), path)


def _libs(c_code: str) -> list:
    libs = ["-lcurl"] if "\n#define SIP_USE_HTTP 1\n" in c_code else []
    if "\n#define SIP_USE_ASYNC 1\n" in c_code:
        libs.append("-pthread")
    return libs


def _cc(cmd: list) -> None:
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SipError("C compiler failed (this is a bug in sip):\n" + r.stderr.strip()[:4000], 0, 0, "sip")


def cc_build(c_code: str, out: str, extra: list[str] | None = None) -> None:
    """Одна единица C -> исполняемый файл."""
    out_dir = os.path.dirname(os.path.abspath(out))
    os.makedirs(out_dir, exist_ok=True)
    c_path = out + ".c"
    with open(c_path, "w", encoding="utf-8") as f:
        f.write(c_code)
    try:
        _cc([find_cc(), *CFLAGS, *(extra or []), c_path, "-o", out, "-lm", *_libs(c_code)])
    finally:
        if os.environ.get("SIP_KEEP_C") is None:
            os.remove(c_path)


def cc_build_units(units: list, out: str, extra: list[str] | None = None) -> dict:
    """Единицы C -> объектные файлы (из кэша, если текст не менялся) -> исполняемый файл.

    Возвращает {"compiled": n, "cached": m}.
    """
    cc = find_cc()
    flags = [*CFLAGS, *(extra or [])]
    obj_dir = cache_dir() / "obj"
    obj_dir.mkdir(parents=True, exist_ok=True)
    jobs, objs = [], []
    for name, code in units:
        h = hashlib.sha256("\0".join([VERSION, cc, *flags, code]).encode()).hexdigest()[:24]
        obj = obj_dir / f"{name}-{h}.o"
        objs.append(str(obj))
        if not obj.exists():
            jobs.append((name, code, obj))

    def build(job):
        name, code, obj = job
        tmp = f"{obj}.tmp{os.getpid()}"
        c_path = tmp + ".c"
        with open(c_path, "w", encoding="utf-8") as f:
            f.write(code)
        try:
            _cc([cc, *flags, "-c", c_path, "-o", tmp])
            os.replace(tmp, obj)
        finally:
            if os.environ.get("SIP_KEEP_C") is None and os.path.exists(c_path):
                os.remove(c_path)

    if jobs:
        with ThreadPoolExecutor(max_workers=min(len(jobs), os.cpu_count() or 4)) as ex:
            list(ex.map(build, jobs))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    _cc([cc, *flags, *objs, "-o", out, "-lm", *_libs(units[0][1])])
    return {"compiled": len(jobs), "cached": len(units) - len(jobs)}


def cache_dir() -> Path:
    base = os.environ.get("SIP_CACHE") or os.path.join(
        os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "sip")
    return Path(base)


def _digest(paths) -> dict:
    out = {}
    for p in paths:
        try:
            out[p] = hashlib.sha256(Path(p).read_bytes()).hexdigest()
        except OSError:
            out[p] = None
    return out


def _tool_hash() -> str:
    here = Path(__file__).parent
    data = [(here / "native" / "sip_rt.h").read_bytes()]
    data += [(here / n).read_bytes() for n in sorted(os.listdir(here)) if n.endswith(".py")]
    return hashlib.sha256(VERSION.encode() + b"".join(data)).hexdigest()[:16]


def build_cached(path: str) -> str:
    """Собирает программу в кэш и возвращает путь к бинарнику.

    Манифест помнит все файлы программы (модули, sip.toml пакетов) и их хэши:
    если ни один не изменился, бинарник берётся из кэша без проверки типов.
    """
    root = os.path.abspath(path)
    tool = _tool_hash()
    key = hashlib.sha256(f"{tool}\0{root}".encode()).hexdigest()[:20]
    runs = cache_dir() / "runs"
    manifest = runs / f"{key}.json"
    try:
        m = json.loads(manifest.read_text())
        if os.path.exists(m["exe"]) and _digest(m["files"]) == m["files"]:
            return m["exe"]
    except (OSError, ValueError, KeyError, TypeError):
        pass
    with open(path, encoding="utf-8") as f:
        src = f.read()
    units, files = compile_units(src, path)
    h = hashlib.sha256("\0".join(code for _, code in units).encode()).hexdigest()[:20]
    exe = cache_dir() / f"{Path(path).stem}-{h}"
    if not exe.exists():
        tmp = str(exe) + f".tmp{os.getpid()}"
        cc_build_units(units, tmp)
        os.replace(tmp, exe)
    runs.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({"exe": str(exe), "files": _digest(files)}))
    return str(exe)
