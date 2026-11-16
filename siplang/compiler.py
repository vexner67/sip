"""Публичный API: компиляция Sip в Python и запуск."""

import builtins
import linecache
import os
import sys
from dataclasses import dataclass

from .codegen import generate
from .errors import SipError
from .lexer import tokenize
from .parser import Parser

# Имена исключений Sip, которые в Python называются иначе
ERROR_NAMES = {"FileNotFoundError": "NotFound", "JSONDecodeError": "ParseError"}


@dataclass
class Compiled:
    file: str
    python: str
    linemap: list[int]  # строка Python (с 0) -> строка Sip

    def sip_line(self, py_line: int) -> int:
        if 1 <= py_line <= len(self.linemap):
            return self.linemap[py_line - 1]
        return 0


def compile_source(src: str, file: str = "<input>") -> Compiled:
    """Sip -> Python. Бросает SipError с позицией в исходнике."""
    module = Parser(tokenize(src, file), file).parse_module()
    python, linemap = generate(module, file)
    compiled = Compiled(file, python, linemap)
    # Python тоже проверяет код (например, await вне async fn)
    try:
        compile(python, file, "exec")
    except SyntaxError as e:
        raise SipError(e.msg, compiled.sip_line(e.lineno or 0), 0, file) from None
    return compiled


def compile_file(path: str) -> Compiled:
    with open(path, encoding="utf-8") as f:
        return compile_source(f.read(), path)


def _code_name(compiled: Compiled) -> str:
    return f"<sip {compiled.file}>"


def execute(compiled: Compiled, argv: list[str] | None = None, name: str = "__main__") -> dict:
    """Выполняет скомпилированную программу и возвращает её глобальные имена."""
    code_name = _code_name(compiled)
    lines = compiled.python.splitlines(keepends=True)
    linecache.cache[code_name] = (len(compiled.python), None, lines, code_name)
    code = compile(compiled.python, code_name, "exec")
    path = os.path.abspath(compiled.file)
    env = {"__name__": name, "__file__": path, "__builtins__": builtins}
    saved_argv = sys.argv
    sys.argv = [compiled.file] + list(argv or [])
    sys.path.insert(0, os.path.dirname(path))
    try:
        exec(code, env)
    finally:
        sys.argv = saved_argv
        sys.path.remove(os.path.dirname(path))
    return env


def format_runtime_error(exc: BaseException, compiled: Compiled) -> str:
    """Коротко: `файл:строка: Тип: сообщение` и строка исходника.

    Берётся самый глубокий кадр из .sip-файла, то есть место, где упал код
    пользователя, а не внутренности рантайма.
    """
    code_name = _code_name(compiled)
    line = 0
    tb = exc.__traceback__
    while tb is not None:
        if tb.tb_frame.f_code.co_filename == code_name:
            line = compiled.sip_line(tb.tb_lineno)
        tb = tb.tb_next
    kind = ERROR_NAMES.get(type(exc).__name__, type(exc).__name__)
    msg = str(exc)
    head = f"{compiled.file}:{line}: {kind}" + (f": {msg}" if msg else "")
    source = ""
    if line:
        try:
            with open(compiled.file, encoding="utf-8") as f:
                source = f.read().splitlines()[line - 1].strip()
        except (OSError, IndexError):
            pass
    return head + (f"\n    {source}" if source else "")
