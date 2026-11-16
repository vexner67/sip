# Загрузчик модулей Sip на самом Sip: перенос siplang/modules.py.
# `import utils`, `from utils import f`, пакеты с sip.toml (зависимости-папки) и встроенные модули.
# Все модули сливаются в одну программу: имена верхнего уровня модуля получают префикс
# (utils.f становится utils__f), строки файла k сдвигаются на k * BAND (SrcMap).

import os
import path
import lexer
import parser
from parser import N, mk, S, L

BAND = 1048576  # строк на файл: номер строки = номер файла * BAND + строка в файле

type SipErr(msg str, file str, line int, col int)

# встроенные модули и их члены: вызов math.sqrt(x) становится встроенной функцией "math.sqrt"
NATIVE = {
    "math": {"sqrt", "floor", "ceil", "trunc", "log", "log2", "log10", "exp", "sin", "cos", "tan", "asin",
             "acos", "atan", "atan2", "hypot", "pow", "isnan", "isinf", "gcd", "pi", "e", "inf", "nan", "tau"},
    "random": {"random", "randint", "uniform", "choice", "shuffle", "seed"},
    "time": {"time", "sleep", "perf_counter"},
    "json": {"parse", "stringify", "read", "write"},
    "csv": {"read", "write", "parse"},
    "http": {"get", "post", "Response"},
}

# ---------- узлы ----------

fn isn(n N) bool = n.kind == "None"

fn nm(n N) str = n.kids[0].s

fn flag(n N) bool = n.s == "True"

# имена, которым что-то присваивается (локальные переменные); kinds — имена записей и сумм,
# у catch Kind e такая переменная живёт только в своём catch
fn add_name(names [str], n str)
    if n not in names then names.append(n)

fn assign_target(t N, names [str])
    if t.kind == "Name"
        add_name(names, nm(t))
    elif t.kind == "TupleLit"
        for i in t.kids[0].kids
            assign_target(i, names)
    pass

fn pattern_names(pt N, names [str])
    k = pt.kind
    if k == "PCapture" or k == "PStar"
        add_name(names, nm(pt))
    elif k == "PClass"
        for a in pt.kids[1].kids
            pattern_names(a, names)
        for kv in pt.kids[2].kids
            pattern_names(kv.kids[1], names)
    elif k == "PTuple" or k == "PList"
        for a in pt.kids[0].kids
            pattern_names(a, names)
    pass

fn walk_assigned(ss [N], names [str], augs [str], use_augs bool, kinds {str})
    for s in ss
        k = s.kind
        if k == "FnDef"
            add_name(names, nm(s))
        elif k == "Assign"
            for t in s.kids[0].kids
                assign_target(t, names)
        elif k == "AugAssign" and use_augs and s.kids[0].kind == "Name"
            if nm(s.kids[0]) not in augs then augs.append(nm(s.kids[0]))
        elif k == "AugAssign" or k == "AnnAssign"
            assign_target(s.kids[0], names)
        elif k == "For"
            assign_target(s.kids[0], names)
            walk_assigned(s.kids[2].kids, names, augs, use_augs, kinds)
        elif k == "While"
            walk_assigned(s.kids[1].kids, names, augs, use_augs, kinds)
        elif k == "If"
            for b in s.kids[0].kids
                walk_assigned(b.kids[1].kids, names, augs, use_augs, kinds)
            if not isn(s.kids[1]) then walk_assigned(s.kids[1].kids, names, augs, use_augs, kinds)
        elif k == "With"
            for it in s.kids[0].kids
                if not isn(it.kids[1]) then add_name(names, it.kids[1].s)
            walk_assigned(s.kids[1].kids, names, augs, use_augs, kinds)
        elif k == "Try"
            walk_assigned(s.kids[0].kids, names, augs, use_augs, kinds)
            for h in s.kids[1].kids
                if not isn(h.kids[1]) and (isn(h.kids[0]) or h.kids[0].s not in kinds)
                    add_name(names, h.kids[1].s)
                walk_assigned(h.kids[2].kids, names, augs, use_augs, kinds)
        elif k == "Match"
            for a in s.kids[1].kids
                pattern_names(a.kids[0], names)
                walk_assigned(a.kids[2].kids, names, augs, use_augs, kinds)
    pass

