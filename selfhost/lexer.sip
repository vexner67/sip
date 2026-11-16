# Лексер Sip на самом Sip: перенос siplang/lexer.py один в один.
# Те же токены, те же позиции (колонки в символах, а не в байтах) и те же ошибки.
# sip run selfhost/lexer.sip FILE.sip печатает токены построчно:
#   ВИД<TAB>строка<TAB>колонка<TAB>длина значения в байтах<TAB>значение

KEYWORDS = {
    "fn", "if", "then", "elif", "else", "for", "in", "while", "return", "match",
    "try", "catch", "fail", "async", "await", "and", "or", "not", "nil", "true",
    "false", "import", "from", "as", "break", "continue", "pass", "is", "with",
    "assert",
}
OPS2 = {"..", "->", "==", "!=", "<=", ">=", "+=", "-=", "*=", "/=", "%=", "**", "//"}
OPS1 = "+-*/%<>=()[]{{}},.:|&@^~?"
OPEN = "([{{"
CLOSE = ")]}}"

# value — текст токена; у строки — то, что между кавычками, а сама кавычка в quote
type Token(kind str, value str, line int, col int, quote str = "")

type LexError(msg str, line int, col int)

# блок с отступами: вся программа или тело многострочной лямбды `fn(x)` в конце строки
type Frame(depth int, base int, indents [int])

fn is_digit(c str) bool = c >= "0" and c <= "9"

fn is_word_start(c str) bool = c.isalpha() or c == "_" or ord(c) >= 128

fn is_word_char(c str) bool = is_word_start(c) or is_digit(c)

# индекс закрывающей кавычки строки, которая начинается в позиции i; внутри {...} — те же кавычки
fn scan_string(text str, i int, line int, col int) int
    quote = text[i]
    j = i + 1
    depth = 0
    n = len(text)
    while j < n
        ch = text[j]
        if ch == "\\"
            j += 2
            continue
        if depth == 0
            if ch == quote then return j
            if ch == "{{"
                if text[j + 1:j + 2] == "{{"
                    j += 2
                    continue
                depth = 1
        elif ch == "\"" or ch == "'"
            j = scan_string(text, j, line, col)
        elif ch == "{{"
            depth += 1
        elif ch == "}}"
            depth -= 1
        j += 1
    fail LexError("unterminated string", line, col)

fn indent_of(text str) int
    j = 0
    while j < len(text) and text[j] == " "
        j += 1
    j

# отступ следующей непустой строки после строки ln (с 1), -1 если её нет
fn next_indent(lines [str], ln int) int
    k = ln
    while k < len(lines)
        text = lines[k]
        j = indent_of(text)
        if j < len(text) and text[j] != "#" then return j
        k += 1
    -1

# как str.splitlines() для \n и \r\n
fn split_lines(src str) [str]
    if src == "" then return []
    lines = src.replace("\r\n", "\n").split("\n")
    if lines[len(lines) - 1] == "" then lines.pop()
    lines

# колонка (с 1) байта i: в символах, как у лексера на Python
fn column(text str, i int, ascii bool) int
    if ascii then return i + 1
    n = 0
    k = 0
    while k < i
        if ord(text[k]) & 192 != 128 then n += 1
        k += 1
    n + 1

fn all_ascii(text str) bool
    for k in 0..len(text) - 1
        if ord(text[k]) >= 128 then return false
    true

type Lexer(toks [Token], frames [Frame], depth int, opens [int], closes {int: int})
    fn add(kind str, value str, line int, col int)
        .toks.append(Token(kind, value, line, col))

    fn last_kind() str = if .toks then .toks[len(.toks) - 1].kind else ""

    fn close_frame(ln int)
        fr = .frames.pop()
        k = .last_kind()
        if .toks and k != "NEWLINE" and k != "DEDENT"
            .add("NEWLINE", "", ln, 1)
        for _ in 1..len(fr.indents) - 1
            .add("DEDENT", "", ln, 1)
        if fr.depth == .frames[len(.frames) - 1].depth  # лямбда была частью инструкции: она закончилась
            .add("NEWLINE", "", ln, 1)

    # строка кончается на `fn(...)`: это заголовок лямбды, а не тип fn(int)
    fn is_header() bool
        n = len(.toks)
        if n == 0 or .toks[n - 1].kind != ")" then return false
        m = .closes.get(n - 1)
        if m == nil then return false
        if m < 1 or .toks[m - 1].kind != "fn" then return false
        if m >= 2
            k = .toks[m - 2].kind
            if k == "NAME" or k == ")" or k == "->" then return false
        true

    fn top() Frame = .frames[len(.frames) - 1]

