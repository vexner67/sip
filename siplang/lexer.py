"""Лексер Sip: превращает исходник в поток токенов.

Блоки задаются отступами, как в Python: лексер выдаёт INDENT/DEDENT.
Внутри скобок переводы строк и отступы игнорируются.
"""

from dataclasses import dataclass

from .errors import SipError

KEYWORDS = {
    "fn", "if", "then", "elif", "else", "for", "in", "while", "return", "match",
    "try", "catch", "fail", "async", "await", "and", "or", "not", "nil", "true",
    "false", "import", "from", "as", "break", "continue", "pass", "is", "with",
    "assert",
}
# `type` и `print` контекстные: это обычные имена, а смысл им придаёт парсер.

OPS2 = {"..", "->", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "**", "//"}
OPS1 = set("+-*/%<>=()[]{},.:|&@^~?")
OPEN, CLOSE = "([{", ")]}"


@dataclass
class Token:
    kind: str   # NAME, NUMBER, STRING, NEWLINE, INDENT, DEDENT, EOF, ключевое слово или оператор
    value: object
    line: int
    col: int

    def __repr__(self) -> str:
        return f"{self.kind}({self.value!r})@{self.line}:{self.col}"


def _scan_string(text: str, i: int, line: int, file: str) -> int:
    """Возвращает индекс закрывающей кавычки строки, которая начинается в позиции i.

    Внутри `{...}` можно использовать те же кавычки: "{d["key"]}".
    """
    quote = text[i]
    j = i + 1
    depth = 0
    n = len(text)
    while j < n:
        ch = text[j]
        if ch == "\\":
            j += 2
            continue
        if depth == 0:
            if ch == quote:
                return j
            if ch == "{":
                if text[j + 1:j + 2] == "{":
                    j += 2
                    continue
                depth = 1
        else:
            if ch in "\"'":
                j = _scan_string(text, j, line, file)
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
        j += 1
    raise SipError("unterminated string", line, i + 1, file)


def _indent_of(text: str) -> int:
    j = 0
    while j < len(text) and text[j] == " ":
        j += 1
    return j


def _next_indent(lines: list, ln: int) -> int:
    """Отступ следующей непустой строки после строки ln (с 1), -1 если её нет."""
    for text in lines[ln:]:
        j = _indent_of(text)
        if j < len(text) and text[j] != "#":
            return j
    return -1


class _Frame:
    """Блок с отступами. Внешний — вся программа; вложенные — тела многострочных лямбд
    `fn(x)` в конце строки, в том числе внутри скобок."""

    def __init__(self, depth: int, base: int):
        self.depth = depth        # глубина скобок, на которой живёт блок
        self.indents = [base]
        self.base = base