fn assigned(stmts [N], kinds {str}) [str]
    names: [str] = []
    augs: [str] = []
    walk_assigned(stmts, names, augs, false, kinds)
    names

# локальные функции: x += 1 без x = ... может менять глобальную переменную модуля
fn fn_assigned(stmts [N]) [str]
    names: [str] = []
    augs: [str] = []
    walk_assigned(stmts, names, augs, true, set())
    names

fn target_names(t N) {str}
    out: {str} = set()
    if t.kind == "Name"
        out.add(nm(t))
    elif t.kind == "TupleLit"
        for i in t.kids[0].kids
            out = out | target_names(i)
    out

# имена верхнего уровня модуля: их видят те, кто его импортирует
fn top_names(body [N]) [str]
    names: [str] = []
    rest: [N] = []
    for s in body
        k = s.kind
        if k == "FnDef" or k == "Record" or k == "Interface"
            names.append(nm(s))
        elif k == "SumType"
            names.append(nm(s))
            for v in s.kids[1].kids
                names.append(nm(v))
        else
            rest.append(s)
    names + assigned(rest, set())

# ---------- пути ----------

fn abspath(p str) str = path.abs(p)

fn join_parts(d str, parts [str]) str = (if d.endswith("/") then d else d + "/") + "/".join(parts)

fn relpath(p str, start str) str
    a = [x for x in abspath(p).split("/") if x != ""]
    b = [x for x in abspath(start).split("/") if x != ""]
    i = 0
    while i < len(a) and i < len(b) and a[i] == b[i]
        i += 1
    out = [".." for _ in b[i:]] + a[i:]
    if out then "/".join(out) else "."

# как re.sub(r"\W", "_", s)
fn word_safe(s str) str
    out = ""
    for c in s
        out = out + (if c.isalnum() or c == "_" or ord(c) >= 128 then c else "_")
    out

fn is_ident(s str) bool
    if s == "" or not (s[0].isalpha() or s[0] == "_") then return false
    for c in s
        if not (c.isalnum() or c == "_") or ord(c) >= 128 then return false
    true

# ---------- пакеты: sip.toml ----------

# папка с sip.toml: имя пакета и его зависимости {имя: папка}
type Package(root str, name str, deps {str: str}, toml str, cflags [str] = [])

fn unquote(v str) str
    t = v.strip()
    if len(t) >= 2 and t.startswith("\"") and t.endswith("\"") then return t[1:len(t) - 1]
    t

# sip.toml без [c] flags (их смотрит только компилятор C): [package] name и [deps] name = "path" или { path = ... }
fn read_package(root str) Package
    toml = join_parts(root, ["sip.toml"])
    section = ""
    name = ""
    dnames: [str] = []
    dspecs: [{str: str}] = []
    flags: [str] = []
    for raw in read(toml).splitlines()
        line = raw.strip()
        if line == "" or line.startswith("#") then continue
        if line.startswith("[")
            section = line[1:len(line) - 1].strip()
            continue
        eq = line.find("=")
        if eq < 0 then fail SipErr("bad sip.toml: expected key = value", toml, 0, 0)
        key = line[:eq].strip()
        val = line[eq + 1:].strip()
        if section == "package" and key == "name"
            name = unquote(val)
        elif section == "deps"
            spec: {str: str} = {}
            if val.startswith("\"")
                spec["path"] = unquote(val)
            elif val.startswith("{{") and val.endswith("}}")
                for part in val[1:len(val) - 1].split(",")
                    e2 = part.find("=")
                    if e2 >= 0 then spec[part[:e2].strip()] = unquote(part[e2 + 1:])
            else
                spec["?"] = val
            dnames.append(key)
            dspecs.append(spec)
        elif section == "c" and key == "flags"
            if not (val.startswith("[") and val.endswith("]"))
                fail SipErr("[c] flags must be a list of strings, e.g. flags = [\"-I/opt/include\", \"-L/opt/lib\"]",
                            toml, 0, 0)
            for part in val[1:len(val) - 1].split(",")
                if part.strip() != "" then flags.append(unquote(part))
    if name == "" then name = path.basename(abspath(root))
    if not is_ident(name) then fail SipErr("package name '{name}' must be a valid identifier", toml, 0, 0)
    deps: {str: str} = {}
    for dname, spec in zip(dnames, dspecs)
        if not is_ident(dname) then fail SipErr("dependency name '{dname}' must be a valid identifier", toml, 0, 0)
        if "?" in spec
            fail SipErr("dependency '{dname}': write {{ path = \"...\" }} or {{ git = \"...\", rev = \"...\" }}",
                        toml, 0, 0)
        if "path" in spec
            d = path.normalize(join_parts(root, [spec["path"]]))
            if not os.isdir(d) then fail SipErr("dependency '{dname}': folder {d} not found", toml, 0, 0)
            deps[dname] = d
        elif "git" in spec
            if spec.get("rev") == nil or spec["rev"] == ""
                fail SipErr("dependency '{dname}': pin a version with rev = \"<tag or commit>\"", toml, 0, 0)
            fail SipErr("dependency '{dname}': git dependencies are not supported by the self-hosted loader yet",
                        toml, 0, 0)
        else
            fail SipErr("dependency '{dname}' needs path or git", toml, 0, 0)
    aroot = abspath(root)
    for i, f in enumerate(flags)  # -Iinclude и -Llib — от папки пакета
        if (f[:2] == "-I" or f[:2] == "-L") and len(f) > 2 and not f[2:].startswith("/")
            flags[i] = f[:2] + join_parts(aroot, [f[2:]])
    Package(aroot, name, deps, toml, flags)

