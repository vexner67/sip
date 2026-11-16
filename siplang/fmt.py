"""sip fmt: один стиль для всего кода.

Форматтер работает с токенами настоящего лексера, а не с деревом, поэтому
сохраняет комментарии и пустые строки и никогда не переставляет код:

- отступ блока — 4 пробела на уровень; строки-продолжения внутри скобок сдвигаются
  вместе с началом инструкции;
- пробелы вокруг бинарных операторов и `=`, после `,` и `:`, нет пробелов внутри
  скобок, вокруг `.` и `..`, в срезах `xs[1:n]`;
- не больше двух пустых строк подряд на верхнем уровне и одной внутри блока;
- без пробелов в конце строк, один перевод строки в конце файла.

Там, где пробел меняет смысл (`print -x` против `a - x`, `print .x`), пробел
остаётся как был. После форматирования поток токенов сравнивается с исходным:
если он изменился, файл не трогается.
"""

from __future__ import annotations

from .errors import SipError
from .lexer import tokenize

STRUCT = {"NEWLINE", "INDENT", "DEDENT", "EOF"}
OPERAND = {"NAME", "NUMBER", "STRING", ")", "]", "}", "true", "false", "nil", "?"}
SPACED = {"==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "->", "<", ">", "|", "&", "^",
          "//", "/", "%", "**"}
AMBIG = {"+", "-", "*"}  # бывают унарными: -x, *args
OPEN, CLOSE = "([{", ")]}"


def tok_text(t, line: str) -> str:
    if t.kind == "STRING":
        return line[t.col - 1:t.col + 1 + len(t.value[1])]
    return str(t.value)


def _structure(toks):
    return [(t.kind, t.value) for t in toks]


class _Line:
    def __init__(self, ln, toks, level, start):
        self.ln = ln
        self.toks = toks
        self.level = level      # число открытых блоков (INDENT) у первого токена
        self.start = start      # начинает инструкцию (а не продолжает скобку)
        self.orig = 0
        self.new = 0


def format_source(src: str, file: str = "<input>") -> str:
    toks = tokenize(src, file)
    lines = src.splitlines()

    # токены по строкам, уровень блока и начало инструкции
    by_line: dict[int, _Line] = {}
    level = 0
    prev_kind = "NEWLINE"
    for t in toks:
        if t.kind == "INDENT":
            level += 1
        elif t.kind == "DEDENT":
            level -= 1
        if t.kind in STRUCT:
            prev_kind = t.kind
            continue
        ln = by_line.get(t.line)
        if ln is None:
            ln = by_line[t.line] = _Line(t.line, [], level, prev_kind in ("NEWLINE", "INDENT", "DEDENT"))
        ln.toks.append(t)
        prev_kind = t.kind

    out: list[str] = []
    blank = 0
    delta = 0                # сдвиг последней строки-начала инструкции
    stack: list = []         # открытые скобки: (символ, это параметры типа?)
    base = 0
    code_lines = sorted(by_line)
    pending_comments: list = []  # (индекс в out, исходный отступ) комментариев без кода

    def flush_comments(next_line: _Line | None, prev_line: _Line | None):
        for idx, ind in pending_comments:
            if next_line is not None and ind == next_line.orig:
                new = next_line.new
            elif prev_line is not None and ind == prev_line.orig:
                new = prev_line.new
            elif next_line is not None:
                new = max(0, ind + next_line.new - next_line.orig)
            else:
                new = max(0, ind + delta)
            out[idx] = " " * new + out[idx].lstrip()
        pending_comments.clear()

    prev_code: _Line | None = None
    for i, text in enumerate(lines, 1):
        stripped = text.strip()
        info = by_line.get(i)
        if info is None:
            if not stripped:
                blank += 1
                continue
            if stripped.startswith("#"):
                if out:
                    limit = 2 if (prev_code is None or prev_code.level == 0) else 1
                    out.extend([""] * min(blank, limit))
                blank = 0
                pending_comments.append((len(out), len(text) - len(text.lstrip(" "))))
                out.append(stripped)
                continue
            out.append(text.rstrip())  # не бывает: строка без токенов и без комментария
            continue
        info.orig = len(text) - len(text.lstrip(" "))
        if info.start:
            info.new = 4 * info.level
            delta = info.new - info.orig
            base = len(stack)  # скобки, открытые до инструкции (тело лямбды внутри вызова)
        else:
            info.new = max(0, info.orig + delta)
        if out and blank:
            limit = 2 if info.level == 0 and info.start and not stack else 1
            out.extend([""] * min(blank, limit))
        blank = 0
        flush_comments(info, prev_code)
        body = _format_tokens(info.toks, text, stack, base)
        last = info.toks[-1]
        end = last.col - 1 + len(tok_text(last, text))
        rest = text[end:]
        if rest.strip().startswith("#"):
            comment = rest.strip()
            gap = len(rest) - len(rest.lstrip())
            col = info.new + len(body)
            want = end + gap + delta  # выровненный комментарий остаётся выровненным
            body += " " * (want - col if gap >= 4 and want - col >= 2 else 2) + comment
        out.append(" " * info.new + body)
        prev_code = info
    flush_comments(None, prev_code)
    while out and not out[-1].strip():
        out.pop()
    while out and not out[0].strip():
        out.pop(0)
    result = "\n".join(out) + "\n" if out else ""
    try:
        same = _structure(tokenize(result, file)) == _structure(toks)
    except SipError:
        same = False
    if not same:
        raise SipError("sip fmt would change the meaning of this file (a bug in sip fmt); left it as is",
                       0, 0, file)
    return result


