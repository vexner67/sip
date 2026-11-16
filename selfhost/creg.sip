# C-типы и вспомогательные функции для каждого конкретного типа: перенос siplang/cregistry.py.
# Списки, словари и кортежи мономорфизируются: для [int] и [str] получаются разные структуры и функции.

import checker
from checker import Ty, INT, FLOAT, BOOL, STR, UNIT, RANGE, PTR, prune, show, is_gen, base_of, fields_of
from checker import variants_of, hashable, comparable, list_t, dict_t, tuple_t, fn_t, fn_params, fn_ret, instantiate
from parser import N

# тип нельзя перевести в JSON или прочитать из JSON
type JsonTypeError(msg str)

# ---------- типы как в C ----------

# полностью раскрытый тип: без связанных переменных и параметров экземпляра
fn deep(t0 Ty) Ty
    t = prune(t0)
    k = t.k
    if k == "list" or k == "dict" or k == "tuple" or k == "opt" or k == "set" or k == "fn" or k == "task"
        return Ty(k, checker.nid(), a=[deep(x) for x in t.a])
    if is_gen(t) and t.a then return instantiate(base_of(t), [deep(x) for x in t.a])
    t

fn is_p(t Ty, p Ty) bool = prune(t).id == p.id

fn opt_t(t Ty) Ty = Ty("opt", checker.nid(), a=[t])

fn set_t(t Ty) Ty = Ty("set", checker.nid(), a=[t])

fn task_t(t Ty) Ty = Ty("task", checker.nid(), a=[t])

# имя типа в C; одинаковые типы дают одинаковые имена
fn key(t0 Ty) str
    t = prune(t0)
    k = t.k
    if k == "prim" then return t.name
    if k == "list" then return "L_" + key(t.a[0])
    if k == "dict" then return "D_" + key(t.a[0]) + "__" + key(t.a[1])
    if k == "tuple" then return "T{len(t.a)}_" + "_".join([key(i) for i in t.a])
    if is_gen(t)
        args = if t.a then "__" + "_".join([key(a) for a in t.a]) else ""
        return (if k == "record" then "R_" else "S_") + t.name + args
    if k == "iface" then return "I_" + t.name
    if k == "opt" then return "O_" + key(t.a[0])
    if k == "set" then return "Z_" + key(t.a[0])
    if k == "fn"
        ps = fn_params(t)
        return "F{len(ps)}_" + "_".join([key(p) for p in ps]) + "__" + key(fn_ret(t))
    if k == "task" then return "K_" + key(t.a[0])
    fail Error("unresolved type {show(t)}")

# тип хранится как указатель, и nil для него — NULL
fn is_ref(t0 Ty) bool
    t = prune(t0)
    t.id == PTR.id or t.k == "list" or t.k == "dict" or is_gen(t) or t.k == "set"

fn ctype(t0 Ty) str
    t = prune(t0)
    if t.id == INT.id then return "int64_t"
    if t.id == FLOAT.id then return "double"
    if t.id == BOOL.id then return "bool"
    if t.id == STR.id then return "sip_str"
    if t.id == UNIT.id then return "void"
    if t.id == RANGE.id then return "sip_range"
    if t.id == PTR.id then return "void *"
    if t.k == "opt" and is_ref(t.a[0]) then return ctype(t.a[0])
    if t.k == "set" then return key(dict_t(t.a[0], BOOL))
    key(t)

# в значении типа нет указателей: его память сборщик мусора не сканирует
fn no_ptrs(t0 Ty) bool
    t = prune(t0)
    if t.k == "prim" then return t.id != STR.id and t.id != PTR.id  # ptr может указывать на память сборщика
    if t.k == "tuple"
        for x in t.a
            if not no_ptrs(x) then return false
        return true
    if t.k == "opt" then return not is_ref(t.a[0]) and no_ptrs(t.a[0])
    false

fn disp(t Ty) str
    d = base_of(t).display
    if d != "" then d else t.name

fn vdisp(t Ty, v str) str = base_of(t).vdisplay.get(v, v)

# ---------- выражения C ----------

fn json_key(name str) str = "\"" + name.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

# оператор C, который дописывает str(val) в построитель строк sb
fn fmt_call(t0 Ty, sb str, val str) str
    t = prune(t0)
    if t.id == STR.id then return "sip_sb_str({sb}, {val});"
    if t.k == "prim" then return "str_{t.name}({sb}, {val});"
    if t.k == "opt" then return "str_{key(t)}({sb}, {val});"
    "repr_{key(t)}({sb}, {val});"

# условие «значение T? не nil»
fn opt_has(t Ty, code str) str = if is_ref(prune(t).a[0]) then "({code} != NULL)" else "({code}).has"

# значение T? без проверки (проверку сделали раньше)
fn opt_val(t Ty, code str) str = if is_ref(prune(t).a[0]) then code else "({code}).v"

fn nil_code(t0 Ty) str
    t = prune(t0)
    if is_ref(t.a[0]) then "NULL" else "(({ctype(t)}){{0}})"

fn repr_call(t0 Ty, sb str, val str) str
    t = prune(t0)
    if t.k == "prim" then return "repr_{t.name}({sb}, {val});"
    "repr_{key(t)}({sb}, {val});"

fn eq_expr(t0 Ty, a str, b str) str
    t = prune(t0)
    if t.id == INT.id or t.id == FLOAT.id or t.id == BOOL.id or t.id == PTR.id then return "({a} == {b})"
    "eq_{key(t)}({a}, {b})"

fn cmp_fn(t Ty) str = "cmp_" + key(t)

fn hash_fn(t Ty) str = "hash_" + key(t)