# ближайший sip.toml в папке файла или выше
fn find_package(start str) Package?
    d = abspath(start)
    while true
        if os.isfile(join_parts(d, ["sip.toml"])) then return read_package(d)
        up = path.dirname(d)
        if up == d or up == "" then return nil
        d = up
    nil

# ---------- переименование: math.sqrt -> имя "math.sqrt", utils.f -> utils__f ----------

type Renamer(names {str: str}, mods {str: {str: str}}, natives {str: str}, file str, offset int)
    fn err(msg str, node N)
        fail SipErr(msg, .file, node.line, 0)

    fn new(name str, local {str}) str
        if name in local then return ""
        got = .names.get(name)
        if got == nil then return ""
        got

    # alias.attr -> новое имя, если alias — модуль (а не переменная)
    fn member(alias str, attr str, node N, local {str}) str
        if alias in local or alias in .names then return ""
        if alias in .mods
            ex = .mods[alias]
            if attr not in ex then .err("module '{alias}' has no '{attr}'", node)
            if attr.startswith("_")
                .err("'{attr}' is private to module '{alias}' (names starting with _ are not exported)", node)
            return ex[attr]
        mod = ""
        got = .natives.get(alias)
        if got != nil
            mod = got
        elif alias in NATIVE
            mod = alias
        if mod != ""
            if attr not in NATIVE[mod] then .err("module '{mod}' has no '{attr}'", node)
            return mod + "." + attr
        ""

    fn dotted(name str, node N, local {str}) str
        if name.find(".") >= 0
            i = name.find(".")
            got = .member(name[:i], name[i + 1:], node, local)
            return if got != "" then got else name
        got = .new(name, local)
        if got != "" then got else name

    # определение, которое переименовали: в s остаётся имя из исходника (для сообщений)
    fn rename_def(s N)
        if nm(s) in .names
            s.s = nm(s)
            s.kids[0] = S(.names[nm(s)])
        pass

    fn top(s N) N
        k = s.kind
        if k == "FnDef" or k == "Record" or k == "SumType" or k == "Interface" then .rename_def(s)
        empty: {str} = set()
        .rn(s, empty)

    fn rn_all(n N, local {str})
        for i in 0..len(n.kids) - 1
            n.kids[i] = .rn(n.kids[i], local)
        pass

    fn rn(n N, local0 {str}) N
        local = local0
        k = n.kind
        if k == "list" or k == "tuple"
            .rn_all(n, local)
            return n
        if k == "str" or k == "None" or k == "bool" or k == "extern" then return n
        if n.line != 0 then n.line += .offset
        if k == "Name"
            got = .new(nm(n), local)
            if got != ""
                n.kids[0] = S(got)
            elif nm(n) not in local and (nm(n) in .mods or nm(n) in .natives)
                .err("module '{nm(n)}' cannot be used as a value", n)
            return n
        if k == "Attr" and n.kids[0].kind == "Name"
            got = .member(nm(n.kids[0]), n.kids[1].s, n, local)
            if got != "" then return mk("Name", n.line, [S(got)])
        if k == "TName" or k == "PClass" then n.kids[0] = S(.dotted(nm(n), n, local))
        if k == "PValue" then return mk("PClass", n.line, [S(.dotted(nm(n), n, local)), L([]), L([])])
        if k == "PCapture" or k == "PStar"
            got = .new(nm(n), local)
            if got != "" then n.kids[0] = S(got)
            return n
        if k == "Handler"
            if not isn(n.kids[0]) then n.kids[0] = S(.dotted(n.kids[0].s, n, local))
            if not isn(n.kids[1])
                got = .new(n.kids[1].s, local)
                if got != "" then n.kids[1] = S(got)
        if k == "Variant" then .rename_def(n)
        if (k == "Record" or k == "SumType") and n.kids[3].kids
            local = local | {tp.kids[0].s for tp in n.kids[3].kids}  # T в полях — не имя модуля
        if k == "FnDef"
            if len(n.kids) == 9 then n.kids[8].line = n.line  # extern
            n.kids[7] = .rn(n.kids[7], local)
            local = local | {tp.kids[0].s for tp in n.kids[7].kids}
            inner = local | {p.kids[0].s for p in n.kids[1].kids}
            for a in fn_assigned(n.kids[3].kids)
                inner.add(a)
            if flag(n.kids[6]) then inner.add("self")
            for p in n.kids[1].kids
                .rn(p, local)  # тип и значение по умолчанию — снаружи
            n.kids[2] = .rn(n.kids[2], local)
            n.kids[3] = .rn(n.kids[3], inner)
            return n
        if k == "Lambda"
            n.kids[2] = .rn(n.kids[2], local)
            inner = local | {p.s for p in n.kids[0].kids}
            if not isn(n.kids[3])
                for a in fn_assigned(n.kids[3].kids)
                    inner.add(a)
                n.kids[3] = .rn(n.kids[3], inner)
            else
                n.kids[1] = .rn(n.kids[1], inner)
            return n
        if k == "Comp"
            bound: {str} = set()
            for c in n.kids[3].kids
                bound = bound | target_names(c.kids[0])
            inner = local | bound
            first = true
            for c in n.kids[3].kids
                c.kids[1] = .rn(c.kids[1], if first then local else inner)
                first = false
                c.kids[0] = .rn(c.kids[0], inner)
                c.kids[2] = .rn(c.kids[2], inner)
            n.kids[1] = .rn(n.kids[1], inner)
            n.kids[2] = .rn(n.kids[2], inner)
            return n
        .rn_all(n, local)
        n