def _format_tokens(toks, text: str, stack: list, base: int) -> str:
    parts: list[str] = []
    prev = None
    prev2 = None
    prev_unary = False
    for idx, t in enumerate(toks):
        s = tok_text(t, text)
        nxt = toks[idx + 1] if idx + 1 < len(toks) else None
        if prev is None:
            parts.append(s)
        else:
            pend = prev.col - 1 + len(tok_text(prev, text))
            gap_before = t.col - 1 > pend
            sp = _space(prev, t, nxt, gap_before, text, stack, prev2, prev_unary, base)
            parts.append((" " if sp else "") + s)
        # унарный ли этот оператор (для пробела после него)
        unary = False
        if t.kind in AMBIG:
            unary = _is_unary(prev, t, nxt, text)
        if t.kind in OPEN:
            tparams = t.kind == "[" and prev is not None and prev.kind == "NAME" and prev2 is not None and (
                prev2.kind == "fn" or (prev2.kind == "NAME" and prev2.value in ("type", "interface")))
            stack.append((t.kind, tparams))
        elif t.kind in CLOSE and stack:
            stack.pop()
        prev2, prev, prev_unary = prev, t, unary
    return "".join(parts)


def _gap_after(t, nxt, text) -> bool:
    if nxt is None or nxt.line != t.line:
        return True
    return nxt.col - 1 > t.col - 1 + len(tok_text(t, text))


def _is_unary(prev, t, nxt, text) -> bool:
    if prev is None or prev.kind not in OPERAND:
        return True
    pend = prev.col - 1 + len(tok_text(prev, text))
    gap_before = t.col - 1 > pend
    # `print -x`, `f *args`: пробел перед и нет после — оставляем как написано
    return gap_before and not _gap_after(t, nxt, text)


def _space(prev, t, nxt, gap: bool, text: str, stack: list, prev2, prev_unary: bool, base: int) -> bool:
    k, pk = t.kind, prev.kind
    inner = stack[-1] if stack else None
    slice_ = inner is not None and inner[0] == "[" and not inner[1]
    # после
    if pk in OPEN or pk == "@":
        return False
    if pk == ".":
        return False
    if pk == "..":
        return False
    if pk in AMBIG:
        return not prev_unary  # a * -1, но -x
    if pk == ",":
        return k not in CLOSE
    if pk == ":":
        return not slice_
    # перед
    if k in CLOSE or k in (",", "?"):
        return False
    if k == ":":
        return False
    if k == "..":
        return False
    if k == ".":
        return gap  # `print .x` — обращение к полю self, пробел значим
    if k in SPACED or pk in SPACED:
        return True
    if pk in (")", "]") and (k == "NAME" or k.isalpha()):
        return True  # fn f() int, if (a) then
    if k in AMBIG:
        return not _is_unary(prev, t, nxt, text) or gap
    if k == "=" or pk == "=":
        if len(stack) <= base:
            return True
        # f(x, reverse=true) и fn(n = 3): как написано, но одинаково с обеих сторон
        if k == "=":
            return gap or _gap_after(t, nxt, text)
        p2end = prev2.col - 1 + len(tok_text(prev2, text)) if prev2 is not None else 0
        return gap or prev.col - 1 > p2end
    return gap
