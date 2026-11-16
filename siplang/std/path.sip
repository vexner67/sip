# Пути к файлам как строки: join, basename, dirname, ext, stem, normalize, abs.
# Разделитель — "/" (macOS и Linux).

import os

# join("a", "b", "c.txt") == "a/b/c.txt"; абсолютная часть отбрасывает всё до неё
fn join(*parts str) str
    out = ""
    for p in parts
        if p.startswith("/") or out == ""
            out = p
        elif out.endswith("/")
            out = out + p
        else
            out = out + "/" + p
    out

# последняя часть пути: basename("a/b.txt") == "b.txt"
fn basename(p str) str
    i = p.rfind("/")
    if i < 0 then p else p[i + 1:]

# всё до последней части: dirname("a/b.txt") == "a", dirname("b.txt") == ""
fn dirname(p str) str
    i = p.rfind("/")
    if i < 0 then return ""
    if i == 0 then return "/"
    p[:i]

# расширение с точкой: ext("a/b.tar.gz") == ".gz", ext(".bashrc") == ""
fn ext(p str) str
    name = basename(p)
    i = name.rfind(".")
    if i <= 0 then "" else name[i:]

# имя без расширения: stem("a/b.txt") == "b"
fn stem(p str) str
    name = basename(p)
    e = ext(name)
    name[:len(name) - len(e)]

# убирает ".", "..", двойные "/": normalize("a/./b/../c") == "a/c"
fn normalize(p str) str
    absolute = p.startswith("/")
    parts: [str] = []
    for part in p.split("/")
        if part == "" or part == "."
            continue
        if part == ".." and parts and parts[len(parts) - 1] != ".."
            parts.pop()
        elif part == ".." and absolute
            continue
        else
            parts.append(part)
    s = "/".join(parts)
    if absolute then "/" + s elif s == "" then "." else s

# абсолютный путь от текущей папки
fn abs(p str) str = if p.startswith("/") then normalize(p) else normalize(os.cwd() + "/" + p)

fn isabs(p str) bool = p.startswith("/")