fn tokenize(src str) [Token]
    lx = Lexer([], [Frame(0, 0, [0])], 0, [], {})
    lines = split_lines(src)
    for ln in 1..len(lines)
        text = lines[ln - 1]
        n = len(text)
        ascii = all_ascii(text)
        i = 0
        line_has_tokens = false
        indent = indent_of(text)
        if lx.depth == lx.top().depth
            j = indent
            if j < n and text[j] == "\t"
                fail LexError("tab in indentation: use spaces", ln, column(text, j, ascii))
            if j == n or text[j] == "#" then continue  # пустая строка или комментарий
            while len(lx.frames) > 1 and lx.depth == lx.top().depth and j <= lx.top().base
                lx.close_frame(ln)
            if lx.depth == lx.top().depth
                fr = lx.top()
                last = fr.indents[len(fr.indents) - 1]
                if j > last
                    fr.indents.append(j)
                    lx.add("INDENT", "", ln, 1)
                elif j < last
                    while j < fr.indents[len(fr.indents) - 1]
                        fr.indents.pop()
                        lx.add("DEDENT", "", ln, 1)
                    if j != fr.indents[len(fr.indents) - 1]
                        fail LexError("indentation does not match any outer block", ln, column(text, j, ascii))
            i = j
        while i < n
            c = text[i]
            col = column(text, i, ascii)
            if c == " " or c == "\t"
                i += 1
                continue
            if c == "#" then break
            line_has_tokens = true
            if is_digit(c)
                j = i
                while j < n and (is_digit(text[j]) or text[j] == "_")
                    j += 1
                # `1.5` это дробь, а `1..5` это диапазон
                if j + 1 < n and text[j] == "." and is_digit(text[j + 1])
                    j += 1
                    while j < n and (is_digit(text[j]) or text[j] == "_")
                        j += 1
                if j < n and (text[j] == "e" or text[j] == "E")
                    k = j + 1
                    if k < n and (text[k] == "+" or text[k] == "-") then k += 1
                    if k < n and is_digit(text[k])
                        j = k
                        while j < n and is_digit(text[j])
                            j += 1
                lx.add("NUMBER", text[i:j], ln, col)
                i = j
                continue
            if is_word_start(c)
                j = i + 1
                while j < n and is_word_char(text[j])
                    j += 1
                word = text[i:j]
                lx.add(if word in KEYWORDS then word else "NAME", word, ln, col)
                i = j
                continue
            if c == "\"" or c == "'"
                j = scan_string(text, i, ln, col)
                lx.toks.append(Token("STRING", text[i + 1:j], ln, col, c))
                i = j + 1
                continue
            two = text[i:i + 2]
            if two in OPS2
                lx.add(two, two, ln, col)
                i += 2
                continue
            if OPS1.find(c) >= 0
                if OPEN.find(c) >= 0
                    lx.depth += 1
                    lx.opens.append(len(lx.toks))
                elif CLOSE.find(c) >= 0
                    if lx.depth == 0 then fail LexError("unmatched '{c}'", ln, col)
                    while len(lx.frames) > 1 and lx.depth == lx.top().depth
                        lx.close_frame(ln)  # `    x + 1)`: скобка закрывает и тело лямбды
                    lx.depth -= 1
                    lx.closes[len(lx.toks)] = lx.opens.pop()
                lx.add(c, c, ln, col)
                i += 1
                continue
            fail LexError("unexpected character '{c}'", ln, col)
        if line_has_tokens and lx.is_header() and next_indent(lines, ln) > indent
            lx.add("NEWLINE", "", ln, column(text, n, ascii))
            lx.frames.append(Frame(lx.depth, indent, [indent]))
        elif lx.depth == lx.top().depth and line_has_tokens and lx.toks and lx.last_kind() != "NEWLINE"
            lx.add("NEWLINE", "", ln, column(text, n, ascii))
    last = len(lines)
    if lx.depth > 0 then fail LexError("unclosed bracket at end of file", last, 0)
    while len(lx.frames) > 1
        lx.close_frame(last + 1)
    indents = lx.frames[0].indents
    lk = lx.last_kind()
    if lx.toks and lk != "NEWLINE" and lk != "DEDENT"
        lx.add("NEWLINE", "", last, 0)
    while len(indents) > 1
        indents.pop()
        lx.add("DEDENT", "", last + 1, 1)
    lx.add("EOF", "", last + 1, 1)
    lx.toks

fn dump(toks [Token]) str
    out: [str] = []
    for t in toks
        out.append("{t.kind}\t{t.line}\t{t.col}\t{len(t.value)}\t{t.quote}{t.value}")
    "\n".join(out) + "\n"

fn main(path str)
    try
        toks = tokenize(read(path))
        write("/dev/stdout", dump(toks))
    catch LexError e
        print "{path}:{e.line}" + (if e.col != 0 then ":{e.col}" else "") + ": {e.msg}"
        exit(1)
