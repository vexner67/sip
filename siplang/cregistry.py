"""Генерация C-типов и вспомогательных функций для каждого конкретного типа.

Списки, словари и кортежи мономорфизируются: для `[int]` и `[str]` получаются
разные структуры и разные функции. Значения хранятся без упаковки, и clang
может встроить и векторизовать работу с ними.
"""

from __future__ import annotations

from .types import (BOOL, FLOAT, INT, RANGE, STR, UNIT, DictT, FnT, IfaceT, ListT, OptT, Prim, RecordT, SetT, SumT, TaskT,
                    TupleT,
                    comparable, ctype, deep, hashable, is_ref, key, no_ptrs)


def show_t(t) -> str:
    from .types import show
    return show(t)


def json_key(name: str) -> str:
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


def fmt_call(t, sb: str, val: str) -> str:
    """Оператор C, который дописывает str(val) в построитель строк sb."""
    t = deep(t)
    if t is STR:
        return f"sip_sb_str({sb}, {val});"
    if isinstance(t, Prim):
        return f"str_{t.name}({sb}, {val});"
    if isinstance(t, OptT):
        return f"str_{key(t)}({sb}, {val});"
    return f"repr_{key(t)}({sb}, {val});"


def opt_has(t, code: str) -> str:
    """Условие «значение T? не nil»."""
    return f"({code} != NULL)" if is_ref(deep(t).inner) else f"({code}).has"


def opt_val(t, code: str) -> str:
    """Значение T? без проверки (проверку сделали раньше)."""
    return code if is_ref(deep(t).inner) else f"({code}).v"


def nil_code(t) -> str:
    t = deep(t)
    return "NULL" if is_ref(t.inner) else f"(({ctype(t)}){{0}})"


def repr_call(t, sb: str, val: str) -> str:
    t = deep(t)
    if isinstance(t, Prim):
        return f"repr_{t.name}({sb}, {val});"
    return f"repr_{key(t)}({sb}, {val});"


def eq_expr(t, a: str, b: str) -> str:
    t = deep(t)
    if t in (INT, FLOAT, BOOL):
        return f"({a} == {b})"
    return f"eq_{key(t)}({a}, {b})"


def cmp_fn(t) -> str:
    return f"cmp_{key(deep(t))}"


def hash_fn(t) -> str:
    return f"hash_{key(deep(t))}"


def msort(name: str, ce: str, less: str) -> str:
    """Устойчивая сортировка слиянием. less — выражение от {X} и {Y}: X строго раньше Y."""

    def L(x, y):
        return "(" + less.replace("{X}", x).replace("{Y}", y) + ")"

    return f"""static void {name}_rec({ce} *a, {ce} *tmp, int64_t n, bool rev) {{
    if (n <= 16) {{
        for (int64_t i = 1; i < n; i++) {{
            {ce} v = a[i];
            int64_t j = i;
            while (j > 0 && {L("v", "a[j - 1]")}) {{ a[j] = a[j - 1]; j--; }}
            a[j] = v;
        }}
        return;
    }}
    int64_t m = n / 2;
    {name}_rec(a, tmp, m, rev);
    {name}_rec(a + m, tmp, n - m, rev);
    if (!{L("a[m]", "a[m - 1]")}) return;
    memcpy(tmp, a, (size_t)m * sizeof({ce}));
    int64_t i = 0, j = m, k = 0;
    while (i < m && j < n) {{
        if ({L("a[j]", "tmp[i]")}) a[k++] = a[j++]; else a[k++] = tmp[i++];
    }}
    while (i < m) a[k++] = tmp[i++];
}}
static void {name}({ce} *a, int64_t n, bool rev) {{
    if (n < 2) return;
    {ce} *tmp = malloc((size_t)n * sizeof({ce}));
    {name}_rec(a, tmp, n, rev);
    free(tmp);
}}
"""


class JsonTypeError(Exception):
    """Тип нельзя перевести в JSON или прочитать из JSON."""


def _clit(s: str) -> str:
    """Строка Python -> литерал C и его длина в байтах."""
    raw = s.encode()
    out = "".join(chr(b) if 32 <= b < 127 and chr(b) not in '"\\?' else f"\\{b:03o}" for b in raw)
    return f'"{out}", {len(raw)}'