def tokenize(src: str, file: str = "<input>") -> list[Token]:
    toks: list[Token] = []
    frames = [_Frame(0, 0)]
    depth = 0  # глубина вложенности скобок
    opens: list[int] = []      # индексы открывающих скобок в toks
    match: dict[int, int] = {}  # индекс закрывающей скобки -> индекс открывающей
    lines = src.splitlines()

    def close_frame(ln):
        fr = frames.pop()
        if toks and toks[-1].kind not in ("NEWLINE", "DEDENT"):
            toks.append(Token("NEWLINE", "", ln, 1))
        for _ in fr.indents[1:]:
            toks.append(Token("DEDENT", "", ln, 1))
        if fr.depth == frames[-1].depth:  # лямбда была частью инструкции: она закончилась
            toks.append(Token("NEWLINE", "", ln, 1))

    def is_header() -> bool:
        """Строка кончается на `fn(...)`: это заголовок лямбды, а не тип fn(int)."""
        if not toks or toks[-1].kind != ")" or len(toks) - 1 not in match:
            return False
        m = match[len(toks) - 1]
        if m < 1 or toks[m - 1].kind != "fn":
            return False
        if m >= 2 and toks[m - 2].kind in ("NAME", ")", "->"):
            return False  # f fn(int), fn g() fn(int)
        return True

    for ln, text in enumerate(lines, 1):
        n = len(text)
        i = 0
        line_has_tokens = False
        indent = _indent_of(text)

        if depth == frames[-1].depth:
            j = indent
            if j < n and text[j] == "\t":
                raise SipError("tab in indentation: use spaces", ln, j + 1, file)
            if j == n or text[j] == "#":
                continue  # пустая строка или комментарий
            while len(frames) > 1 and depth == frames[-1].depth and j <= frames[-1].base:
                close_frame(ln)
            if depth == frames[-1].depth:
                indents = frames[-1].indents
                if j > indents[-1]:
                    indents.append(j)
                    toks.append(Token("INDENT", "", ln, 1))
                elif j < indents[-1]:
                    while j < indents[-1]:
                        indents.pop()
                        toks.append(Token("DEDENT", "", ln, 1))
                    if j != indents[-1]:
                        raise SipError("indentation does not match any outer block", ln, j + 1, file)
            i = j
        while i < n:
            c = text[i]
            col = i + 1
            if c in " \t":
                i += 1
                continue
            if c == "#":
                break
            line_has_tokens = True

            if c.isdigit():
                j = i
                while j < n and (text[j].isdigit() or text[j] == "_"):
                    j += 1
                # `1.5` это дробь, а `1..5` это диапазон
                if j + 1 < n and text[j] == "." and text[j + 1].isdigit():
                    j += 1
                    while j < n and (text[j].isdigit() or text[j] == "_"):
                        j += 1
                if j < n and text[j] in "eE":
                    k = j + 1
                    if k < n and text[k] in "+-":
                        k += 1
                    if k < n and text[k].isdigit():
                        j = k
                        while j < n and text[j].isdigit():
                            j += 1
                toks.append(Token("NUMBER", text[i:j], ln, col))
                i = j
                continue

            if c.isalpha() or c == "_":
                j = i + 1
                while j < n and (text[j].isalnum() or text[j] == "_"):
                    j += 1
                word = text[i:j]
                toks.append(Token(word if word in KEYWORDS else "NAME", word, ln, col))
                i = j
                continue

            if c in "\"'":
                j = _scan_string(text, i, ln, file)
                toks.append(Token("STRING", (c, text[i + 1:j]), ln, col))
                i = j + 1
                continue

            two = text[i:i + 2]
            if two in OPS2:
                toks.append(Token(two, two, ln, col))
                i += 2
                continue

            if c in OPS1:
                if c in OPEN:
                    depth += 1
                    opens.append(len(toks))
                elif c in CLOSE:
                    if depth == 0:
                        raise SipError(f"unmatched '{c}'", ln, col, file)
                    while len(frames) > 1 and depth == frames[-1].depth:
                        close_frame(ln)  # `    x + 1)`: скобка закрывает и тело лямбды
                    depth -= 1
                    match[len(toks)] = opens.pop()
                toks.append(Token(c, c, ln, col))
                i += 1
                continue

            raise SipError(f"unexpected character {c!r}", ln, col, file)

        if line_has_tokens and is_header() and _next_indent(lines, ln) > indent:
            toks.append(Token("NEWLINE", "", ln, n + 1))
            frames.append(_Frame(depth, indent))
        elif depth == frames[-1].depth and line_has_tokens and toks and toks[-1].kind != "NEWLINE":
            toks.append(Token("NEWLINE", "", ln, n + 1))

    last = len(lines)
    if depth > 0:
        raise SipError("unclosed bracket at end of file", last, 0, file)
    while len(frames) > 1:
        close_frame(last + 1)
    indents = frames[0].indents
    if toks and toks[-1].kind not in ("NEWLINE", "DEDENT"):
        toks.append(Token("NEWLINE", "", last, 0))
    while len(indents) > 1:
        indents.pop()
        toks.append(Token("DEDENT", "", last + 1, 1))
    toks.append(Token("EOF", "", last + 1, 1))
    return toks
