"""Генерация C-типов и вспомогательных функций для каждого конкретного типа.

Списки, словари и кортежи мономорфизируются: для `[int]` и `[str]` получаются
разные структуры и разные функции. Значения хранятся без упаковки, и clang
может встроить и векторизовать работу с ними.
"""

from __future__ import annotations

from .types import (BOOL, FLOAT, INT, RANGE, STR, UNIT, DictT, FnT, ListT, OptT, Prim, RecordT, SumT, TupleT,
                    comparable, ctype, deep, hashable, is_ref, key)


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


class Registry:
    def __init__(self):
        self.types: dict = {}   # ключ -> тип
        self.order: list = []   # ключи в порядке зависимостей

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
        elif isinstance(t, FnT):
            for pt in t.params:
                self.need(pt)
            self.need(t.ret)
        self.order.append(k)
        return k

    # ---------- сборка ----------

    def code(self) -> str:
        fwd, tuples, bodies, protos, impls = [], [], [], [], []
        for k in self.order:
            t = self.types[k]
            if isinstance(t, (ListT, DictT, RecordT, SumT)):
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
        for k in self.order:
            t = self.types[k]
            gen = getattr(self, "gen_" + type(t).__name__)
            body, ps, im = gen(k, t)
            if body:
                bodies.append(body)
            protos += ps
            impls.append(im)
        return "\n".join(["/* ---- типы ---- */", *fwd, *tuples, *bodies,
                          "/* ---- вспомогательные функции ---- */", *protos, *impls])

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
            "repeat": f"static {k} {k}_repeat({k} l, int64_t times)",
            "contains": f"static bool {k}_contains({k} l, {ce} x)",
            "index": f"static int64_t {k}_index({k} l, {ce} x, int line)",
            "count": f"static int64_t {k}_count({k} l, {ce} x)",
            "reverse": f"static void {k}_reverse({k} l)",
            "join": f"static sip_str {k}_join({k} l, sip_str sep)",
        }
        eq = eq_expr(t.elem, "l->d[i]", "x")
        im = f"""{sigs['new']} {{
    {k} l = sip_alloc(sizeof *l);
    l->n = 0; l->cap = cap;
    l->d = cap ? sip_realloc(NULL, (size_t)cap * sizeof({ce})) : NULL;
    return l;
}}
{sigs['push']} {{
    if (SIP_UNLIKELY(l->n == l->cap)) {{
        l->cap = l->cap ? l->cap * 2 : 4;
        l->d = sip_realloc(l->d, (size_t)l->cap * sizeof({ce}));
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
    {k} r = {k}_new(times > 0 ? l->n * times : 0);
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
        }
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
    free(d->ix);
    d->ix = calloc((size_t)icap, sizeof(int32_t));
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
        d->e = sip_realloc(d->e, (size_t)d->cap * sizeof({e}));
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

    def gen_RecordT(self, k, t):
        fields = " ".join(f"{ctype(ft)} f_{fn};" for fn, ft in t.fields.items()) or "char _unused;"
        body = f"struct {k}_s {{ {fields} }};"
        params = ", ".join(f"{ctype(ft)} f_{fn}" for fn, ft in t.fields.items()) or "void"
        assigns = " ".join(f"r->f_{fn} = f_{fn};" for fn in t.fields)
        eq = " && ".join(eq_expr(ft, f"a->f_{fn}", f"b->f_{fn}") for fn, ft in t.fields.items()) or "true"
        rep = [f'sip_sb_put(b, "{t.name}(", {len(t.name) + 1});']
        for i, (fn, ft) in enumerate(t.fields.items()):
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
            rep = [f'sip_sb_put(b, "{vname}(", {len(vname) + 1});']
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