class Registry:
    def __init__(self):
        self.types: dict = {}   # ключ -> тип
        self.order: list = []   # ключи в порядке зависимостей
        self.jfuncs: dict = {}  # имя функции JSON -> (прототип, тело)
        self.const_code = None  # cgen: литерал по умолчанию -> код C (или None)

    def need(self, t) -> str:
        t = deep(t)
        if isinstance(t, Prim):
            return t.name
        k = key(t)
        if k in self.types:
            return k
        self.types[k] = t
        if isinstance(t, ListT):
            self.need(t.elem)
        elif isinstance(t, DictT):
            self.need(t.key)
            self.need(t.val)
            self.need(ListT(t.key))
            self.need(ListT(t.val))
            self.need(ListT(TupleT([t.key, t.val])))
        elif isinstance(t, TupleT):
            for i in t.items:
                self.need(i)
        elif isinstance(t, RecordT):
            for ft in t.fields.values():
                self.need(ft)
        elif isinstance(t, SumT):
            for fields in t.variants.values():
                for _, ft in fields:
                    self.need(ft)
        elif isinstance(t, OptT):
            self.need(t.inner)
        elif isinstance(t, SetT):
            self.need(DictT(t.elem, BOOL))
        elif isinstance(t, FnT):
            for pt in t.params:
                self.need(pt)
            self.need(t.ret)
        elif isinstance(t, TaskT):
            self.need(FnT([], t.ret))
        elif isinstance(t, IfaceT):
            for ps, ret in t.methods.values():
                for _, pt in ps:
                    self.need(pt)
                self.need(ret)
        self.order.append(k)
        return k

    # ---------- сборка ----------

    def code(self) -> str:
        fwd, tuples, bodies, protos, impls = [], [], [], [], []
        for k in self.order:
            t = self.types[k]
            if isinstance(t, (ListT, DictT, RecordT, SumT, TaskT)):
                fwd.append(f"typedef struct {k}_s *{k};")
        for k in self.order:
            # значения по месту: кортежи, T? для не-ссылочных T, замыкания — в порядке зависимостей
            t = self.types[k]
            if isinstance(t, TupleT):
                fields = " ".join(f"{ctype(it)} f{i};" for i, it in enumerate(t.items))
                tuples.append(f"typedef struct {{ {fields} }} {k};")
            elif isinstance(t, OptT) and not is_ref(t.inner):
                tuples.append(f"typedef struct {{ bool has; {ctype(t.inner)} v; }} {k};")
            elif isinstance(t, FnT):
                ps = ", ".join(["void *"] + [ctype(p) for p in t.params])
                tuples.append(f"typedef struct {{ {ctype(t.ret)} (*fn)({ps}); void *env; }} {k};")
            elif isinstance(t, IfaceT):
                # значение интерфейса: объект и таблица его методов
                tuples.append(f"struct {k}_vt;")
                tuples.append(f"typedef struct {{ void *o; const struct {k}_vt *vt; }} {k};")
        for k in self.order:
            t = self.types[k]
            gen = getattr(self, "gen_" + type(t).__name__)
            body, ps, im = gen(k, t)
            if body:
                bodies.append(body)
            protos += ps
            impls.append(im)
        jp = [v[0] for v in self.jfuncs.values()]
        ji = [v[1] for v in self.jfuncs.values()]
        return "\n".join(["/* ---- типы ---- */", *fwd, *tuples, *bodies,
                          "/* ---- вспомогательные функции ---- */", *protos, *impls, *jp, *ji])

    # ---------- JSON ----------

    def jparse(self, t) -> str:
        """Имя функции C: sip_str -> значение типа t (весь текст — одно значение JSON)."""
        t = deep(t)
        dec = self.jdec(t)
        name = f"jparse_{self.need(t)}"
        if name not in self.jfuncs:
            ct = ctype(t)
            sig = f"static {ct} {name}(sip_str s, int line)"
            self.jfuncs[name] = (sig + ";", sig + f" {{ sip_jp jp = sip_jp_new(s, line); sip_jp *p = &jp; "
                                             f"{ct} v = {dec}; sip_jp_end(p); return v; }}")
        return name

    def jdump(self, t) -> str:
        """Имя функции C: (значение, отступ или -1) -> строка JSON."""
        t = deep(t)
        enc = self.jenc(t, "v", "0")
        name = f"jdump_{self.need(t)}"
        if name not in self.jfuncs:
            sig = f"static sip_str {name}({ctype(t)} v, int64_t ind)"
            self.jfuncs[name] = (sig + ";", sig + f" {{ sip_sb sb = sip_sb_new(); sip_sb *b = &sb; {enc} "
                                             f"return sip_sb_done(b); }}")
        return name

    # ---------- CSV ----------

    CSV_SCALAR = None

    def csv_cell(self, t, target: str, i: str, col: str, dflt=None) -> str:
        """Оператор C: target = ячейка i, переведённая в t (col — имя колонки для ошибок)."""
        t = deep(t)
        conv = {STR: "sip_csv_cell(c, {i})", INT: "sip_csv_int(c, {i}, {col})", FLOAT: "sip_csv_float(c, {i}, {col})",
                BOOL: "sip_csv_bool(c, {i}, {col})"}
        if isinstance(t, OptT):
            inner = deep(t.inner)
            if inner not in conv:
                raise JsonTypeError(f"CSV cells cannot hold {show_t(t)}")
            self.need(t)
            got = conv[inner].format(i=i, col=col)
            return (f"if (sip_csv_cell(c, {i}).n == 0) {target} = ({key(t)}){{0}}; "
                    f"else {target} = ({key(t)}){{true, {got}}};")
        if t not in conv:
            raise JsonTypeError(f"CSV cells cannot hold {show_t(t)}")
        code = f"{target} = {conv[t].format(i=i, col=col)};"
        if dflt is not None and t is not STR:
            return f"if (sip_csv_cell(c, {i}).n == 0) {self.const_code(dflt, target)} else {code}"
        return code

    def csvread(self, t) -> str:
        """Имя функции C: (текст, разделитель, строка) -> значение типа t."""
        t = deep(t)
        if not isinstance(t, ListT):
            raise JsonTypeError(f"CSV is read as a list of rows, not {show_t(t)}")
        k = self.need(t)
        name = f"csvread_{k}"
        if name in self.jfuncs:
            return name
        row = deep(t.elem)
        rk = self.need(row)
        head = [f"    sip_csv cv = sip_csv_new(text, delim, line); sip_csv *c = &cv;", f"    {k} out = {k}_new(0);"]
        if isinstance(row, ListT):
            ce = ctype(row.elem)
            body = head + ["    while (sip_csv_row(c)) {", f"        {rk} r = {rk}_new(c->nf);",
                           "        for (int64_t j = 0; j < c->nf; j++) {", f"            {ce} v;",
                           "            " + self.csv_cell(row.elem, "v", "j", "(sip_str){\"\", 0}"),
                           f"            {rk}_push(r, v);", "        }", f"        {k}_push(out, r);", "    }"]
        elif isinstance(row, DictT):
            if deep(row.key) is not STR:
                raise JsonTypeError(f"CSV rows as dicts need str keys, not {show_t(row)}")
            cv = ctype(row.val)
            body = head + ["    if (!sip_csv_row(c)) return out;",
                           "    sip_str *hdr = sip_csv_header(c); int64_t nh = c->nf;",
                           "    while (sip_csv_row(c)) {", "        if (c->nf == 0) continue;",
                           f"        {rk} r = {rk}_new();",
                           "        for (int64_t j = 0; j < nh; j++) {", f"            {cv} v;",
                           "            " + self.csv_cell(row.val, "v", "j", "hdr[j]"),
                           f"            {rk}_set(r, hdr[j], v);", "        }", f"        {k}_push(out, r);", "    }"]
        elif isinstance(row, RecordT):
            dn = getattr(row, "display", row.name)
            defaults = getattr(row, "cdefaults", {})
            body = head + ["    if (!sip_csv_row(c)) return out;",
                           "    sip_str *hdr = sip_csv_header(c); int64_t nh = c->nf;"]
            for fn, ft in row.fields.items():
                body.append(f"    int64_t ix_{fn} = sip_csv_col(hdr, nh, (sip_str){{{_clit(fn)}}});")
                if not isinstance(deep(ft), OptT) and fn not in defaults:
                    msg = f"CSV has no column '{fn}' (needed for {dn})".replace('"', '\\"')
                    body.append(f'    if (ix_{fn} < 0) sip_raise(SIP_E_ParseError, SIP_LIT("{msg}"), line);')
            body += ["    while (sip_csv_row(c)) {", "        if (c->nf == 0) continue;"]
            for fn, ft in row.fields.items():
                body.append(f"        {ctype(ft)} jf_{fn};")
                cell = self.csv_cell(ft, f"jf_{fn}", f"ix_{fn}", f"(sip_str){{{_clit(fn)}}}", defaults.get(fn))
                if fn in defaults:
                    body.append(f"        if (ix_{fn} < 0) {self.const_code(defaults[fn], f'jf_{fn}')} else {cell}")
                else:
                    body.append(f"        {cell}")
            args = ", ".join(f"jf_{fn}" for fn in row.fields)
            body += [f"        {k}_push(out, {rk}_new({args}));", "    }"]
        else:
            raise JsonTypeError(f"CSV rows are read as [str], {{str: str}} or a record, not {show_t(row)}")
        sig = f"static {k} {name}(sip_str text, sip_str delim, int line)"
        self.jfuncs[name] = (sig + ";", sig + " {\n" + "\n".join(body + ["    return out;"]) + "\n}")
        return name

    def csv_put(self, t, val: str) -> str:
        """Оператор C: дописать ячейку со значением val в sip_sb *b (разделитель dch)."""
        t = deep(t)
        if isinstance(t, OptT):
            return f"if ({opt_has(t, val)}) {{ {self.csv_put(t.inner, opt_val(t, val))} }}"
        if t is STR:
            return f"sip_csv_put(b, {val}, dch);"
        if isinstance(t, FnT):
            raise JsonTypeError(f"CSV cells cannot hold {show_t(t)}")
        self.need(t)
        return f"{{ sip_sb tb = sip_sb_new(); {fmt_call(t, '&tb', val)} sip_csv_put(b, sip_sb_done(&tb), dch); }}"

    def csvdump(self, t) -> str:
        """Имя функции C: (строки, разделитель, строка) -> текст CSV."""
        t = deep(t)
        if not isinstance(t, ListT):
            raise JsonTypeError(f"CSV is written from a list of rows, not {show_t(t)}")
        k = self.need(t)
        name = f"csvdump_{k}"
        if name in self.jfuncs:
            return name
        row = deep(t.elem)
        rk = self.need(row)
        body = ["    char dch = sip_csv_delim(delim, line);", "    sip_sb sb = sip_sb_new(); sip_sb *b = &sb;"]
        sep = "if (j) sip_sb_putc(b, dch);"
        if isinstance(row, ListT):
            body += ["    for (int64_t i = 0; i < rows->n; i++) {", f"        {rk} r = rows->d[i];",
                     f"        for (int64_t j = 0; j < r->n; j++) {{ {sep} {self.csv_put(row.elem, 'r->d[j]')} }}",
                     '        sip_sb_put(b, "\\r\\n", 2);', "    }"]
        elif isinstance(row, TupleT):
            cells = " sip_sb_putc(b, dch); ".join(self.csv_put(it, f"r.f{j}") for j, it in enumerate(row.items))
            body += ["    for (int64_t i = 0; i < rows->n; i++) {", f"        {rk} r = rows->d[i];",
                     f"        {cells}", '        sip_sb_put(b, "\\r\\n", 2);', "    }"]
        elif isinstance(row, RecordT):
            names = list(row.fields)
            hdr = " sip_sb_putc(b, dch); ".join(f"sip_csv_put(b, (sip_str){{{_clit(fn)}}}, dch);" for fn in names)
            cells = " sip_sb_putc(b, dch); ".join(self.csv_put(ft, f"r->f_{fn}") for fn, ft in row.fields.items())
            body += [f"    {hdr}", '    sip_sb_put(b, "\\r\\n", 2);',
                     "    for (int64_t i = 0; i < rows->n; i++) {", f"        {rk} r = rows->d[i];",
                     f"        {cells}", '        sip_sb_put(b, "\\r\\n", 2);', "    }"]
        elif isinstance(row, DictT):
            if deep(row.key) is not STR:
                raise JsonTypeError(f"CSV rows as dicts need str keys, not {show_t(row)}")
            body += ["    if (rows->n == 0) return sip_sb_done(b);", f"    {rk} h = rows->d[0];",
                     f"    for (int64_t j = 0; j < h->n; j++) {{ {sep} sip_csv_put(b, h->e[j].k, dch); }}",
                     '    sip_sb_put(b, "\\r\\n", 2);',
                     "    for (int64_t i = 0; i < rows->n; i++) {", f"        {rk} r = rows->d[i];",
                     f"        for (int64_t j = 0; j < h->n; j++) {{ {sep} "
                     f"if ({rk}_contains(r, h->e[j].k)) {{ {self.csv_put(row.val, f'{rk}_get(r, h->e[j].k, line)')} }} }}",
                     '        sip_sb_put(b, "\\r\\n", 2);', "    }"]
        else:
            raise JsonTypeError(f"CSV rows are written from lists, tuples, dicts or records, not {show_t(row)}")
        sig = f"static sip_str {name}({k} rows, sip_str delim, int line)"
        self.jfuncs[name] = (sig + ";", sig + " {\n" + "\n".join(body + ["    return sip_sb_done(b);"]) + "\n}")
        return name

    def http_wrap(self, rt) -> str:
        k = self.need(rt)
        d = self.need(DictT(STR, STR))
        name = "sip_http_wrap"
        if name not in self.jfuncs:
            sig = f"static {k} {name}(sip_http_resp r)"
            self.jfuncs[name] = (sig + ";", sig + f" {{ {d} h = {d}_new(); "
                                 f"for (int64_t i = 0; i < r.nh; i++) {d}_set(h, r.hk[i], r.hv[i]); "
                                 f"return {k}_new(r.status, r.status >= 200 && r.status < 300, r.body, r.url, h); }}")
        return name

    def jdec(self, t) -> str:
        """Выражение C, которое читает значение типа t из sip_jp *p."""
        t = deep(t)
        prim = {INT: "sip_jp_int(p)", FLOAT: "sip_jp_float(p)", BOOL: "sip_jp_bool(p)", STR: "sip_jp_str(p)"}
        if t in prim:
            return prim[t]
        if isinstance(t, Prim) or isinstance(t, FnT):
            raise JsonTypeError(f"{show_t(t)} cannot be read from JSON")
        k = self.need(t)
        name = f"jdec_{k}"
        if name not in self.jfuncs:
            ct = ctype(t)
            self.jfuncs[name] = (f"static {ct} {name}(sip_jp *p);", "")
            self.jfuncs[name] = (self.jfuncs[name][0], f"static {ct} {name}(sip_jp *p) {{\n{self.jdec_body(k, t)}\n}}")
        return f"{name}(p)"

    def jdec_fields(self, fields, what) -> tuple:
        """Чтение полей объекта: (код, имена переменных)."""
        lines = []
        for fn, ft, _ in fields:
            lines.append(f"    {ctype(ft)} jf_{fn} = ({ctype(ft)}){{0}}; bool js_{fn} = false;")
        lines.append("    sip_str k;")
        lines.append("    for (int64_t i = 0; sip_jp_obj_next(p, i, &k); i++) {")
        lines.append("        int64_t m = sip_jp_path_key(p, k);")
        for i, (fn, ft, _) in enumerate(fields):
            lines.append(f"        {'else ' if i else ''}if (sip_str_is(k, {_clit(fn)})) "
                         f"{{ jf_{fn} = {self.jdec(ft)}; js_{fn} = true; }}")
        lines.append(f"        {'else ' if fields else ''}sip_jp_skip(p);")
        lines.append("        p->path.n = m;")
        lines.append("    }")
        for fn, ft, dflt in fields:
            if isinstance(deep(ft), OptT):
                continue
            if dflt is not None:
                lines.append(f"    if (!js_{fn}) {self.const_code(dflt, f'jf_{fn}')}")
            else:
                msg = f"missing field '{fn}'".replace('"', '\\"')
                lines.append(f'    if (!js_{fn}) sip_jp_fail(p, "{msg}");')
        return lines, ", ".join(f"jf_{fn}" for fn, _, _ in fields)

    def jdec_body(self, k, t) -> str:
        if isinstance(t, ListT):
            return (f'    sip_jp_want(p, \'[\', "list");\n    {k} l = {k}_new(0);\n'
                    f"    for (int64_t i = 0; sip_jp_arr_next(p, i); i++) {{\n"
                    f"        int64_t m = sip_jp_path_idx(p, i);\n        {k}_push(l, {self.jdec(t.elem)});\n"
                    f"        p->path.n = m;\n    }}\n    return l;")
        if isinstance(t, SetT):
            d = ctype(t)
            return (f'    sip_jp_want(p, \'[\', "list");\n    {d} s = {d}_new();\n'
                    f"    for (int64_t i = 0; sip_jp_arr_next(p, i); i++) {{\n"
                    f"        int64_t m = sip_jp_path_idx(p, i);\n        {d}_set(s, {self.jdec(t.elem)}, true);\n"
                    f"        p->path.n = m;\n    }}\n    return s;")
        if isinstance(t, DictT):
            kt = deep(t.key)
            if kt is STR:
                kc = "k"
            elif kt is INT:
                kc = "sip_jp_key_int(p, k)"
            else:
                raise JsonTypeError(f"{show_t(t)} cannot be read from JSON: keys must be str or int")
            return (f'    sip_jp_want(p, \'{{\', "dict");\n    {k} d = {k}_new();\n    sip_str k;\n'
                    f"    for (int64_t i = 0; sip_jp_obj_next(p, i, &k); i++) {{\n"
                    f"        int64_t m = sip_jp_path_key(p, k);\n        {ctype(kt)} key = {kc};\n"
                    f"        {k}_set(d, key, {self.jdec(t.val)});\n"
                    f"        p->path.n = m;\n    }}\n    return d;")
        if isinstance(t, OptT):
            inner = self.jdec(t.inner)
            if is_ref(t.inner):
                return f"    if (sip_jp_null(p)) return NULL;\n    return {inner};"
            return f"    if (sip_jp_null(p)) return ({k}){{0}};\n    return ({k}){{true, {inner}}};"
        if isinstance(t, TupleT):
            n = len(t.items)
            lines = [f'    sip_jp_want(p, \'[\', "list");', f"    {k} r;", "    int64_t m;"]
            for i, it in enumerate(t.items):
                lines.append(f'    if (!sip_jp_arr_next(p, {i})) sip_jp_fail(p, "expected a list of {n} items");')
                lines.append(f"    m = sip_jp_path_idx(p, {i}); r.f{i} = {self.jdec(it)}; p->path.n = m;")
            lines.append(f'    if (sip_jp_arr_next(p, {n})) sip_jp_fail(p, "expected a list of {n} items");')
            lines.append("    return r;")
            return "\n".join(lines)
        if isinstance(t, RecordT):
            fields = [(fn, ft, getattr(t, "cdefaults", {}).get(fn)) for fn, ft in t.fields.items()]
            lines, args = self.jdec_fields(fields, getattr(t, "display", t.name))
            return "\n".join([f'    sip_jp_want(p, \'{{\', "object");', *lines, f"    return {k}_new({args});"])
        if isinstance(t, SumT):
            lines = ["    sip_str tag = sip_jp_tag(p);"]
            for vname, fields in t.variants.items():
                dn = getattr(t, "vdisplay", {}).get(vname, vname)
                fl = [(fn, ft, None) for fn, ft in fields]
                body, args = self.jdec_fields(fl, dn)
                lines.append(f"    if (sip_str_is(tag, {_clit(dn)})) {{")
                lines.append(f'        sip_jp_want(p, \'{{\', "object");')
                lines += ["    " + x for x in body]
                lines.append(f"        return {k}_new_{vname}({args});")
                lines.append("    }")
            lines.append('    sip_jp_fail(p, "unknown \\"type\\"");')
            return "\n".join(lines)
        raise JsonTypeError(f"{show_t(t)} cannot be read from JSON")

    def jenc(self, t, v: str, d: str) -> str:
        """Оператор C: дописать JSON значения v в sip_sb *b (отступ ind, глубина d)."""
        t = deep(t)
        prim = {INT: "str_int", FLOAT: "sip_je_float", BOOL: "sip_je_bool", STR: "sip_je_str"}
        if t in prim:
            return f"{prim[t]}(b, {v});"
        if isinstance(t, Prim) or isinstance(t, FnT):
            raise JsonTypeError(f"{show_t(t)} cannot be converted to JSON")
        k = self.need(t)
        name = f"jenc_{k}"
        if name not in self.jfuncs:
            ct = ctype(t)
            sig = f"static void {name}(sip_sb *b, {ct} v, int64_t ind, int64_t d)"
            self.jfuncs[name] = (sig + ";", "")
            self.jfuncs[name] = (sig + ";", sig + " {\n" + self.jenc_body(k, t) + "\n}")
        return f"{name}(b, {v}, ind, {d});"

    def jenc_obj(self, items, tag=None) -> list:
        """Объект с полями [(имя, тип, выражение)]."""
        lines = ["    sip_sb_putc(b, '{');"]
        first = "true"
        if tag is not None:
            lines.append(f"    sip_je_sep(b, ind, d + 1, true); sip_sb_put(b, {_clit(chr(34) + 'type' + chr(34) + ': ')});"
                         f" sip_je_str(b, (sip_str){{{_clit(tag)}}});")
            first = "false"
        for fn, ft, ex in items:
            lines.append(f"    sip_je_sep(b, ind, d + 1, {first}); "
                         f"sip_sb_put(b, {_clit(json_key(fn) + ': ')}); {self.jenc(ft, ex, 'd + 1')}")
            first = "false"
        if items or tag is not None:
            lines.append("    sip_je_close(b, ind, d, '}');")
        else:
            lines.append("    sip_sb_putc(b, '}');")
        return lines

    def jenc_body(self, k, t) -> str:
        if isinstance(t, (ListT, SetT)):
            if isinstance(t, ListT):
                n, item = "v->n", "v->d[i]"
            else:
                n, item = "v->n", "v->e[i].k"
            return (f"    sip_sb_putc(b, '[');\n    for (int64_t i = 0; i < {n}; i++) {{\n"
                    f"        sip_je_sep(b, ind, d + 1, i == 0); {self.jenc(t.elem, item, 'd + 1')}\n    }}\n"
                    f"    if ({n}) sip_je_close(b, ind, d, ']'); else sip_sb_putc(b, ']');")
        if isinstance(t, TupleT):
            lines = ["    sip_sb_putc(b, '[');"]
            for i, it in enumerate(t.items):
                lines.append(f"    sip_je_sep(b, ind, d + 1, {'true' if i == 0 else 'false'}); "
                             + self.jenc(it, f"v.f{i}", "d + 1"))
            lines.append("    sip_je_close(b, ind, d, ']');" if t.items else "    sip_sb_putc(b, ']');")
            return "\n".join(lines)
        if isinstance(t, DictT):
            kt = deep(t.key)
            keyw = {STR: "sip_je_str(b, v->e[i].k);",
                    INT: "sip_sb_putc(b, '\"'); str_int(b, v->e[i].k); sip_sb_putc(b, '\"');",
                    FLOAT: "sip_sb_putc(b, '\"'); sip_je_float(b, v->e[i].k); sip_sb_putc(b, '\"');",
                    BOOL: "sip_sb_putc(b, '\"'); sip_je_bool(b, v->e[i].k); sip_sb_putc(b, '\"');"}.get(kt)
            if keyw is None:
                raise JsonTypeError(f"{show_t(t)} cannot be converted to JSON: keys must be str, int, float or bool")
            return (f"    sip_sb_putc(b, '{{');\n    for (int64_t i = 0; i < v->n; i++) {{\n"
                    f"        sip_je_sep(b, ind, d + 1, i == 0); {keyw} sip_sb_put(b, \": \", 2); "
                    f"{self.jenc(t.val, 'v->e[i].v', 'd + 1')}\n    }}\n"
                    f"    if (v->n) sip_je_close(b, ind, d, '}}'); else sip_sb_putc(b, '}}');")
        if isinstance(t, OptT):
            return (f"    if (!{opt_has(t, 'v')}) {{ sip_sb_put(b, \"null\", 4); return; }}\n"
                    f"    {self.jenc(t.inner, opt_val(t, 'v'), 'd')}")
        if isinstance(t, RecordT):
            return "\n".join(self.jenc_obj([(fn, ft, f"v->f_{fn}") for fn, ft in t.fields.items()]))
        if isinstance(t, SumT):
            lines = ["    switch (v->tag) {"]
            for idx, (vname, fields) in enumerate(t.variants.items()):
                dn = getattr(t, "vdisplay", {}).get(vname, vname)
                body = self.jenc_obj([(fn, ft, f"v->u.{vname}.f_{fn}") for fn, ft in fields], tag=dn)
                lines.append(f"    case {idx}: {{")
                lines += ["    " + x for x in body]
                lines.append("        return;\n    }")
            lines.append("    }")
            return "\n".join(lines)
        raise JsonTypeError(f"{show_t(t)} cannot be converted to JSON")

    # ---------- кортежи ----------

    def gen_TupleT(self, k, t):
        n = len(t.items)
        ps = [f"static bool eq_{k}({k} a, {k} b);", f"static void repr_{k}(sip_sb *b, {k} a);"]
        eq = " && ".join(eq_expr(it, f"a.f{i}", f"b.f{i}") for i, it in enumerate(t.items)) or "true"
        rep = []
        for i, it in enumerate(t.items):
            if i:
                rep.append('sip_sb_put(b, ", ", 2);')
            rep.append(repr_call(it, "b", f"a.f{i}"))
        if n == 1:
            rep.append("sip_sb_putc(b, ',');")
        im = [f"static bool eq_{k}({k} a, {k} b) {{ return {eq}; }}",
              f"static void repr_{k}(sip_sb *b, {k} a) {{ sip_sb_putc(b, '('); {' '.join(rep)} sip_sb_putc(b, ')'); }}"]
        if comparable(t):
            ps.append(f"static int cmp_{k}({k} a, {k} b);")
            steps = " ".join(f"if ((c = {cmp_fn(it)}(a.f{i}, b.f{i}))) return c;" for i, it in enumerate(t.items))
            im.append(f"static int cmp_{k}({k} a, {k} b) {{ int c; {steps} return 0; }}")
        if hashable(t):
            ps.append(f"static uint64_t hash_{k}({k} a);")
            mix = " ".join(f"h = sip_mix(h ^ {hash_fn(it)}(a.f{i}));" for i, it in enumerate(t.items))
            im.append(f"static uint64_t hash_{k}({k} a) {{ uint64_t h = 0x9e3779b97f4a7c15ULL; {mix} return h; }}")
        return "", ps, "\n".join(im)

    # ---------- списки ----------

    def gen_ListT(self, k, t):
        ce = ctype(t.elem)
        body = f"struct {k}_s {{ int64_t n, cap; {ce} *d; }};"
        names = ["new", "push", "ref", "get", "pop", "insert", "slice", "copy", "concat", "extend",
                 "repeat", "contains", "index", "count", "reverse", "join"]
        sigs = {
            "new": f"static {k} {k}_new(int64_t cap)",
            "push": f"static inline void {k}_push({k} l, {ce} x)",
            "ref": f"static inline {ce} *{k}_ref({k} l, int64_t i, int line)",
            "get": f"static inline {ce} {k}_get({k} l, int64_t i, int line)",
            "pop": f"static {ce} {k}_pop({k} l, int64_t i, bool has_i, int line)",
            "insert": f"static void {k}_insert({k} l, int64_t i, {ce} x)",
            "slice": f"static {k} {k}_slice({k} l, int64_t lo, int64_t hi, bool has_lo, bool has_hi)",
            "copy": f"static {k} {k}_copy({k} l)",
            "concat": f"static {k} {k}_concat({k} a, {k} b)",
            "extend": f"static void {k}_extend({k} a, {k} b)",
            "repeat": f"static {k} {k}_repeat({k} l, int64_t times, int line)",
            "contains": f"static bool {k}_contains({k} l, {ce} x)",
            "index": f"static int64_t {k}_index({k} l, {ce} x, int line)",
            "count": f"static int64_t {k}_count({k} l, {ce} x)",
            "reverse": f"static void {k}_reverse({k} l)",
            "join": f"static sip_str {k}_join({k} l, sip_str sep)",
        }
        eq = eq_expr(t.elem, "l->d[i]", "x")
        ra = "sip_realloc_atomic" if no_ptrs(t.elem) else "sip_realloc"  # числа сборщик не сканирует
        im = f"""{sigs['new']} {{
    {k} l = sip_alloc(sizeof *l);
    l->n = 0; l->cap = cap;
    l->d = cap ? {ra}(NULL, (size_t)cap * sizeof({ce})) : NULL;
    return l;
}}
{sigs['push']} {{
    if (SIP_UNLIKELY(l->n == l->cap)) {{
        l->cap = l->cap ? l->cap * 2 : 4;
        l->d = {ra}(l->d, (size_t)l->cap * sizeof({ce}));
    }}
    l->d[l->n++] = x;
}}
{sigs['ref']} {{
    if (i < 0) i += l->n;
    if (SIP_UNLIKELY((uint64_t)i >= (uint64_t)l->n)) sip_raise(SIP_E_IndexError, SIP_LIT("list index out of range"), line);
    return &l->d[i];
}}
{sigs['get']} {{ return *{k}_ref(l, i, line); }}
{sigs['pop']} {{
    if (SIP_UNLIKELY(l->n == 0)) sip_raise(SIP_E_IndexError, SIP_LIT("pop from empty list"), line);
    if (!has_i) return l->d[--l->n];
    {ce} *p = {k}_ref(l, i, line);
    int64_t j = p - l->d;
    {ce} x = *p;
    memmove(&l->d[j], &l->d[j + 1], (size_t)(l->n - j - 1) * sizeof({ce}));
    l->n--;
    return x;
}}
{sigs['insert']} {{
    if (i < 0) i += l->n;
    if (i < 0) i = 0;
    if (i > l->n) i = l->n;
    {k}_push(l, x);
    memmove(&l->d[i + 1], &l->d[i], (size_t)(l->n - 1 - i) * sizeof({ce}));
    l->d[i] = x;
}}
{sigs['slice']} {{
    sip_clamp(l->n, &lo, &hi, has_lo, has_hi);
    {k} r = {k}_new(hi - lo);
    if (hi > lo) memcpy(r->d, l->d + lo, (size_t)(hi - lo) * sizeof({ce}));
    r->n = hi - lo;
    return r;
}}
{sigs['copy']} {{ return {k}_slice(l, 0, 0, false, false); }}
{sigs['concat']} {{
    {k} r = {k}_new(a->n + b->n);
    if (a->n) memcpy(r->d, a->d, (size_t)a->n * sizeof({ce}));
    if (b->n) memcpy(r->d + a->n, b->d, (size_t)b->n * sizeof({ce}));
    r->n = a->n + b->n;
    return r;
}}
{sigs['extend']} {{ int64_t n = b->n; for (int64_t i = 0; i < n; i++) {k}_push(a, b->d[i]); }}
{sigs['repeat']} {{
    int64_t total = 0;
    if (times > 0 && (__builtin_mul_overflow(l->n, times, &total) || total > ((int64_t)1 << 40)))
        sip_raise(SIP_E_OverflowError, SIP_LIT("repeated list is too long"), line);
    {k} r = {k}_new(total);
    for (int64_t t = 0; t < times; t++) for (int64_t i = 0; i < l->n; i++) {k}_push(r, l->d[i]);
    return r;
}}
{sigs['contains']} {{ for (int64_t i = 0; i < l->n; i++) if ({eq}) return true; return false; }}
{sigs['index']} {{
    for (int64_t i = 0; i < l->n; i++) if ({eq}) return i;
    sip_raise(SIP_E_ValueError, SIP_LIT("value is not in list"), line);
}}
{sigs['count']} {{ int64_t c = 0; for (int64_t i = 0; i < l->n; i++) if ({eq}) c++; return c; }}
{sigs['reverse']} {{
    for (int64_t i = 0, j = l->n - 1; i < j; i++, j--) {{ {ce} x = l->d[i]; l->d[i] = l->d[j]; l->d[j] = x; }}
}}
{sigs['join']} {{
    sip_sb b = sip_sb_new();
    for (int64_t i = 0; i < l->n; i++) {{
        if (i) sip_sb_str(&b, sep);
        {fmt_call(t.elem, "&b", "l->d[i]")}
    }}
    return sip_sb_done(&b);
}}
static bool eq_{k}({k} a, {k} b) {{
    if (a == b) return true;
    if (a->n != b->n) return false;
    for (int64_t i = 0; i < a->n; i++) if (!{eq_expr(t.elem, "a->d[i]", "b->d[i]")}) return false;
    return true;
}}
static void repr_{k}(sip_sb *b, {k} l) {{
    sip_sb_putc(b, '[');
    for (int64_t i = 0; i < l->n; i++) {{
        if (i) sip_sb_put(b, ", ", 2);
        {repr_call(t.elem, "b", "l->d[i]")}
    }}
    sip_sb_putc(b, ']');
}}"""
        ps = [s + ";" for s in sigs.values()] + [
            f"static bool eq_{k}({k} a, {k} b);", f"static void repr_{k}(sip_sb *b, {k} l);"]
        if comparable(t.elem):
            cf = cmp_fn(t.elem)
            ps += [f"static void {k}_sort({k} l, bool rev);", f"static int cmp_{k}({k} a, {k} b);"]
            im += "\n" + msort(f"{k}_msort", ce, f"rev ? {cf}({{Y}}, {{X}}) < 0 : {cf}({{X}}, {{Y}}) < 0")
            im += f"""
static void {k}_sort({k} l, bool rev) {{ {k}_msort(l->d, l->n, rev); }}
static int cmp_{k}({k} a, {k} b) {{
    int64_t n = a->n < b->n ? a->n : b->n;
    for (int64_t i = 0; i < n; i++) {{ int c = {cf}(a->d[i], b->d[i]); if (c) return c; }}
    return (a->n > b->n) - (a->n < b->n);
}}"""
        return body, ps, im

    # ---------- словари ----------

    def gen_DictT(self, k, t):
        ck, cv = ctype(t.key), ctype(t.val)
        lk, lv, lt = key(ListT(t.key)), key(ListT(t.val)), key(ListT(TupleT([t.key, t.val])))
        tt = key(TupleT([t.key, t.val]))
        e = f"DE_{k}"
        body = (f"typedef struct {{ {ck} k; {cv} v; uint64_t h; }} {e};\n"
                f"struct {k}_s {{ int64_t n, cap, icap; {e} *e; int32_t *ix; }};")
        sigs = {
            "new": f"static {k} {k}_new(void)",
            "find": f"static inline int64_t {k}_find({k} d, {ck} key, uint64_t h)",
            "rehash": f"static void {k}_rehash({k} d, int64_t icap)",
            "slot": f"static {cv} *{k}_slot({k} d, {ck} key, {cv} dflt)",
            "set": f"static inline void {k}_set({k} d, {ck} key, {cv} v)",
            "ref": f"static {cv} *{k}_ref({k} d, {ck} key, int line)",
            "get": f"static inline {cv} {k}_get({k} d, {ck} key, int line)",
            "get_or": f"static inline {cv} {k}_get_or({k} d, {ck} key, {cv} dflt)",
            "contains": f"static inline bool {k}_contains({k} d, {ck} key)",
            "keys": f"static {lk} {k}_keys({k} d)",
            "values": f"static {lv} {k}_values({k} d)",
            "items": f"static {lt} {k}_items({k} d)",
            "copy": f"static {k} {k}_copy({k} d)",
            "merge": f"static {k} {k}_merge({k} a, {k} b)",
            "discard": f"static bool {k}_discard({k} d, {ck} key)",
            "pop": f"static {cv} {k}_pop({k} d, {ck} key, int line)",
        }
        ra = "sip_realloc_atomic" if no_ptrs(t.key) and no_ptrs(t.val) else "sip_realloc"
        im = f"""{sigs['new']} {{ {k} d = sip_alloc(sizeof *d); memset(d, 0, sizeof *d); return d; }}
{sigs['find']} {{
    if (SIP_UNLIKELY(!d->icap)) return -1;
    uint64_t m = (uint64_t)d->icap - 1;
    for (uint64_t i = h & m;; i = (i + 1) & m) {{
        int32_t j = d->ix[i];
        if (!j) return -1;
        {e} *en = &d->e[j - 1];
        if (en->h == h && {eq_expr(t.key, "en->k", "key")}) return j - 1;
    }}
}}
{sigs['rehash']} {{
    d->ix = sip_alloc_atomic((size_t)icap * sizeof(int32_t));
    memset(d->ix, 0, (size_t)icap * sizeof(int32_t));
    d->icap = icap;
    uint64_t m = (uint64_t)icap - 1;
    for (int64_t j = 0; j < d->n; j++) {{
        uint64_t i = d->e[j].h & m;
        while (d->ix[i]) i = (i + 1) & m;
        d->ix[i] = (int32_t)(j + 1);
    }}
}}
{sigs['slot']} {{
    uint64_t h = {hash_fn(t.key)}(key);
    int64_t j = {k}_find(d, key, h);
    if (j >= 0) return &d->e[j].v;
    if ((d->n + 1) * 4 > d->icap * 3) {k}_rehash(d, d->icap ? d->icap * 2 : 8);
    if (d->n == d->cap) {{
        d->cap = d->cap ? d->cap * 2 : 8;
        d->e = {ra}(d->e, (size_t)d->cap * sizeof({e}));
    }}
    d->e[d->n] = ({e}){{key, dflt, h}};
    uint64_t m = (uint64_t)d->icap - 1, i = h & m;
    while (d->ix[i]) i = (i + 1) & m;
    d->ix[i] = (int32_t)(d->n + 1);
    return &d->e[d->n++].v;
}}
{sigs['set']} {{ *{k}_slot(d, key, v) = v; }}
{sigs['ref']} {{
    int64_t j = {k}_find(d, key, {hash_fn(t.key)}(key));
    if (SIP_UNLIKELY(j < 0)) {{
        sip_sb b = sip_sb_new();
        {repr_call(t.key, "&b", "key")}
        sip_raise(SIP_E_KeyError, sip_sb_done(&b), line);
    }}
    return &d->e[j].v;
}}
{sigs['get']} {{ return *{k}_ref(d, key, line); }}
{sigs['get_or']} {{ int64_t j = {k}_find(d, key, {hash_fn(t.key)}(key)); return j >= 0 ? d->e[j].v : dflt; }}
{sigs['contains']} {{ return {k}_find(d, key, {hash_fn(t.key)}(key)) >= 0; }}
{sigs['keys']} {{ {lk} r = {lk}_new(d->n); for (int64_t j = 0; j < d->n; j++) r->d[j] = d->e[j].k; r->n = d->n; return r; }}
{sigs['values']} {{ {lv} r = {lv}_new(d->n); for (int64_t j = 0; j < d->n; j++) r->d[j] = d->e[j].v; r->n = d->n; return r; }}
{sigs['items']} {{
    {lt} r = {lt}_new(d->n);
    for (int64_t j = 0; j < d->n; j++) r->d[j] = ({tt}){{d->e[j].k, d->e[j].v}};
    r->n = d->n;
    return r;
}}
{sigs['copy']} {{ {k} r = {k}_new(); for (int64_t j = 0; j < d->n; j++) {k}_set(r, d->e[j].k, d->e[j].v); return r; }}
{sigs['merge']} {{ {k} r = {k}_copy(a); for (int64_t j = 0; j < b->n; j++) {k}_set(r, b->e[j].k, b->e[j].v); return r; }}
static bool eq_{k}({k} a, {k} b) {{
    if (a == b) return true;
    if (a->n != b->n) return false;
    for (int64_t j = 0; j < a->n; j++) {{
        int64_t i = {k}_find(b, a->e[j].k, a->e[j].h);
        if (i < 0 || !{eq_expr(t.val, "a->e[j].v", "b->e[i].v")}) return false;
    }}
    return true;
}}
static void repr_{k}(sip_sb *b, {k} d) {{
    sip_sb_putc(b, '{{');
    for (int64_t j = 0; j < d->n; j++) {{
        if (j) sip_sb_put(b, ", ", 2);
        {repr_call(t.key, "b", "d->e[j].k")}
        sip_sb_put(b, ": ", 2);
        {repr_call(t.val, "b", "d->e[j].v")}
    }}
    sip_sb_putc(b, '}}');
}}"""
        im += f"""
{sigs['discard']} {{
    int64_t j = {k}_find(d, key, {hash_fn(t.key)}(key));
    if (j < 0) return false;
    memmove(&d->e[j], &d->e[j + 1], (size_t)(d->n - j - 1) * sizeof({e}));
    d->n--;
    {k}_rehash(d, d->icap);
    return true;
}}
{sigs['pop']} {{
    int64_t j = {k}_find(d, key, {hash_fn(t.key)}(key));
    if (SIP_UNLIKELY(j < 0)) {{
        sip_sb b = sip_sb_new();
        {repr_call(t.key, "&b", "key")}
        sip_raise(SIP_E_KeyError, sip_sb_done(&b), line);
    }}
    {cv} v = d->e[j].v;
    {k}_discard(d, key);
    return v;
}}"""
        ps = [s + ";" for s in sigs.values()] + [
            f"static bool eq_{k}({k} a, {k} b);", f"static void repr_{k}(sip_sb *b, {k} d);"]
        if deep(t.val) is INT:
            ps += [f"static {k} {k}_count({lk} l);", f"static {lt} {k}_top({k} d, int64_t n, bool has_n);"]
            im += "\n" + msort(f"{k}_topsort", tt, "{X}.f1 > {Y}.f1")
            im += f"""
static {k} {k}_count({lk} l) {{
    {k} d = {k}_new();
    for (int64_t i = 0; i < l->n; i++) (*{k}_slot(d, l->d[i], 0))++;
    return d;
}}
static {lt} {k}_top({k} d, int64_t n, bool has_n) {{
    {lt} r = {k}_items(d);
    {k}_topsort(r->d, r->n, false);
    if (has_n && n >= 0 && n < r->n) r->n = n;
    return r;
}}"""
        return body, ps, im

    # ---------- множества ----------

    def gen_SetT(self, k, t):
        d = key(DictT(t.elem, BOOL))
        ce = ctype(t.elem)
        ps = [f"static bool eq_{k}({d} a, {d} b);", f"static void repr_{k}(sip_sb *b, {d} s);",
              f"static bool {k}_subset({d} a, {d} b);", f"static {d} {k}_union({d} a, {d} b);",
              f"static {d} {k}_inter({d} a, {d} b);", f"static {d} {k}_diff({d} a, {d} b);",
              f"static {d} {k}_xor({d} a, {d} b);", f"static void {k}_update({d} a, {d} b);",
              f"static void {k}_remove({d} s, {ce} x, int line);"]
        im = f"""static bool {k}_subset({d} a, {d} b) {{
    if (a->n > b->n) return false;
    for (int64_t i = 0; i < a->n; i++) if ({d}_find(b, a->e[i].k, a->e[i].h) < 0) return false;
    return true;
}}
static bool eq_{k}({d} a, {d} b) {{ return a->n == b->n && {k}_subset(a, b); }}
static void repr_{k}(sip_sb *b, {d} s) {{
    if (!s->n) {{ sip_sb_put(b, "set()", 5); return; }}
    sip_sb_putc(b, '{{');
    for (int64_t i = 0; i < s->n; i++) {{
        if (i) sip_sb_put(b, ", ", 2);
        {repr_call(t.elem, "b", "s->e[i].k")}
    }}
    sip_sb_putc(b, '}}');
}}
static void {k}_update({d} a, {d} b) {{ for (int64_t i = 0; i < b->n; i++) {d}_set(a, b->e[i].k, true); }}
static {d} {k}_union({d} a, {d} b) {{ {d} r = {d}_copy(a); {k}_update(r, b); return r; }}
static {d} {k}_inter({d} a, {d} b) {{
    {d} r = {d}_new();
    for (int64_t i = 0; i < a->n; i++) if ({d}_find(b, a->e[i].k, a->e[i].h) >= 0) {d}_set(r, a->e[i].k, true);
    return r;
}}
static {d} {k}_diff({d} a, {d} b) {{
    {d} r = {d}_new();
    for (int64_t i = 0; i < a->n; i++) if ({d}_find(b, a->e[i].k, a->e[i].h) < 0) {d}_set(r, a->e[i].k, true);
    return r;
}}
static {d} {k}_xor({d} a, {d} b) {{
    {d} r = {k}_diff(a, b);
    for (int64_t i = 0; i < b->n; i++) if ({d}_find(a, b->e[i].k, b->e[i].h) < 0) {d}_set(r, b->e[i].k, true);
    return r;
}}
static void {k}_remove({d} s, {ce} x, int line) {{
    if (SIP_UNLIKELY(!{d}_discard(s, x))) {{
        sip_sb b = sip_sb_new();
        {repr_call(t.elem, "&b", "x")}
        sip_raise(SIP_E_KeyError, sip_sb_done(&b), line);
    }}
}}"""
        return "", ps, im

    # ---------- T? ----------

    def gen_OptT(self, k, t):
        ce, ci = ctype(t), ctype(t.inner)
        has, val = opt_has(t, "a"), opt_val(t, "a")
        hb, vb = opt_has(t, "b"), opt_val(t, "b")
        ps = [f"static bool eq_{k}({ce} a, {ce} b);", f"static void repr_{k}(sip_sb *b, {ce} a);",
              f"static void str_{k}(sip_sb *b, {ce} a);",
              f"static inline {ci} unwrap_{k}({ce} a, int line);"]
        im = [f"static bool eq_{k}({ce} a, {ce} b) {{ if (!{has} || !{hb}) return {has} == {hb}; "
              f"return {eq_expr(t.inner, val, vb)}; }}",
              f'static void repr_{k}(sip_sb *b, {ce} a) {{ if (!{has}) sip_sb_put(b, "None", 4); '
              f'else {repr_call(t.inner, "b", val)} }}',
              f'static void str_{k}(sip_sb *b, {ce} a) {{ if (!{has}) sip_sb_put(b, "None", 4); '
              f'else {fmt_call(t.inner, "b", val)} }}',
              f"static inline {ci} unwrap_{k}({ce} a, int line) {{ if (SIP_UNLIKELY(!{has})) "
              f'sip_raise(SIP_E_NilError, SIP_LIT("value is nil"), line); return {val}; }}']
        return "", ps, "\n".join(im)

    # ---------- функции-значения ----------

    def gen_FnT(self, k, t):
        ps = [f"static bool eq_{k}({k} a, {k} b);", f"static void repr_{k}(sip_sb *b, {k} a);"]
        im = (f"static bool eq_{k}({k} a, {k} b) {{ return a.fn == b.fn && a.env == b.env; }}\n"
              f'static void repr_{k}(sip_sb *b, {k} a) {{ (void)a; sip_sb_put(b, "<fn>", 4); }}')
        return "", ps, im

    # ---------- записи ----------

    def gen_TaskT(self, k, t):
        ft = key(FnT([], t.ret))
        unit = deep(t.ret) is UNIT
        rt = ctype(t.ret)
        body = f"struct {k}_s {{ sip_task base; {ft} fn;{'' if unit else f' {rt} result;'} }};"
        ps = [f"static {k} {k}_new({ft} fn);", f"static {rt} {k}_await({k} t, int line);",
              f"static bool eq_{k}({k} a, {k} b);", f"static void repr_{k}(sip_sb *b, {k} t);"]
        run = "t->fn.fn(t->fn.env);" if unit else "t->result = t->fn.fn(t->fn.env);"
        im = (f"static void {k}_run(sip_task *b) {{ {k} t = ({k})b; {run} }}\n"
              f"static {k} {k}_new({ft} fn) {{ {k} t = sip_alloc(sizeof *t); memset(t, 0, sizeof *t); "
              f"t->base.run = {k}_run; t->fn = fn; return t; }}\n"
              f"static {rt} {k}_await({k} t, int line) {{ sip_task_await(&t->base, line);"
              f"{'' if unit else ' return t->result;'} }}\n"
              f"static bool eq_{k}({k} a, {k} b) {{ return a == b; }}\n"
              f'static void repr_{k}(sip_sb *b, {k} t) {{ (void)t; sip_sb_put(b, "<task>", 6); }}')
        return body, ps, im

    def gen_IfaceT(self, k, t):
        slots = []
        for mname, (ps, ret) in t.methods.items():
            args = ", ".join(["void *"] + [ctype(pt) for _, pt in ps])
            slots.append(f"{ctype(ret)} (*m_{mname})({args});")
        slots.append("void (*repr)(sip_sb *, void *);")
        body = f"struct {k}_vt {{ {' '.join(slots)} }};"
        ps = [f"static bool eq_{k}({k} a, {k} b);", f"static void repr_{k}(sip_sb *b, {k} v);"]
        im = (f"static bool eq_{k}({k} a, {k} b) {{ return a.o == b.o; }}\n"
              f"static void repr_{k}(sip_sb *b, {k} v) {{ v.vt->repr(b, v.o); }}")
        return body, ps, im

    def gen_RecordT(self, k, t):
        fields = " ".join(f"{ctype(ft)} f_{fn};" for fn, ft in t.fields.items()) or "char _unused;"
        body = f"struct {k}_s {{ {fields} }};"
        params = ", ".join(f"{ctype(ft)} f_{fn}" for fn, ft in t.fields.items()) or "void"
        assigns = " ".join(f"r->f_{fn} = f_{fn};" for fn in t.fields)
        eq = " && ".join(eq_expr(ft, f"a->f_{fn}", f"b->f_{fn}") for fn, ft in t.fields.items()) or "true"
        dn = getattr(t, "display", t.name)
        rep = [f'sip_sb_put(b, "{dn}(", {len(dn) + 1});']
        if t.name == "sip_Response":  # <Response 200 https://...>
            fields_ = {}
            rep = ['sip_sb_put(b, "<Response ", 10); str_int(b, r->f_status); sip_sb_putc(b, \' \'); '
                   'sip_sb_str(b, r->f_url); sip_sb_putc(b, \'>\'); return;']
        else:
            fields_ = t.fields
        for i, (fn, ft) in enumerate(fields_.items()):
            prefix = (", " if i else "") + fn + "="
            rep.append(f'sip_sb_put(b, "{prefix}", {len(prefix)});')
            rep.append(repr_call(ft, "b", f"r->f_{fn}"))
        rep.append("sip_sb_putc(b, ')');")
        ps = [f"static {k} {k}_new({params});", f"static bool eq_{k}({k} a, {k} b);",
              f"static void repr_{k}(sip_sb *b, {k} r);"]
        im = (f"static {k} {k}_new({params}) {{ {k} r = sip_alloc(sizeof *r); {assigns} return r; }}\n"
              f"static bool eq_{k}({k} a, {k} b) {{ return a == b || ({eq}); }}\n"
              f"static void repr_{k}(sip_sb *b, {k} r) {{ {' '.join(rep)} }}")
        return body, ps, im

    # ---------- типы-суммы ----------

    def gen_SumT(self, k, t):
        members = []
        for vname, fields in t.variants.items():
            if fields:
                fs = " ".join(f"{ctype(ft)} f_{fn};" for fn, ft in fields)
                members.append(f"struct {{ {fs} }} {vname};")
        union = f" union {{ {' '.join(members)} }} u;" if members else ""
        body = f"struct {k}_s {{ int tag;{union} }};"
        ps, im = [], []
        eq_cases, rep_cases = [], []
        for idx, (vname, fields) in enumerate(t.variants.items()):
            params = ", ".join(f"{ctype(ft)} f_{fn}" for fn, ft in fields) or "void"
            ps.append(f"static {k} {k}_new_{vname}({params});")
            if fields:
                assigns = " ".join(f"r->u.{vname}.f_{fn} = f_{fn};" for fn, _ in fields)
                im.append(f"static {k} {k}_new_{vname}({params}) {{ {k} r = sip_alloc(sizeof *r); "
                          f"r->tag = {idx}; {assigns} return r; }}")
            else:
                im.append(f"static {k} {k}_new_{vname}(void) {{ static {k} r; if (!r) {{ "
                          f"r = sip_alloc(sizeof *r); r->tag = {idx}; }} return r; }}")
            eq = " && ".join(eq_expr(ft, f"a->u.{vname}.f_{fn}", f"b->u.{vname}.f_{fn}")
                             for fn, ft in fields) or "true"
            eq_cases.append(f"case {idx}: return {eq};")
            dn = getattr(t, "vdisplay", {}).get(vname, vname)
            rep = [f'sip_sb_put(b, "{dn}(", {len(dn) + 1});']
            for i, (fn, ft) in enumerate(fields):
                prefix = (", " if i else "") + fn + "="
                rep.append(f'sip_sb_put(b, "{prefix}", {len(prefix)});')
                rep.append(repr_call(ft, "b", f"r->u.{vname}.f_{fn}"))
            rep.append("sip_sb_putc(b, ')'); return;")
            rep_cases.append(f"case {idx}: {' '.join(rep)}")
        ps += [f"static bool eq_{k}({k} a, {k} b);", f"static void repr_{k}(sip_sb *b, {k} r);"]
        im.append(f"static bool eq_{k}({k} a, {k} b) {{ if (a == b) return true; if (a->tag != b->tag) "
                  f"return false; switch (a->tag) {{ {' '.join(eq_cases)} }} return false; }}")
        im.append(f"static void repr_{k}(sip_sb *b, {k} r) {{ switch (r->tag) {{ {' '.join(rep_cases)} }} }}")
        return body, ps, "\n".join(im)


__all__ = ["Registry", "fmt_call", "repr_call", "eq_expr", "cmp_fn", "hash_fn", "opt_has", "opt_val", "nil_code",
           "UNIT", "RANGE"]