# ---------- загрузчик ----------

type Loader(std str, files [(int, str)] = [], srcs [[str]] = [], extra [str] = [], modules {str: {str: str}} = {}, loading {str: bool} = {},
            bodies [N] = [], pkg_seen {str: bool} = {}, pkgs {str: Package} = {}, base str = ".")

    fn package_of(p str) Package?
        d = path.dirname(abspath(p))
        if d not in .pkg_seen
            .pkg_seen[d] = true
            pkg = find_package(d)
            if pkg != nil then .pkgs[d] = pkg
        .pkgs.get(d)

    fn add(p str, src str) int
        offset = len(.files) * BAND
        .files.append((offset, p))
        lines = py_lines(src)
        .srcs.append(if lines then lines else [""])
        offset

    fn parse_file(src str, p str) [N]
        mod = NONE_MOD()
        try
            mod = parser.Parser(lexer.tokenize(src), 0).parse_module()
        catch lexer.LexError e
            fail SipErr(e.msg, p, e.line, e.col)
        catch parser.ParseError e
            fail SipErr(e.msg, p, e.line, e.col)
        [s for s in mod.kids[0].kids if s.kind != "TestDef"]  # тесты модуля — только для sip test его самого

    fn load_root(p str, src str) [N]
        body = .parse_file(src, p)
        offset = .add(p, src)
        pkg = .package_of(p)
        .base = if pkg != nil then pkg.root else path.dirname(abspath(p))
        .loading[abspath(p)] = true  # import самого себя — циклический импорт
        out = .process(body, "", p, offset, {})
        .bodies + out

    # import a.b -> (путь файла, префикс имён): рядом с файлом, в зависимости пакета, от корня пакета, в std
    fn resolve(name str, from_path str, node N) (str, str)
        parts = name.split(".")
        here = path.dirname(abspath(from_path))
        tried = [join_parts(here, parts) + ".sip"]
        pkg = .package_of(from_path)
        if pkg != nil
            if parts[0] in pkg.deps
                rest = if len(parts) > 1 then parts[1:] else parts[:1]
                tried.append(join_parts(pkg.deps[parts[0]], rest) + ".sip")
            tried.append(join_parts(pkg.root, parts) + ".sip")
        tried.append(join_parts(.std, parts) + ".sip")
        for t in tried
            if os.isfile(t) then return (abspath(t), .prefix(t))
        fail SipErr("module '{name}' not found (looked for {', '.join(tried)})", from_path, node.line, 0)

    # префикс имён модуля: из пакета и пути внутри него, чтобы модули разных пакетов не путались
    fn prefix(p str) str
        if abspath(p).startswith(.std + "/")
            rel = relpath(p, .std)
            return "__".join(["std"] + [word_safe(x) for x in rel[:len(rel) - 4].split("/")]) + "__"
        pkg = .package_of(p)
        label: [str] = []
        if pkg != nil and pkg.root != .base
            rel = relpath(p, pkg.root)
            label = [pkg.name] + rel[:len(rel) - 4].split("/")
        else
            rel = relpath(p, .base)
            label = [if x == ".." then "up" else x for x in rel[:len(rel) - 4].split("/")]
        "__".join([word_safe(x) for x in label]) + "__"

    fn load_module(name str, from_path str, node N) {str: str}
        p, pre = .resolve(name, from_path, node)
        if p in .loading then fail SipErr("circular import of '{name}'", from_path, node.line, 0)
        if p in .modules then return .modules[p]
        src = read(p)
        .loading[p] = true
        body = .parse_file(src, p)
        offset = .add(p, src)
        exports: {str: str} = {}
        for n in top_names(body)
            exports[n] = pre + n
        out = .process(body, pre, p, offset, exports)
        .bodies.extend(out)
        .loading.pop(p)
        .modules[p] = exports
        exports

    fn process(body [N], pre str, file str, offset int, exports {str: str}) [N]
        names = exports.copy()
        mods: {str: {str: str}} = {}
        natives: {str: str} = {}
        rest: [N] = []
        for s in body
            if s.kind == "Import"
                module = s.kids[0].s
                parts = module.split(".")
                alias = if isn(s.kids[1]) then parts[len(parts) - 1] else s.kids[1].s
                if module in NATIVE
                    natives[alias] = module
                else
                    mods[alias] = .load_module(module, file, s)
            elif s.kind == "FromImport"
                module = s.kids[0].s
                for pair in s.kids[1].kids
                    n = pair.kids[0].s
                    alias = if isn(pair.kids[1]) then n else pair.kids[1].s
                    if module in NATIVE
                        if n not in NATIVE[module] then fail SipErr("module '{module}' has no '{n}'", file, s.line, 0)
                        names[alias] = "{module}.{n}"
                    else
                        ex = .load_module(module, file, s)
                        if n not in ex then fail SipErr("module '{module}' has no '{n}'", file, s.line, 0)
                        if n.startswith("_")
                            fail SipErr("'{n}' is private to module '{module}' (names starting with _ " +
                                        "are not exported)", file, s.line, 0)
                        names[alias] = ex[n]
            else
                rest.append(s)
        r = Renamer(names, mods, natives, file, offset)
        [r.top(s) for s in rest]

    # строка программы -> (файл, строка в файле)
    fn locate(line int) (str, int)
        i = len(.files) - 1
        while i >= 0
            offset, f = .files[i]
            if line > offset then return (f, line - offset)
            i -= 1
        (if .files then .files[0][1] else "<input>", line)

# как str.splitlines в Python: концом строки считаются и \r, \r\n, \v, \f, \x1c-\x1e
fn py_lines(src str) [str]
    out: [str] = []
    start = 0
    i = 0
    n = len(src)
    while i < n
        b = ord(src[i])
        if b == 10 or b == 13 or b == 11 or b == 12 or (b >= 28 and b <= 30)
            out.append(src[start:i])
            if b == 13 and i + 1 < n and src[i + 1] == "\n" then i += 1
            start = i + 1
        i += 1
    if start < n then out.append(src[start:])
    out

fn NONE_MOD() N = mk("Module", 1, [L([])])