fn oct3(b int) str = "\\" + str(b // 64) + str(b // 8 % 8) + str(b % 8)

# байты строки как литерал C
fn c_bytes(data str) str
    out: [str] = []
    for i in 0..len(data) - 1
        ch = data[i]
        b = ord(ch)
        if ch == "\\"
            out.append("\\\\")
        elif ch == "\""
            out.append("\\\"")
        elif ch == "?"
            out.append("\\?")
        elif b >= 32 and b < 127
            out.append(ch)
        else
            out.append(oct3(b))
    "\"" + "".join(out) + "\""

# строка -> литерал C и его длина в байтах
fn clit(s str) str
    out: [str] = []
    for i in 0..len(s) - 1
        ch = s[i]
        b = ord(ch)
        if b >= 32 and b < 127 and ch != "\"" and ch != "\\" and ch != "?"
            out.append(ch)
        else
            out.append(oct3(b))
    "\"" + "".join(out) + "\", {len(s)}"

# устойчивая сортировка слиянием; less — выражение от @X и @Y: X строго раньше Y
fn msort(name str, ce str, less str) str
    L = fn(x str, y str) = "(" + less.replace("@X", x).replace("@Y", y) + ")"
    "\n".join([
        "static void {name}_rec({ce} *a, {ce} *tmp, int64_t n, bool rev) {{",
        "    if (n <= 16) {{",
        "        for (int64_t i = 1; i < n; i++) {{",
        "            {ce} v = a[i];",
        "            int64_t j = i;",
        "            while (j > 0 && {L('v', 'a[j - 1]')}) {{ a[j] = a[j - 1]; j--; }}",
        "            a[j] = v;",
        "        }}",
        "        return;",
        "    }}",
        "    int64_t m = n / 2;",
        "    {name}_rec(a, tmp, m, rev);",
        "    {name}_rec(a + m, tmp, n - m, rev);",
        "    if (!{L('a[m]', 'a[m - 1]')}) return;",
        "    memcpy(tmp, a, (size_t)m * sizeof({ce}));",
        "    int64_t i = 0, j = m, k = 0;",
        "    while (i < m && j < n) {{",
        "        if ({L('a[j]', 'tmp[i]')}) a[k++] = a[j++]; else a[k++] = tmp[i++];",
        "    }}",
        "    while (i < m) a[k++] = tmp[i++];",
        "}}",
        "static void {name}({ce} *a, int64_t n, bool rev) {{",
        "    if (n < 2) return;",
        "    {ce} *tmp = malloc((size_t)n * sizeof({ce}));",
        "    {name}_rec(a, tmp, n, rev);",
        "    free(tmp);",
        "}}",
        ""])

# ---------- реестр ----------

type Gen(body str, ps [str], im str)

# cc: литерал по умолчанию (поле записи) -> оператор C `target = значение;` в отдельном блоке
type Registry(cc fn(N, str) str, types {str: Ty} = {}, order [str] = [], jnames [str] = [],
              jprotos {str: str} = {}, jimpls {str: str} = {})

    fn need(t0 Ty) str
        t = deep(t0)
        if t.k == "prim" then return t.name
        k = key(t)
        if k in .types then return k
        .types[k] = t
        tk = t.k
        if tk == "list"
            .need(t.a[0])
        elif tk == "dict"
            .need(t.a[0])
            .need(t.a[1])
            .need(list_t(t.a[0]))
            .need(list_t(t.a[1]))
            .need(list_t(tuple_t([t.a[0], t.a[1]])))
        elif tk == "tuple"
            for i in t.a
                .need(i)
        elif tk == "record"
            fs = fields_of(t)
            for fname in fs
                .need(fs[fname])
        elif tk == "sum"
            vs = variants_of(t)
            for vn in vs
                for f in vs[vn]
                    .need(f.ty)
        elif tk == "opt"
            .need(t.a[0])
        elif tk == "set"
            .need(dict_t(t.a[0], BOOL))
        elif tk == "fn"
            for pt in fn_params(t)
                .need(pt)
            .need(fn_ret(t))
        elif tk == "task"
            .need(fn_t([], t.a[0]))
        elif tk == "iface"
            for mname in t.imethods
                sig = t.imethods[mname]
                for p in sig.params
                    .need(p.ty)
                .need(sig.ret)
        .order.append(k)
        k

    fn jset(name str, proto str, impl str)
        if name not in .jprotos then .jnames.append(name)
        .jprotos[name] = proto
        .jimpls[name] = impl

    # ---------- сборка ----------

    fn code() str
        fwd: [str] = []
        tuples: [str] = []
        bodies: [str] = []
        protos: [str] = []
        impls: [str] = []
        for k in .order
            t = .types[k]
            if t.k == "list" or t.k == "dict" or is_gen(t) or t.k == "task" then fwd.append("typedef struct {k}_s *{k};")
        for k in .order
            # значения по месту: кортежи, T? для не-ссылочных T, замыкания — в порядке зависимостей
            t = .types[k]
            if t.k == "tuple"
                fields = " ".join(["{ctype(it)} f{i};" for i, it in enumerate(t.a)])
                tuples.append("typedef struct {{ {fields} }} {k};")
            elif t.k == "opt" and not is_ref(t.a[0])
                tuples.append("typedef struct {{ bool has; {ctype(t.a[0])} v; }} {k};")
            elif t.k == "fn"
                ps = ", ".join(["void *"] + [ctype(p) for p in fn_params(t)])
                tuples.append("typedef struct {{ {ctype(fn_ret(t))} (*fn)({ps}); void *env; }} {k};")
            elif t.k == "iface"
                # значение интерфейса: объект и таблица его методов
                tuples.append("struct {k}_vt;")
                tuples.append("typedef struct {{ void *o; const struct {k}_vt *vt; }} {k};")
        for k in .order
            t = .types[k]
            g = .gen(k, t)
            if g.body != "" then bodies.append(g.body)
            protos.extend(g.ps)
            impls.append(g.im)
        jp = [.jprotos[n] for n in .jnames]
        ji = [.jimpls[n] for n in .jnames]
        "\n".join(["/* ---- типы ---- */"] + fwd + tuples + bodies + ["/* ---- вспомогательные функции ---- */"] +
                  protos + impls + jp + ji)

    fn gen(k str, t Ty) Gen
        tk = t.k
        if tk == "tuple" then return .gen_tuple(k, t)
        if tk == "list" then return .gen_list(k, t)
        if tk == "dict" then return .gen_dict(k, t)
        if tk == "set" then return .gen_set(k, t)
        if tk == "opt" then return .gen_opt(k, t)
        if tk == "fn" then return .gen_fn(k, t)
        if tk == "task" then return .gen_task(k, t)
        if tk == "iface" then return .gen_iface(k, t)
        if tk == "record" then return .gen_record(k, t)
        .gen_sum(k, t)

    # ---------- JSON ----------

    # имя функции C: sip_str -> значение типа t (весь текст — одно значение JSON)
    fn jparse(t0 Ty) str
        t = deep(t0)
        dec = .jdec(t)
        name = "jparse_{.need(t)}"
        if name not in .jprotos
            ct = ctype(t)
            sig = "static {ct} {name}(sip_str s, int line)"
            .jset(name, sig + ";", sig + " {{ sip_jp jp = sip_jp_new(s, line); sip_jp *p = &jp; " +
                  "{ct} v = {dec}; sip_jp_end(p); return v; }}")
        name

    # имя функции C: (значение, отступ или -1) -> строка JSON
    fn jdump(t0 Ty) str
        t = deep(t0)
        enc = .jenc(t, "v", "0")
        name = "jdump_{.need(t)}"
        if name not in .jprotos
            sig = "static sip_str {name}({ctype(t)} v, int64_t ind)"
            .jset(name, sig + ";", sig + " {{ sip_sb sb = sip_sb_new(); sip_sb *b = &sb; {enc} " +
                  "return sip_sb_done(b); }}")
        name

    # ---------- CSV ----------

    fn csv_conv(t Ty, i str, col str) str
        if t.id == STR.id then return "sip_csv_cell(c, {i})"
        if t.id == INT.id then return "sip_csv_int(c, {i}, {col})"
        if t.id == FLOAT.id then return "sip_csv_float(c, {i}, {col})"
        if t.id == BOOL.id then return "sip_csv_bool(c, {i}, {col})"
        ""

    # оператор C: target = ячейка i, переведённая в t (col — имя колонки для ошибок)
    fn csv_cell(t0 Ty, target str, i str, col str, dflt N? = nil) str
        t = deep(t0)
        if t.k == "opt"
            inner = deep(t.a[0])
            got = .csv_conv(inner, i, col)
            if got == "" then fail JsonTypeError("CSV cells cannot hold {show(t)}")
            .need(t)
            return ("if (sip_csv_cell(c, {i}).n == 0) {target} = ({key(t)}){{0}}; " +
                   "else {target} = ({key(t)}){{true, {got}}};")
        conv = .csv_conv(t, i, col)
        if conv == "" then fail JsonTypeError("CSV cells cannot hold {show(t)}")
        code = "{target} = {conv};"
        if dflt != nil and t.id != STR.id
            d: N = dflt
            return "if (sip_csv_cell(c, {i}).n == 0) {.cc(d, target)} else {code}"
        code

    # имя функции C: (текст, разделитель, строка) -> значение типа t
    fn csvread(t0 Ty) str
        t = deep(t0)
        if t.k != "list" then fail JsonTypeError("CSV is read as a list of rows, not {show(t)}")
        k = .need(t)
        name = "csvread_{k}"
        if name in .jprotos then return name
        row = deep(t.a[0])
        rk = .need(row)
        body = ["    sip_csv cv = sip_csv_new(text, delim, line); sip_csv *c = &cv;", "    {k} out = {k}_new(0);"]
        if row.k == "list"
            ce = ctype(row.a[0])
            body.extend(["    while (sip_csv_row(c)) {{", "        {rk} r = {rk}_new(c->nf);",
                         "        for (int64_t j = 0; j < c->nf; j++) {{", "            {ce} v;",
                         "            " + .csv_cell(row.a[0], "v", "j", "(sip_str){{\"\", 0}}"),
                         "            {rk}_push(r, v);", "        }}", "        {k}_push(out, r);", "    }}"])
        elif row.k == "dict"
            if not is_p(row.a[0], STR) then fail JsonTypeError("CSV rows as dicts need str keys, not {show(row)}")
            cv = ctype(row.a[1])
            body.extend(["    if (!sip_csv_row(c)) return out;",
                         "    sip_str *hdr = sip_csv_header(c); int64_t nh = c->nf;",
                         "    while (sip_csv_row(c)) {{", "        if (c->nf == 0) continue;",
                         "        {rk} r = {rk}_new();",
                         "        for (int64_t j = 0; j < nh; j++) {{", "            {cv} v;",
                         "            " + .csv_cell(row.a[1], "v", "j", "hdr[j]"),
                         "            {rk}_set(r, hdr[j], v);", "        }}", "        {k}_push(out, r);", "    }}"])
        elif row.k == "record"
            dn = disp(row)
            defaults = base_of(row).cdefaults
            fs = fields_of(row)
            body.extend(["    if (!sip_csv_row(c)) return out;",
                         "    sip_str *hdr = sip_csv_header(c); int64_t nh = c->nf;"])
            for fname in fs
                body.append("    int64_t ix_{fname} = sip_csv_col(hdr, nh, (sip_str){{{clit(fname)}}});")
                if prune(fs[fname]).k != "opt" and fname not in defaults
                    msg = "CSV has no column '{fname}' (needed for {dn})".replace("\"", "\\\"")
                    body.append("    if (ix_{fname} < 0) sip_raise(SIP_E_ParseError, SIP_LIT(\"{msg}\"), line);")
            body.extend(["    while (sip_csv_row(c)) {{", "        if (c->nf == 0) continue;"])
            for fname in fs
                ft = fs[fname]
                body.append("        {ctype(ft)} jf_{fname};")
                cell = .csv_cell(ft, "jf_{fname}", "ix_{fname}", "(sip_str){{{clit(fname)}}}", defaults.get(fname))
                if fname in defaults
                    body.append("        if (ix_{fname} < 0) {.cc(defaults[fname], 'jf_' + fname)} else {cell}")
                else
                    body.append("        {cell}")
            args = ", ".join(["jf_{fname}" for fname in fs])
            body.extend(["        {k}_push(out, {rk}_new({args}));", "    }}"])
        else
            fail JsonTypeError("CSV rows are read as [str], {{str: str}} or a record, not {show(row)}")
        sig = "static {k} {name}(sip_str text, sip_str delim, int line)"
        .jset(name, sig + ";", sig + " {{\n" + "\n".join(body + ["    return out;"]) + "\n}}")
        name

    # оператор C: дописать ячейку со значением val в sip_sb *b (разделитель dch)
    fn csv_put(t0 Ty, val str) str
        t = deep(t0)
        if t.k == "opt" then return "if ({opt_has(t, val)}) {{ {.csv_put(t.a[0], opt_val(t, val))} }}"
        if t.id == STR.id then return "sip_csv_put(b, {val}, dch);"
        if t.k == "fn" then fail JsonTypeError("CSV cells cannot hold {show(t)}")
        .need(t)
        "{{ sip_sb tb = sip_sb_new(); {fmt_call(t, '&tb', val)} sip_csv_put(b, sip_sb_done(&tb), dch); }}"

    # имя функции C: (строки, разделитель, строка) -> текст CSV
    fn csvdump(t0 Ty) str
        t = deep(t0)
        if t.k != "list" then fail JsonTypeError("CSV is written from a list of rows, not {show(t)}")
        k = .need(t)
        name = "csvdump_{k}"
        if name in .jprotos then return name
        row = deep(t.a[0])
        rk = .need(row)
        body = ["    char dch = sip_csv_delim(delim, line);", "    sip_sb sb = sip_sb_new(); sip_sb *b = &sb;"]
        sep = "if (j) sip_sb_putc(b, dch);"
        crlf = "        sip_sb_put(b, \"\\r\\n\", 2);"
        if row.k == "list"
            body.extend(["    for (int64_t i = 0; i < rows->n; i++) {{", "        {rk} r = rows->d[i];",
                         "        for (int64_t j = 0; j < r->n; j++) {{ {sep} {.csv_put(row.a[0], 'r->d[j]')} }}",
                         crlf, "    }}"])
        elif row.k == "tuple"
            cells = " sip_sb_putc(b, dch); ".join([.csv_put(it, "r.f{j}") for j, it in enumerate(row.a)])
            body.extend(["    for (int64_t i = 0; i < rows->n; i++) {{", "        {rk} r = rows->d[i];",
                         "        {cells}", crlf, "    }}"])
        elif row.k == "record"
            fs = fields_of(row)
            hdr = " sip_sb_putc(b, dch); ".join(["sip_csv_put(b, (sip_str){{{clit(fname)}}}, dch);" for fname in fs])
            cells = " sip_sb_putc(b, dch); ".join([.csv_put(fs[fname], "r->f_{fname}") for fname in fs])
            body.extend(["    {hdr}", "    sip_sb_put(b, \"\\r\\n\", 2);",
                         "    for (int64_t i = 0; i < rows->n; i++) {{", "        {rk} r = rows->d[i];",
                         "        {cells}", crlf, "    }}"])
        elif row.k == "dict"
            if not is_p(row.a[0], STR) then fail JsonTypeError("CSV rows as dicts need str keys, not {show(row)}")
            put = .csv_put(row.a[1], "{rk}_get(r, h->e[j].k, line)")
            body.extend(["    if (rows->n == 0) return sip_sb_done(b);", "    {rk} h = rows->d[0];",
                         "    for (int64_t j = 0; j < h->n; j++) {{ {sep} sip_csv_put(b, h->e[j].k, dch); }}",
                         "    sip_sb_put(b, \"\\r\\n\", 2);",
                         "    for (int64_t i = 0; i < rows->n; i++) {{", "        {rk} r = rows->d[i];",
                         "        for (int64_t j = 0; j < h->n; j++) {{ {sep} " +
                         "if ({rk}_contains(r, h->e[j].k)) {{ {put} }} }}",
                         crlf, "    }}"])
        else
            fail JsonTypeError("CSV rows are written from lists, tuples, dicts or records, not {show(row)}")
        sig = "static sip_str {name}({k} rows, sip_str delim, int line)"
        .jset(name, sig + ";", sig + " {{\n" + "\n".join(body + ["    return sip_sb_done(b);"]) + "\n}}")
        name

    fn http_wrap(rt Ty) str
        k = .need(rt)
        d = .need(dict_t(STR, STR))
        name = "sip_http_wrap"
        if name not in .jprotos
            sig = "static {k} {name}(sip_http_resp r)"
            .jset(name, sig + ";", sig + " {{ {d} h = {d}_new(); " +
                  "for (int64_t i = 0; i < r.nh; i++) {d}_set(h, r.hk[i], r.hv[i]); " +
                  "return {k}_new(r.status, r.status >= 200 && r.status < 300, r.body, r.url, h); }}")
        name

    # выражение C, которое читает значение типа t из sip_jp *p
    fn jdec(t0 Ty) str
        t = deep(t0)
        if t.id == INT.id then return "sip_jp_int(p)"
        if t.id == FLOAT.id then return "sip_jp_float(p)"
        if t.id == BOOL.id then return "sip_jp_bool(p)"
        if t.id == STR.id then return "sip_jp_str(p)"
        if t.k == "prim" or t.k == "fn" then fail JsonTypeError("{show(t)} cannot be read from JSON")
        k = .need(t)
        name = "jdec_{k}"
        if name not in .jprotos
            ct = ctype(t)
            .jset(name, "static {ct} {name}(sip_jp *p);", "")
            .jset(name, "static {ct} {name}(sip_jp *p);", "static {ct} {name}(sip_jp *p) {{\n{.jdec_body(k, t)}\n}}")
        "{name}(p)"

    # чтение полей объекта: (строки кода, имена переменных)
    fn jdec_fields(fields [(str, Ty, N?)]) ([str], str)
        lines: [str] = []
        for f in fields
            fname, ft, _ = f
            lines.append("    {ctype(ft)} jf_{fname} = ({ctype(ft)}){{0}}; bool js_{fname} = false;")
        lines.append("    sip_str k;")
        lines.append("    for (int64_t i = 0; sip_jp_obj_next(p, i, &k); i++) {{")
        lines.append("        int64_t m = sip_jp_path_key(p, k);")
        for i, f in enumerate(fields)
            fname, ft, _ = f
            lines.append("        {if i > 0 then 'else ' else ''}if (sip_str_is(k, {clit(fname)})) " +
                         "{{ jf_{fname} = {.jdec(ft)}; js_{fname} = true; }}")
        lines.append("        {if fields then 'else ' else ''}sip_jp_skip(p);")
        lines.append("        p->path.n = m;")
        lines.append("    }}")
        for f in fields
            fname, ft, dflt = f
            if prune(ft).k == "opt" then continue
            if dflt != nil
                d: N = dflt
                lines.append("    if (!js_{fname}) {.cc(d, 'jf_' + fname)}")
            else
                msg = "missing field '{fname}'".replace("\"", "\\\"")
                lines.append("    if (!js_{fname}) sip_jp_fail(p, \"{msg}\");")
        (lines, ", ".join(["jf_{f[0]}" for f in fields]))

    fn jdec_body(k str, t Ty) str
        if t.k == "list"
            return ("    sip_jp_want(p, '[', \"list\");\n    {k} l = {k}_new(0);\n" +
                   "    for (int64_t i = 0; sip_jp_arr_next(p, i); i++) {{\n" +
                   "        int64_t m = sip_jp_path_idx(p, i);\n        {k}_push(l, {.jdec(t.a[0])});\n" +
                   "        p->path.n = m;\n    }}\n    return l;")
        if t.k == "set"
            d = ctype(t)
            return ("    sip_jp_want(p, '[', \"list\");\n    {d} s = {d}_new();\n" +
                   "    for (int64_t i = 0; sip_jp_arr_next(p, i); i++) {{\n" +
                   "        int64_t m = sip_jp_path_idx(p, i);\n        {d}_set(s, {.jdec(t.a[0])}, true);\n" +
                   "        p->path.n = m;\n    }}\n    return s;")
        if t.k == "dict"
            kt = deep(t.a[0])
            kc = ""
            if kt.id == STR.id
                kc = "k"
            elif kt.id == INT.id
                kc = "sip_jp_key_int(p, k)"
            else
                fail JsonTypeError("{show(t)} cannot be read from JSON: keys must be str or int")
            return ("    sip_jp_want(p, '{{', \"dict\");\n    {k} d = {k}_new();\n    sip_str k;\n" +
                   "    for (int64_t i = 0; sip_jp_obj_next(p, i, &k); i++) {{\n" +
                   "        int64_t m = sip_jp_path_key(p, k);\n        {ctype(kt)} key = {kc};\n" +
                   "        {k}_set(d, key, {.jdec(t.a[1])});\n" +
                   "        p->path.n = m;\n    }}\n    return d;")
        if t.k == "opt"
            inner = .jdec(t.a[0])
            if is_ref(t.a[0]) then return "    if (sip_jp_null(p)) return NULL;\n    return {inner};"
            return "    if (sip_jp_null(p)) return ({k}){{0}};\n    return ({k}){{true, {inner}}};"
        if t.k == "tuple"
            n = len(t.a)
            lines = ["    sip_jp_want(p, '[', \"list\");", "    {k} r;", "    int64_t m;"]
            for i, it in enumerate(t.a)
                lines.append("    if (!sip_jp_arr_next(p, {i})) sip_jp_fail(p, \"expected a list of {n} items\");")
                lines.append("    m = sip_jp_path_idx(p, {i}); r.f{i} = {.jdec(it)}; p->path.n = m;")
            lines.append("    if (sip_jp_arr_next(p, {n})) sip_jp_fail(p, \"expected a list of {n} items\");")
            lines.append("    return r;")
            return "\n".join(lines)
        if t.k == "record"
            fs = fields_of(t)
            defs = base_of(t).cdefaults
            fl: [(str, Ty, N?)] = []
            for fname in fs
                fl.append((fname, fs[fname], defs.get(fname)))
            lines, args = .jdec_fields(fl)
            return "\n".join(["    sip_jp_want(p, '{{', \"object\");"] + lines + ["    return {k}_new({args});"])
        if t.k == "sum"
            lines = ["    sip_str tag = sip_jp_tag(p);"]
            vs = variants_of(t)
            for vname in vs
                dn = vdisp(t, vname)
                fl: [(str, Ty, N?)] = []
                for f in vs[vname]
                    fl.append((f.name, f.ty, nil))
                body, args = .jdec_fields(fl)
                lines.append("    if (sip_str_is(tag, {clit(dn)})) {{")
                lines.append("        sip_jp_want(p, '{{', \"object\");")
                lines.extend(["    " + x for x in body])
                lines.append("        return {k}_new_{vname}({args});")
                lines.append("    }}")
            lines.append("    sip_jp_fail(p, \"unknown \\\"type\\\"\");")
            return "\n".join(lines)
        fail JsonTypeError("{show(t)} cannot be read from JSON")

    # оператор C: дописать JSON значения v в sip_sb *b (отступ ind, глубина d)
    fn jenc(t0 Ty, v str, d str) str
        t = deep(t0)
        if t.id == INT.id then return "str_int(b, {v});"
        if t.id == FLOAT.id then return "sip_je_float(b, {v});"
        if t.id == BOOL.id then return "sip_je_bool(b, {v});"
        if t.id == STR.id then return "sip_je_str(b, {v});"
        if t.k == "prim" or t.k == "fn" then fail JsonTypeError("{show(t)} cannot be converted to JSON")
        k = .need(t)
        name = "jenc_{k}"
        if name not in .jprotos
            ct = ctype(t)
            sig = "static void {name}(sip_sb *b, {ct} v, int64_t ind, int64_t d)"
            .jset(name, sig + ";", "")
            .jset(name, sig + ";", sig + " {{\n" + .jenc_body(k, t) + "\n}}")
        "{name}(b, {v}, ind, {d});"

    # объект с полями [(имя, тип, выражение)]
    fn jenc_obj(items [(str, Ty, str)], tag str?) [str]
        lines = ["    sip_sb_putc(b, '{{');"]
        first = "true"
        if tag != nil
            tg: str = tag
            lines.append("    sip_je_sep(b, ind, d + 1, true); sip_sb_put(b, {clit('\"type\": ')});" +
                         " sip_je_str(b, (sip_str){{{clit(tg)}}});")
            first = "false"
        for it in items
            fname, ft, ex = it
            lines.append("    sip_je_sep(b, ind, d + 1, {first}); " +
                         "sip_sb_put(b, {clit(json_key(fname) + ': ')}); {.jenc(ft, ex, 'd + 1')}")
            first = "false"
        if items or tag != nil
            lines.append("    sip_je_close(b, ind, d, '}}');")
        else
            lines.append("    sip_sb_putc(b, '}}');")
        lines

    fn jenc_body(k str, t Ty) str
        if t.k == "list" or t.k == "set"
            n = "v->n"
            item = if t.k == "list" then "v->d[i]" else "v->e[i].k"
            return ("    sip_sb_putc(b, '[');\n    for (int64_t i = 0; i < {n}; i++) {{\n" +
                   "        sip_je_sep(b, ind, d + 1, i == 0); {.jenc(t.a[0], item, 'd + 1')}\n    }}\n" +
                   "    if ({n}) sip_je_close(b, ind, d, ']'); else sip_sb_putc(b, ']');")
        if t.k == "tuple"
            lines = ["    sip_sb_putc(b, '[');"]
            for i, it in enumerate(t.a)
                lines.append("    sip_je_sep(b, ind, d + 1, {if i == 0 then 'true' else 'false'}); " +
                             .jenc(it, "v.f{i}", "d + 1"))
            lines.append(if t.a then "    sip_je_close(b, ind, d, ']');" else "    sip_sb_putc(b, ']');")
            return "\n".join(lines)
        if t.k == "dict"
            kt = deep(t.a[0])
            keyw = ""
            if kt.id == STR.id
                keyw = "sip_je_str(b, v->e[i].k);"
            elif kt.id == INT.id
                keyw = "sip_sb_putc(b, '\"'); str_int(b, v->e[i].k); sip_sb_putc(b, '\"');"
            elif kt.id == FLOAT.id
                keyw = "sip_sb_putc(b, '\"'); sip_je_float(b, v->e[i].k); sip_sb_putc(b, '\"');"
            elif kt.id == BOOL.id
                keyw = "sip_sb_putc(b, '\"'); sip_je_bool(b, v->e[i].k); sip_sb_putc(b, '\"');"
            else
                fail JsonTypeError("{show(t)} cannot be converted to JSON: keys must be str, int, float or bool")
            return ("    sip_sb_putc(b, '{{');\n    for (int64_t i = 0; i < v->n; i++) {{\n" +
                   "        sip_je_sep(b, ind, d + 1, i == 0); {keyw} sip_sb_put(b, \": \", 2); " +
                   "{.jenc(t.a[1], 'v->e[i].v', 'd + 1')}\n    }}\n" +
                   "    if (v->n) sip_je_close(b, ind, d, '}}'); else sip_sb_putc(b, '}}');")
        if t.k == "opt"
            return ("    if (!{opt_has(t, 'v')}) {{ sip_sb_put(b, \"null\", 4); return; }}\n" +
                   "    {.jenc(t.a[0], opt_val(t, 'v'), 'd')}")
        if t.k == "record"
            fs = fields_of(t)
            return "\n".join(.jenc_obj([(fname, fs[fname], "v->f_{fname}") for fname in fs], nil))
        if t.k == "sum"
            lines = ["    switch (v->tag) {{"]
            vs = variants_of(t)
            for idx, vname in enumerate([v for v in vs])
                dn = vdisp(t, vname)
                body = .jenc_obj([(f.name, f.ty, "v->u.{vname}.f_{f.name}") for f in vs[vname]], dn)
                lines.append("    case {idx}: {{")
                lines.extend(["    " + x for x in body])
                lines.append("        return;\n    }}")
            lines.append("    }}")
            return "\n".join(lines)
        fail JsonTypeError("{show(t)} cannot be converted to JSON")

    # ---------- кортежи ----------

    fn gen_tuple(k str, t Ty) Gen
        n = len(t.a)
        ps = ["static bool eq_{k}({k} a, {k} b);", "static void repr_{k}(sip_sb *b, {k} a);"]
        eqs = " && ".join([eq_expr(it, "a.f{i}", "b.f{i}") for i, it in enumerate(t.a)])
        eq = if eqs == "" then "true" else eqs
        rep: [str] = []
        for i, it in enumerate(t.a)
            if i > 0 then rep.append("sip_sb_put(b, \", \", 2);")
            rep.append(repr_call(it, "b", "a.f{i}"))
        if n == 1 then rep.append("sip_sb_putc(b, ',');")
        im = ["static bool eq_{k}({k} a, {k} b) {{ return {eq}; }}",
              "static void repr_{k}(sip_sb *b, {k} a) {{ sip_sb_putc(b, '('); {' '.join(rep)} sip_sb_putc(b, ')'); }}"]
        if comparable(t)
            ps.append("static int cmp_{k}({k} a, {k} b);")
            steps = " ".join(["if ((c = {cmp_fn(it)}(a.f{i}, b.f{i}))) return c;" for i, it in enumerate(t.a)])
            im.append("static int cmp_{k}({k} a, {k} b) {{ int c; {steps} return 0; }}")
        if hashable(t)
            ps.append("static uint64_t hash_{k}({k} a);")
            mix = " ".join(["h = sip_mix(h ^ {hash_fn(it)}(a.f{i}));" for i, it in enumerate(t.a)])
            im.append("static uint64_t hash_{k}({k} a) {{ uint64_t h = 0x9e3779b97f4a7c15ULL; {mix} return h; }}")
        Gen("", ps, "\n".join(im))

    # ---------- списки ----------

    fn gen_list(k str, t Ty) Gen
        el = t.a[0]
        ce = ctype(el)
        body = "struct {k}_s {{ int64_t n, cap; {ce} *d; }};"
        sigs = ["static {k} {k}_new(int64_t cap)",
                "static inline void {k}_push({k} l, {ce} x)",
                "static inline {ce} *{k}_ref({k} l, int64_t i, int line)",
                "static inline {ce} {k}_get({k} l, int64_t i, int line)",
                "static {ce} {k}_pop({k} l, int64_t i, bool has_i, int line)",
                "static void {k}_insert({k} l, int64_t i, {ce} x)",
                "static {k} {k}_slice({k} l, int64_t lo, int64_t hi, bool has_lo, bool has_hi)",
                "static {k} {k}_copy({k} l)",
                "static {k} {k}_concat({k} a, {k} b)",
                "static void {k}_extend({k} a, {k} b)",
                "static {k} {k}_repeat({k} l, int64_t times, int line)",
                "static bool {k}_contains({k} l, {ce} x)",
                "static int64_t {k}_index({k} l, {ce} x, int line)",
                "static int64_t {k}_count({k} l, {ce} x)",
                "static void {k}_reverse({k} l)",
                "static sip_str {k}_join({k} l, sip_str sep)"]
        eq = eq_expr(el, "l->d[i]", "x")
        ra = if no_ptrs(el) then "sip_realloc_atomic" else "sip_realloc"  # числа сборщик не сканирует
        im = "\n".join([
            "{sigs[0]} {{",
            "    {k} l = sip_alloc(sizeof *l);",
            "    l->n = 0; l->cap = cap;",
            "    l->d = cap ? {ra}(NULL, (size_t)cap * sizeof({ce})) : NULL;",
            "    return l;",
            "}}",
            "{sigs[1]} {{",
            "    if (SIP_UNLIKELY(l->n == l->cap)) {{",
            "        l->cap = l->cap ? l->cap * 2 : 4;",
            "        l->d = {ra}(l->d, (size_t)l->cap * sizeof({ce}));",
            "    }}",
            "    l->d[l->n++] = x;",
            "}}",
            "{sigs[2]} {{",
            "    if (i < 0) i += l->n;",
            "    if (SIP_UNLIKELY((uint64_t)i >= (uint64_t)l->n)) sip_raise(SIP_E_IndexError, SIP_LIT(\"list index out of range\"), line);",
            "    return &l->d[i];",
            "}}",
            "{sigs[3]} {{ return *{k}_ref(l, i, line); }}",
            "{sigs[4]} {{",
            "    if (SIP_UNLIKELY(l->n == 0)) sip_raise(SIP_E_IndexError, SIP_LIT(\"pop from empty list\"), line);",
            "    if (!has_i) return l->d[--l->n];",
            "    {ce} *p = {k}_ref(l, i, line);",
            "    int64_t j = p - l->d;",
            "    {ce} x = *p;",
            "    memmove(&l->d[j], &l->d[j + 1], (size_t)(l->n - j - 1) * sizeof({ce}));",
            "    l->n--;",
            "    return x;",
            "}}",
            "{sigs[5]} {{",
            "    if (i < 0) i += l->n;",
            "    if (i < 0) i = 0;",
            "    if (i > l->n) i = l->n;",
            "    {k}_push(l, x);",
            "    memmove(&l->d[i + 1], &l->d[i], (size_t)(l->n - 1 - i) * sizeof({ce}));",
            "    l->d[i] = x;",
            "}}",
            "{sigs[6]} {{",
            "    sip_clamp(l->n, &lo, &hi, has_lo, has_hi);",
            "    {k} r = {k}_new(hi - lo);",
            "    if (hi > lo) memcpy(r->d, l->d + lo, (size_t)(hi - lo) * sizeof({ce}));",
            "    r->n = hi - lo;",
            "    return r;",
            "}}",
            "{sigs[7]} {{ return {k}_slice(l, 0, 0, false, false); }}",
            "{sigs[8]} {{",
            "    {k} r = {k}_new(a->n + b->n);",
            "    if (a->n) memcpy(r->d, a->d, (size_t)a->n * sizeof({ce}));",
            "    if (b->n) memcpy(r->d + a->n, b->d, (size_t)b->n * sizeof({ce}));",
            "    r->n = a->n + b->n;",
            "    return r;",
            "}}",
            "{sigs[9]} {{ int64_t n = b->n; for (int64_t i = 0; i < n; i++) {k}_push(a, b->d[i]); }}",
            "{sigs[10]} {{",
            "    int64_t total = 0;",
            "    if (times > 0 && (__builtin_mul_overflow(l->n, times, &total) || total > ((int64_t)1 << 40)))",
            "        sip_raise(SIP_E_OverflowError, SIP_LIT(\"repeated list is too long\"), line);",
            "    {k} r = {k}_new(total);",
            "    for (int64_t t = 0; t < times; t++) for (int64_t i = 0; i < l->n; i++) {k}_push(r, l->d[i]);",
            "    return r;",
            "}}",
            "{sigs[11]} {{ for (int64_t i = 0; i < l->n; i++) if ({eq}) return true; return false; }}",
            "{sigs[12]} {{",
            "    for (int64_t i = 0; i < l->n; i++) if ({eq}) return i;",
            "    sip_raise(SIP_E_ValueError, SIP_LIT(\"value is not in list\"), line);",
            "}}",
            "{sigs[13]} {{ int64_t c = 0; for (int64_t i = 0; i < l->n; i++) if ({eq}) c++; return c; }}",
            "{sigs[14]} {{",
            "    for (int64_t i = 0, j = l->n - 1; i < j; i++, j--) {{ {ce} x = l->d[i]; l->d[i] = l->d[j]; l->d[j] = x; }}",
            "}}",
            "{sigs[15]} {{",
            "    sip_sb b = sip_sb_new();",
            "    for (int64_t i = 0; i < l->n; i++) {{",
            "        if (i) sip_sb_str(&b, sep);",
            "        {fmt_call(el, '&b', 'l->d[i]')}",
            "    }}",
            "    return sip_sb_done(&b);",
            "}}",
            "static bool eq_{k}({k} a, {k} b) {{",
            "    if (a == b) return true;",
            "    if (a->n != b->n) return false;",
            "    for (int64_t i = 0; i < a->n; i++) if (!{eq_expr(el, 'a->d[i]', 'b->d[i]')}) return false;",
            "    return true;",
            "}}",
            "static void repr_{k}(sip_sb *b, {k} l) {{",
            "    sip_sb_putc(b, '[');",
            "    for (int64_t i = 0; i < l->n; i++) {{",
            "        if (i) sip_sb_put(b, \", \", 2);",
            "        {repr_call(el, 'b', 'l->d[i]')}",
            "    }}",
            "    sip_sb_putc(b, ']');",
            "}}"])
        ps = [s + ";" for s in sigs] + ["static bool eq_{k}({k} a, {k} b);", "static void repr_{k}(sip_sb *b, {k} l);"]
        if comparable(el)
            cf = cmp_fn(el)
            ps.extend(["static void {k}_sort({k} l, bool rev);", "static int cmp_{k}({k} a, {k} b);"])
            im = im + "\n" + msort("{k}_msort", ce, "rev ? {cf}(@Y, @X) < 0 : {cf}(@X, @Y) < 0")
            im = im + "\n" + "\n".join([
                "static void {k}_sort({k} l, bool rev) {{ {k}_msort(l->d, l->n, rev); }}",
                "static int cmp_{k}({k} a, {k} b) {{",
                "    int64_t n = a->n < b->n ? a->n : b->n;",
                "    for (int64_t i = 0; i < n; i++) {{ int c = {cf}(a->d[i], b->d[i]); if (c) return c; }}",
                "    return (a->n > b->n) - (a->n < b->n);",
                "}}"])
        Gen(body, ps, im)

    # ---------- словари ----------

    fn gen_dict(k str, t Ty) Gen
        kt = t.a[0]
        vt = t.a[1]
        ck = ctype(kt)
        cv = ctype(vt)
        lk = key(list_t(kt))
        lv = key(list_t(vt))
        lt = key(list_t(tuple_t([kt, vt])))
        tt = key(tuple_t([kt, vt]))
        e = "DE_{k}"
        body = ("typedef struct {{ {ck} k; {cv} v; uint64_t h; }} {e};\n" +
               "struct {k}_s {{ int64_t n, cap, icap; {e} *e; int32_t *ix; }};")
        sigs = ["static {k} {k}_new(void)",
                "static inline int64_t {k}_find({k} d, {ck} key, uint64_t h)",
                "static void {k}_rehash({k} d, int64_t icap)",
                "static {cv} *{k}_slot({k} d, {ck} key, {cv} dflt)",
                "static inline void {k}_set({k} d, {ck} key, {cv} v)",
                "static {cv} *{k}_ref({k} d, {ck} key, int line)",
                "static inline {cv} {k}_get({k} d, {ck} key, int line)",
                "static inline {cv} {k}_get_or({k} d, {ck} key, {cv} dflt)",
                "static inline bool {k}_contains({k} d, {ck} key)",
                "static {lk} {k}_keys({k} d)",
                "static {lv} {k}_values({k} d)",
                "static {lt} {k}_items({k} d)",
                "static {k} {k}_copy({k} d)",
                "static {k} {k}_merge({k} a, {k} b)",
                "static bool {k}_discard({k} d, {ck} key)",
                "static {cv} {k}_pop({k} d, {ck} key, int line)"]
        ra = if no_ptrs(kt) and no_ptrs(vt) then "sip_realloc_atomic" else "sip_realloc"
        h = hash_fn(kt)
        im = "\n".join([
            "{sigs[0]} {{ {k} d = sip_alloc(sizeof *d); memset(d, 0, sizeof *d); return d; }}",
            "{sigs[1]} {{",
            "    if (SIP_UNLIKELY(!d->icap)) return -1;",
            "    uint64_t m = (uint64_t)d->icap - 1;",
            "    for (uint64_t i = h & m;; i = (i + 1) & m) {{",
            "        int32_t j = d->ix[i];",
            "        if (!j) return -1;",
            "        {e} *en = &d->e[j - 1];",
            "        if (en->h == h && {eq_expr(kt, 'en->k', 'key')}) return j - 1;",
            "    }}",
            "}}",
            "{sigs[2]} {{",
            "    d->ix = sip_alloc_atomic((size_t)icap * sizeof(int32_t));",
            "    memset(d->ix, 0, (size_t)icap * sizeof(int32_t));",
            "    d->icap = icap;",
            "    uint64_t m = (uint64_t)icap - 1;",
            "    for (int64_t j = 0; j < d->n; j++) {{",
            "        uint64_t i = d->e[j].h & m;",
            "        while (d->ix[i]) i = (i + 1) & m;",
            "        d->ix[i] = (int32_t)(j + 1);",
            "    }}",
            "}}",
            "{sigs[3]} {{",
            "    uint64_t h = {h}(key);",
            "    int64_t j = {k}_find(d, key, h);",
            "    if (j >= 0) return &d->e[j].v;",
            "    if ((d->n + 1) * 4 > d->icap * 3) {k}_rehash(d, d->icap ? d->icap * 2 : 8);",
            "    if (d->n == d->cap) {{",
            "        d->cap = d->cap ? d->cap * 2 : 8;",
            "        d->e = {ra}(d->e, (size_t)d->cap * sizeof({e}));",
            "    }}",
            "    d->e[d->n] = ({e}){{key, dflt, h}};",
            "    uint64_t m = (uint64_t)d->icap - 1, i = h & m;",
            "    while (d->ix[i]) i = (i + 1) & m;",
            "    d->ix[i] = (int32_t)(d->n + 1);",
            "    return &d->e[d->n++].v;",
            "}}",
            "{sigs[4]} {{ *{k}_slot(d, key, v) = v; }}",
            "{sigs[5]} {{",
            "    int64_t j = {k}_find(d, key, {h}(key));",
            "    if (SIP_UNLIKELY(j < 0)) {{",
            "        sip_sb b = sip_sb_new();",
            "        {repr_call(kt, '&b', 'key')}",
            "        sip_raise(SIP_E_KeyError, sip_sb_done(&b), line);",
            "    }}",
            "    return &d->e[j].v;",
            "}}",
            "{sigs[6]} {{ return *{k}_ref(d, key, line); }}",
            "{sigs[7]} {{ int64_t j = {k}_find(d, key, {h}(key)); return j >= 0 ? d->e[j].v : dflt; }}",
            "{sigs[8]} {{ return {k}_find(d, key, {h}(key)) >= 0; }}",
            "{sigs[9]} {{ {lk} r = {lk}_new(d->n); for (int64_t j = 0; j < d->n; j++) r->d[j] = d->e[j].k; r->n = d->n; return r; }}",
            "{sigs[10]} {{ {lv} r = {lv}_new(d->n); for (int64_t j = 0; j < d->n; j++) r->d[j] = d->e[j].v; r->n = d->n; return r; }}",
            "{sigs[11]} {{",
            "    {lt} r = {lt}_new(d->n);",
            "    for (int64_t j = 0; j < d->n; j++) r->d[j] = ({tt}){{d->e[j].k, d->e[j].v}};",
            "    r->n = d->n;",
            "    return r;",
            "}}",
            "{sigs[12]} {{ {k} r = {k}_new(); for (int64_t j = 0; j < d->n; j++) {k}_set(r, d->e[j].k, d->e[j].v); return r; }}",
            "{sigs[13]} {{ {k} r = {k}_copy(a); for (int64_t j = 0; j < b->n; j++) {k}_set(r, b->e[j].k, b->e[j].v); return r; }}",
            "static bool eq_{k}({k} a, {k} b) {{",
            "    if (a == b) return true;",
            "    if (a->n != b->n) return false;",
            "    for (int64_t j = 0; j < a->n; j++) {{",
            "        int64_t i = {k}_find(b, a->e[j].k, a->e[j].h);",
            "        if (i < 0 || !{eq_expr(vt, 'a->e[j].v', 'b->e[i].v')}) return false;",
            "    }}",
            "    return true;",
            "}}",
            "static void repr_{k}(sip_sb *b, {k} d) {{",
            "    sip_sb_putc(b, '{{');",
            "    for (int64_t j = 0; j < d->n; j++) {{",
            "        if (j) sip_sb_put(b, \", \", 2);",
            "        {repr_call(kt, 'b', 'd->e[j].k')}",
            "        sip_sb_put(b, \": \", 2);",
            "        {repr_call(vt, 'b', 'd->e[j].v')}",
            "    }}",
            "    sip_sb_putc(b, '}}');",
            "}}",
            "{sigs[14]} {{",
            "    int64_t j = {k}_find(d, key, {h}(key));",
            "    if (j < 0) return false;",
            "    memmove(&d->e[j], &d->e[j + 1], (size_t)(d->n - j - 1) * sizeof({e}));",
            "    d->n--;",
            "    {k}_rehash(d, d->icap);",
            "    return true;",
            "}}",
            "{sigs[15]} {{",
            "    int64_t j = {k}_find(d, key, {h}(key));",
            "    if (SIP_UNLIKELY(j < 0)) {{",
            "        sip_sb b = sip_sb_new();",
            "        {repr_call(kt, '&b', 'key')}",
            "        sip_raise(SIP_E_KeyError, sip_sb_done(&b), line);",
            "    }}",
            "    {cv} v = d->e[j].v;",
            "    {k}_discard(d, key);",
            "    return v;",
            "}}"])
        ps = [s + ";" for s in sigs] + ["static bool eq_{k}({k} a, {k} b);", "static void repr_{k}(sip_sb *b, {k} d);"]
        if is_p(vt, INT)
            ps.extend(["static {k} {k}_count({lk} l);", "static {lt} {k}_top({k} d, int64_t n, bool has_n);"])
            im = im + "\n" + msort("{k}_topsort", tt, "@X.f1 > @Y.f1")
            im = im + "\n" + "\n".join([
                "static {k} {k}_count({lk} l) {{",
                "    {k} d = {k}_new();",
                "    for (int64_t i = 0; i < l->n; i++) (*{k}_slot(d, l->d[i], 0))++;",
                "    return d;",
                "}}",
                "static {lt} {k}_top({k} d, int64_t n, bool has_n) {{",
                "    {lt} r = {k}_items(d);",
                "    {k}_topsort(r->d, r->n, false);",
                "    if (has_n && n >= 0 && n < r->n) r->n = n;",
                "    return r;",
                "}}"])
        Gen(body, ps, im)

    # ---------- множества ----------

    fn gen_set(k str, t Ty) Gen
        el = t.a[0]
        d = key(dict_t(el, BOOL))
        ce = ctype(el)
        ps = ["static bool eq_{k}({d} a, {d} b);", "static void repr_{k}(sip_sb *b, {d} s);",
              "static bool {k}_subset({d} a, {d} b);", "static {d} {k}_union({d} a, {d} b);",
              "static {d} {k}_inter({d} a, {d} b);", "static {d} {k}_diff({d} a, {d} b);",
              "static {d} {k}_xor({d} a, {d} b);", "static void {k}_update({d} a, {d} b);",
              "static void {k}_remove({d} s, {ce} x, int line);"]
        im = "\n".join([
            "static bool {k}_subset({d} a, {d} b) {{",
            "    if (a->n > b->n) return false;",
            "    for (int64_t i = 0; i < a->n; i++) if ({d}_find(b, a->e[i].k, a->e[i].h) < 0) return false;",
            "    return true;",
            "}}",
            "static bool eq_{k}({d} a, {d} b) {{ return a->n == b->n && {k}_subset(a, b); }}",
            "static void repr_{k}(sip_sb *b, {d} s) {{",
            "    if (!s->n) {{ sip_sb_put(b, \"set()\", 5); return; }}",
            "    sip_sb_putc(b, '{{');",
            "    for (int64_t i = 0; i < s->n; i++) {{",
            "        if (i) sip_sb_put(b, \", \", 2);",
            "        {repr_call(el, 'b', 's->e[i].k')}",
            "    }}",
            "    sip_sb_putc(b, '}}');",
            "}}",
            "static void {k}_update({d} a, {d} b) {{ for (int64_t i = 0; i < b->n; i++) {d}_set(a, b->e[i].k, true); }}",
            "static {d} {k}_union({d} a, {d} b) {{ {d} r = {d}_copy(a); {k}_update(r, b); return r; }}",
            "static {d} {k}_inter({d} a, {d} b) {{",
            "    {d} r = {d}_new();",
            "    for (int64_t i = 0; i < a->n; i++) if ({d}_find(b, a->e[i].k, a->e[i].h) >= 0) {d}_set(r, a->e[i].k, true);",
            "    return r;",
            "}}",
            "static {d} {k}_diff({d} a, {d} b) {{",
            "    {d} r = {d}_new();",
            "    for (int64_t i = 0; i < a->n; i++) if ({d}_find(b, a->e[i].k, a->e[i].h) < 0) {d}_set(r, a->e[i].k, true);",
            "    return r;",
            "}}",
            "static {d} {k}_xor({d} a, {d} b) {{",
            "    {d} r = {k}_diff(a, b);",
            "    for (int64_t i = 0; i < b->n; i++) if ({d}_find(a, b->e[i].k, b->e[i].h) < 0) {d}_set(r, b->e[i].k, true);",
            "    return r;",
            "}}",
            "static void {k}_remove({d} s, {ce} x, int line) {{",
            "    if (SIP_UNLIKELY(!{d}_discard(s, x))) {{",
            "        sip_sb b = sip_sb_new();",
            "        {repr_call(el, '&b', 'x')}",
            "        sip_raise(SIP_E_KeyError, sip_sb_done(&b), line);",
            "    }}",
            "}}"])
        Gen("", ps, im)

    # ---------- T? ----------

    fn gen_opt(k str, t Ty) Gen
        inner = t.a[0]
        ce = ctype(t)
        ci = ctype(inner)
        has = opt_has(t, "a")
        val = opt_val(t, "a")
        hb = opt_has(t, "b")
        vb = opt_val(t, "b")
        ps = ["static bool eq_{k}({ce} a, {ce} b);", "static void repr_{k}(sip_sb *b, {ce} a);",
              "static void str_{k}(sip_sb *b, {ce} a);",
              "static inline {ci} unwrap_{k}({ce} a, int line);"]
        im = ["static bool eq_{k}({ce} a, {ce} b) {{ if (!{has} || !{hb}) return {has} == {hb}; " +
              "return {eq_expr(inner, val, vb)}; }}",
              "static void repr_{k}(sip_sb *b, {ce} a) {{ if (!{has}) sip_sb_put(b, \"None\", 4); " +
              "else {repr_call(inner, 'b', val)} }}",
              "static void str_{k}(sip_sb *b, {ce} a) {{ if (!{has}) sip_sb_put(b, \"None\", 4); " +
              "else {fmt_call(inner, 'b', val)} }}",
              "static inline {ci} unwrap_{k}({ce} a, int line) {{ if (SIP_UNLIKELY(!{has})) " +
              "sip_raise(SIP_E_NilError, SIP_LIT(\"value is nil\"), line); return {val}; }}"]
        Gen("", ps, "\n".join(im))

    # ---------- функции-значения ----------

    fn gen_fn(k str, t Ty) Gen
        ps = ["static bool eq_{k}({k} a, {k} b);", "static void repr_{k}(sip_sb *b, {k} a);"]
        im = ("static bool eq_{k}({k} a, {k} b) {{ return a.fn == b.fn && a.env == b.env; }}\n" +
             "static void repr_{k}(sip_sb *b, {k} a) {{ (void)a; sip_sb_put(b, \"<fn>\", 4); }}")
        Gen("", ps, im)

    # ---------- задачи ----------

    fn gen_task(k str, t Ty) Gen
        ft = key(fn_t([], t.a[0]))
        unit = is_p(t.a[0], UNIT)
        rt = ctype(t.a[0])
        body = "struct {k}_s {{ sip_task base; {ft} fn;{if unit then '' else ' ' + rt + ' result;'} }};"
        ps = ["static {k} {k}_new({ft} fn);", "static {rt} {k}_await({k} t, int line);",
              "static bool eq_{k}({k} a, {k} b);", "static void repr_{k}(sip_sb *b, {k} t);"]
        run = if unit then "t->fn.fn(t->fn.env);" else "t->result = t->fn.fn(t->fn.env);"
        im = ("static void {k}_run(sip_task *b) {{ {k} t = ({k})b; {run} }}\n" +
             "static {k} {k}_new({ft} fn) {{ {k} t = sip_alloc(sizeof *t); memset(t, 0, sizeof *t); " +
             "t->base.run = {k}_run; t->fn = fn; return t; }}\n" +
             "static {rt} {k}_await({k} t, int line) {{ sip_task_await(&t->base, line);" +
             "{if unit then '' else ' return t->result;'} }}\n" +
             "static bool eq_{k}({k} a, {k} b) {{ return a == b; }}\n" +
             "static void repr_{k}(sip_sb *b, {k} t) {{ (void)t; sip_sb_put(b, \"<task>\", 6); }}")
        Gen(body, ps, im)

    fn gen_iface(k str, t Ty) Gen
        slots: [str] = []
        for mname in t.imethods
            sig = t.imethods[mname]
            args = ", ".join(["void *"] + [ctype(p.ty) for p in sig.params])
            slots.append("{ctype(sig.ret)} (*m_{mname})({args});")
        slots.append("void (*repr)(sip_sb *, void *);")
        body = "struct {k}_vt {{ {' '.join(slots)} }};"
        ps = ["static bool eq_{k}({k} a, {k} b);", "static void repr_{k}(sip_sb *b, {k} v);"]
        im = ("static bool eq_{k}({k} a, {k} b) {{ return a.o == b.o; }}\n" +
             "static void repr_{k}(sip_sb *b, {k} v) {{ v.vt->repr(b, v.o); }}")
        Gen(body, ps, im)

    # ---------- записи ----------

    fn gen_record(k str, t Ty) Gen
        fs = fields_of(t)
        fj = " ".join(["{ctype(fs[fname])} f_{fname};" for fname in fs])
        fields = if fj == "" then "char _unused;" else fj
        body = "struct {k}_s {{ {fields} }};"
        pj = ", ".join(["{ctype(fs[fname])} f_{fname}" for fname in fs])
        params = if pj == "" then "void" else pj
        assigns = " ".join(["r->f_{fname} = f_{fname};" for fname in fs])
        ej = " && ".join([eq_expr(fs[fname], "a->f_{fname}", "b->f_{fname}") for fname in fs])
        eq = if ej == "" then "true" else ej
        dn = disp(t)
        rep = ["sip_sb_put(b, \"{dn}(\", {len(dn) + 1});"]
        names = [fname for fname in fs]
        if t.name == "sip_Response"  # <Response 200 https://...>
            names = []
            rep = ["sip_sb_put(b, \"<Response \", 10); str_int(b, r->f_status); sip_sb_putc(b, ' '); " +
                   "sip_sb_str(b, r->f_url); sip_sb_putc(b, '>'); return;"]
        for i, fname in enumerate(names)
            prefix = (if i > 0 then ", " else "") + fname + "="
            rep.append("sip_sb_put(b, \"{prefix}\", {len(prefix)});")
            rep.append(repr_call(fs[fname], "b", "r->f_{fname}"))
        rep.append("sip_sb_putc(b, ')');")
        ps = ["static {k} {k}_new({params});", "static bool eq_{k}({k} a, {k} b);",
              "static void repr_{k}(sip_sb *b, {k} r);"]
        im = ("static {k} {k}_new({params}) {{ {k} r = sip_alloc(sizeof *r); {assigns} return r; }}\n" +
             "static bool eq_{k}({k} a, {k} b) {{ return a == b || ({eq}); }}\n" +
             "static void repr_{k}(sip_sb *b, {k} r) {{ {' '.join(rep)} }}")
        Gen(body, ps, im)

    # ---------- типы-суммы ----------

    fn gen_sum(k str, t Ty) Gen
        vs = variants_of(t)
        members: [str] = []
        for vname in vs
            fields = vs[vname]
            if fields
                fs = " ".join(["{ctype(f.ty)} f_{f.name};" for f in fields])
                members.append("struct {{ {fs} }} {vname};")
        union = if members then " union {{ " + " ".join(members) + " }} u;" else ""
        body = "struct {k}_s {{ int tag;{union} }};"
        ps: [str] = []
        im: [str] = []
        eq_cases: [str] = []
        rep_cases: [str] = []
        for idx, vname in enumerate([v for v in vs])
            fields = vs[vname]
            pj = ", ".join(["{ctype(f.ty)} f_{f.name}" for f in fields])
            params = if pj == "" then "void" else pj
            ps.append("static {k} {k}_new_{vname}({params});")
            if fields
                assigns = " ".join(["r->u.{vname}.f_{f.name} = f_{f.name};" for f in fields])
                im.append("static {k} {k}_new_{vname}({params}) {{ {k} r = sip_alloc(sizeof *r); " +
                          "r->tag = {idx}; {assigns} return r; }}")
            else
                im.append("static {k} {k}_new_{vname}(void) {{ static {k} r; if (!r) {{ " +
                          "r = sip_alloc(sizeof *r); r->tag = {idx}; }} return r; }}")
            ej = " && ".join([eq_expr(f.ty, "a->u.{vname}.f_{f.name}", "b->u.{vname}.f_{f.name}") for f in fields])
            eq = if ej == "" then "true" else ej
            eq_cases.append("case {idx}: return {eq};")
            dn = vdisp(t, vname)
            rep = ["sip_sb_put(b, \"{dn}(\", {len(dn) + 1});"]
            for i, f in enumerate(fields)
                prefix = (if i > 0 then ", " else "") + f.name + "="
                rep.append("sip_sb_put(b, \"{prefix}\", {len(prefix)});")
                rep.append(repr_call(f.ty, "b", "r->u.{vname}.f_{f.name}"))
            rep.append("sip_sb_putc(b, ')'); return;")
            rep_cases.append("case {idx}: " + " ".join(rep))
        ps.extend(["static bool eq_{k}({k} a, {k} b);", "static void repr_{k}(sip_sb *b, {k} r);"])
        im.append("static bool eq_{k}({k} a, {k} b) {{ if (a == b) return true; if (a->tag != b->tag) " +
                  "return false; switch (a->tag) {{ " + " ".join(eq_cases) + " }} return false; }}")
        im.append("static void repr_{k}(sip_sb *b, {k} r) {{ switch (r->tag) {{ " + " ".join(rep_cases) + " }} }}")
        Gen(body, ps, "\n".join(im))
