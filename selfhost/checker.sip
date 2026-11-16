# Проверка типов Sip на самом Sip: перенос siplang/checker.py и siplang/types.py.
# Модули загружает selfhost/modules.sip: вся программа приходит сюда одним деревом.
# sip run selfhost/checker.sip FILE.sip печатает дерево с типом каждого выражения или первую ошибку.

import lexer
import parser
import modules
from parser import N, mk, S, L, T, NONE
from modules import NATIVE, SipErr, isn, nm, flag, walk_assigned, assigned

UNSUPPORTED = "is not supported by the native compiler yet"
ERROR_KINDS = ["Error", "NotFound", "ParseError", "IndexError", "KeyError", "ValueError",
               "ZeroDivisionError", "AssertionError", "IOError", "NilError", "HttpError", "OverflowError"]
NEED_TEXT = {"ord": "comparison with < (or sorting, min, max)", "hash": "use as a dict key or set item",
             "num": "arithmetic", "add": "'+'"}

# ---------- типы ----------

NEXT_ID = 0

fn nid() int
    NEXT_ID += 1
    NEXT_ID

type Field(name str, ty Ty)

type Sig(params [Field], ret Ty)

type PInfo(name str, ty Ty, default N?)

type Var(name str, ty Ty, kind str)

# Один вид для всех типов. k: prim, list, dict, tuple, opt, set, fn, task, tvar, tparam, record, sum, iface.
# a — составные части: элемент, ключ и значение, элементы кортежа, параметры функции и её результат
# последним; у записи и суммы — аргументы типа (у самого обобщённого типа это его параметры).
# У экземпляра Box[int] base — Box; поля, варианты и методы хранит base.
type Ty(k str, id int, name str = "", a [Ty] = [], ref Ty? = nil, base Ty? = nil, params [Ty] = [],
        fields {str: Ty} = {}, defaults {str: N} = {}, variants {str: [Field]} = {}, methods {str: Fn} = {},
        imethods {str: Sig} = {}, bound Ty? = nil, needs {str: bool} = {}, display str = "", mod str = "")

type Fn(node N, name str, ret Ty, owner Ty? = nil, params [PInfo] = [], locals {str: Var} = {}, body [N] = [],
        state str = "new", cache bool = false, tparams [Ty] = [], allparams [Ty] = [], tscope {str: Ty} = {},
        stars {str: int} = {}, is_async bool = false, parent Fn? = nil, parent_scopes [{str: Var}] = [],
        recvar Var? = nil, is_top bool = false)

fn prim(name str) Ty = Ty("prim", nid(), name)

INT = prim("int")
FLOAT = prim("float")
BOOL = prim("bool")
STR = prim("str")
UNIT = prim("unit")
RANGE = prim("range")
PTR = prim("ptr")
NUM = prim("num")  # в сигнатурах math.*: int или float

fn tv() Ty = Ty("tvar", nid())

fn list_t(e Ty) Ty = Ty("list", nid(), a=[e])

fn dict_t(k Ty, v Ty) Ty = Ty("dict", nid(), a=[k, v])

fn tuple_t(items [Ty]) Ty = Ty("tuple", nid(), a=items)

fn opt_t(i Ty) Ty = Ty("opt", nid(), a=[i])

fn set_t(e Ty) Ty = Ty("set", nid(), a=[e])

fn fn_t(ps [Ty], r Ty) Ty = Ty("fn", nid(), a=ps + [r])

fn task_t(r Ty) Ty = Ty("task", nid(), a=[r])

fn fn_params(t Ty) [Ty] = t.a[:len(t.a) - 1]

fn fn_ret(t Ty) Ty = t.a[len(t.a) - 1]

fn is_gen(t Ty) bool = t.k == "record" or t.k == "sum"

fn base_of(t Ty) Ty
    if t.base == nil then return t
    t.base

fn meths(t Ty) {str: Fn} = base_of(t).methods

fn disp(t Ty) str
    d = base_of(t).display
    if d != "" then return d
    t.name

fn targ_map(t Ty) {int: Ty}
    m: {int: Ty} = {}
    for P, a in zip(base_of(t).params, t.a)
        m[P.id] = a
    m

fn fields_of(t Ty) {str: Ty}
    if t.base == nil then return t.fields
    m = targ_map(t)
    b = base_of(t)
    out: {str: Ty} = {}
    for n in b.fields
        out[n] = subst(b.fields[n], m)
    out

fn variants_of(t Ty) {str: [Field]}
    if t.base == nil then return t.variants
    m = targ_map(t)
    b = base_of(t)
    out: {str: [Field]} = {}
    for v in b.variants
        out[v] = [Field(f.name, subst(f.ty, m)) for f in b.variants[v]]
    out

fn instantiate(base Ty, args [Ty]) Ty
    if not base.params then return base
    Ty(base.k, nid(), base.name, a=args, base=base, display=base.display)

fn prune(t Ty) Ty
    cur = t
    while cur.k == "tvar" and cur.ref != nil
        cur = cur.ref
    cur

fn is_p(t Ty, p Ty) bool = prune(t).id == p.id

fn opt_of(t Ty) Ty
    if prune(t).k == "opt" then return t
    opt_t(t)

fn subst(t0 Ty, m {int: Ty}) Ty
    t = t0
    while t.k == "tvar" and t.ref != nil
        t = t.ref
    if t.k == "tparam" and t.id in m then return m[t.id]
    t = prune(t)
    k = t.k
    if k == "tparam" then return t
    if k == "list" or k == "dict" or k == "tuple" or k == "opt" or k == "set" or k == "fn" or k == "task"
        return Ty(k, nid(), a=[subst(x, m) for x in t.a])
    if is_gen(t) and t.a
        return instantiate(base_of(t), [subst(x, m) for x in t.a])
    t

fn is_resolved(t0 Ty) bool
    t = prune(t0)
    if t.k == "tvar" then return false
    if t.k == "prim" or t.k == "tparam" or t.k == "iface" then return true
    for x in t.a
        if not is_resolved(x) then return false
    true

fn show(t0 Ty) str
    t = prune(t0)
    k = t.k
    if k == "prim" then return t.name
    if k == "list" then return "[" + show(t.a[0]) + "]"
    if k == "dict" then return "{{" + show(t.a[0]) + ": " + show(t.a[1]) + "}}"
    if k == "tuple" then return "(" + ", ".join([show(x) for x in t.a]) + ")"
    if is_gen(t)
        if t.a then return disp(t) + "[" + ", ".join([show(x) for x in t.a]) + "]"
        return disp(t)
    if k == "tparam" or k == "iface" then return disp(t)
    if k == "opt" then return show(t.a[0]) + "?"
    if k == "set" then return "{{" + show(t.a[0]) + "}}"
    if k == "fn"
        ret = if is_p(fn_ret(t), UNIT) then "" else " " + show(fn_ret(t))
        return "fn(" + ", ".join([show(x) for x in fn_params(t)]) + ")" + ret
    if k == "task" then return "Task[" + show(t.a[0]) + "]"
    "?"

fn all_same(xs [Ty], ys [Ty]) bool
    if len(xs) != len(ys) then return false
    for x, y in zip(xs, ys)
        if not same(x, y) then return false
    true

fn same(a0 Ty, b0 Ty) bool
    a = prune(a0)
    b = prune(b0)
    if a.id == b.id then return true
    if a.k != b.k then return false
    k = a.k
    if k == "list" or k == "opt" or k == "set" or k == "task" then return same(a.a[0], b.a[0])
    if k == "dict" then return same(a.a[0], b.a[0]) and same(a.a[1], b.a[1])
    if k == "tuple" or k == "fn" then return all_same(a.a, b.a)
    if is_gen(a)
        if base_of(a).id != base_of(b).id then return false
        for x, y in zip(a.a, b.a)
            if not same(x, y) then return false
        return true
    false

fn is_basic(t Ty) bool = t.id == INT.id or t.id == FLOAT.id or t.id == BOOL.id or t.id == STR.id

fn hashable(t0 Ty) bool
    t = prune(t0)
    if t.k == "tparam"
        t.needs["hash"] = true  # проверится в месте вызова
        return true
    if is_basic(t) then return true
    if t.k == "tuple"
        for x in t.a
            if not hashable(x) then return false
        return true
    false

fn comparable(t0 Ty) bool
    t = prune(t0)
    if t.k == "tparam"
        t.needs["ord"] = true
        return true
    if is_basic(t) then return true
    if t.k == "tuple"
        for x in t.a
            if not comparable(x) then return false
        return true
    if t.k == "list" then return comparable(t.a[0])
    false

fn truthy_ok(t0 Ty) bool
    t = prune(t0)
    if is_basic(t) or t.id == RANGE.id then return true
    t.k == "list" or t.k == "dict" or t.k == "opt" or t.k == "set"

fn mk_response() Ty
    r = Ty("record", nid(), "sip_Response", display="Response")
    r.fields["status"] = INT
    r.fields["ok"] = BOOL
    r.fields["text"] = STR
    r.fields["url"] = STR
    r.fields["headers"] = dict_t(STR, STR)
    r

RESPONSE = mk_response()

# ---------- встроенные функции и модули ----------

type NSig(params [Ty], ret Ty)

NATIVE_SIGS: {str: NSig} = {}
for n in ["sqrt", "log2", "log10", "exp", "sin", "cos", "tan", "asin", "acos", "atan"]
    NATIVE_SIGS["math." + n] = NSig([NUM], FLOAT)
for n in ["floor", "ceil", "trunc"]
    NATIVE_SIGS["math." + n] = NSig([NUM], INT)
NATIVE_SIGS["math.log"] = NSig([NUM, NUM], FLOAT)
NATIVE_SIGS["math.atan2"] = NSig([NUM, NUM], FLOAT)
NATIVE_SIGS["math.hypot"] = NSig([NUM, NUM], FLOAT)
NATIVE_SIGS["math.pow"] = NSig([NUM, NUM], FLOAT)
NATIVE_SIGS["math.isnan"] = NSig([NUM], BOOL)
NATIVE_SIGS["math.isinf"] = NSig([NUM], BOOL)
NATIVE_SIGS["math.gcd"] = NSig([INT, INT], INT)
NATIVE_SIGS["random.random"] = NSig([], FLOAT)
NATIVE_SIGS["random.randint"] = NSig([INT, INT], INT)
NATIVE_SIGS["random.uniform"] = NSig([NUM, NUM], FLOAT)
NATIVE_SIGS["random.seed"] = NSig([INT], UNIT)
NATIVE_SIGS["time.time"] = NSig([], FLOAT)
NATIVE_SIGS["time.perf_counter"] = NSig([], FLOAT)
NATIVE_SIGS["time.sleep"] = NSig([NUM], UNIT)

NATIVE_CONSTS = {"math.pi", "math.e", "math.tau", "math.inf", "math.nan"}

BUILTINS = {"random.choice", "json.parse", "json.read", "json.stringify", "json.write", "csv.read", "csv.parse",
            "csv.write", "http.get", "http.post", "http.response_json", "random.shuffle", "print", "len", "str",
            "int", "float", "bool", "abs", "min", "max", "sum", "avg", "any", "all", "sorted", "list", "count",
            "read", "write", "input", "round", "zip", "enumerate", "exit", "set", "ord", "chr"}
for n in NATIVE_SIGS
    BUILTINS.add(n)

STR_METHODS = {"lower", "upper", "strip", "lstrip", "rstrip", "splitlines", "isdigit", "isalpha", "isspace",
               "split", "startswith", "endswith", "find", "count", "replace", "join", "rfind", "removeprefix",
               "removesuffix", "zfill", "ljust", "rjust", "isalnum", "isupper", "islower", "capitalize", "title"}
LIST_METHODS = {"append", "pop", "insert", "extend", "clear", "reverse", "copy", "index", "count", "sort", "join",
                "sum", "avg", "top", "map", "filter", "sort_by", "group_by", "first"}
DICT_METHODS = {"pop", "update", "clear", "get", "keys", "values", "items", "copy", "top"}
SET_METHODS = {"add", "remove", "discard", "clear", "copy", "update", "union", "intersection", "difference",
               "issubset"}


# ---------- узлы ----------

fn opt_n(n N) N?
    if n.kind == "None" then return nil
    n

fn is_nil(e N) bool = e.kind == "Const" and e.kids[0].s == "None"

fn is_nil_opt(e N?) bool
    if e == nil then return false
    is_nil(e)

fn copy_n(n N) N = N(n.kind, n.line, n.s, [copy_n(k) for k in n.kids])

fn is_extern(fnode N) bool = len(fnode.kids) == 9

# имя определения в исходнике модуля (после переименования utils__f это f)
fn dname(n N) str = if n.s != "" then n.s else nm(n)

# неявный return: последнее выражение функции — её результат
fn tail(stmts [N]) [N]
    if not stmts then return stmts
    out = stmts[:len(stmts) - 1]
    out.append(tail_stmt(stmts[len(stmts) - 1]))
    out

fn tail_stmt(s N) N
    k = s.kind
    if k == "ExprStmt"
        e = s.kids[0]
        if e.kind == "Call" and e.kids[0].kind == "Name" and nm(e.kids[0]) == "print" then return s
        return mk("Return", s.line, [e])
    if k == "If"
        brs = [T([b.kids[0], L(tail(b.kids[1].kids))]) for b in s.kids[0].kids]
        orelse = if isn(s.kids[1]) then s.kids[1] else L(tail(s.kids[1].kids))
        return mk("If", s.line, [L(brs), orelse])
    if k == "Try"
        hs = [mk("Handler", h.line, [h.kids[0], h.kids[1], L(tail(h.kids[2].kids))]) for h in s.kids[1].kids]
        return mk("Try", s.line, [L(tail(s.kids[0].kids)), L(hs)])
    if k == "Match"
        arms = [mk("Arm", a.line, [a.kids[0], a.kids[1], L(tail(a.kids[2].kids))]) for a in s.kids[1].kids]
        return mk("Match", s.line, [s.kids[0], L(arms)])
    s

# значение по умолчанию подставляется в месте вызова, поэтому только литералы
fn literal_default(e N) bool
    k = e.kind
    if k == "Num" or k == "Const" then return true
    if k == "Str"
        for p in e.kids[0].kids
            if p.kind != "str" then return false
        return true
    if k == "Unary" and e.kids[0].s == "-" then return e.kids[1].kind == "Num"
    if k == "ListLit" or k == "TupleLit"
        for i in e.kids[0].kids
            if not literal_default(i) then return false
        return true
    if k == "DictLit"
        for kv in e.kids[0].kids
            if isn(kv.kids[0]) or not literal_default(kv.kids[0]) or not literal_default(kv.kids[1]) then return false
        return true
    false

# ---------- проверка ----------

type Lam(block bool, ret Ty)

type Typed(node N, ty Ty, name str)

type Inst(params [Ty], args [Ty], node N, what str)

type Checker(file str, std str, loader modules.Loader, tys [Ty] = [], records {str: Ty} = {}, sums {str: Ty} = {},
             variants {str: Ty} = {}, ifaces {str: Ty} = {}, fns {str: Fn} = {}, methods [Fn] = [],
             globals {str: Var} = {}, tops [Fn] = [], cur Fn? = nil, scopes [{str: Var}] = [], lams [Lam] = [],
             typed [Typed] = [], nils [N] = [], tscope {str: Ty} = {}, inst_checks [Inst] = [],
             all_tparams [Ty] = [])

    # ---------- общее ----------

    fn err(msg str, node N? = nil)
        line = if node == nil then 0 else node.line
        f = .file
        if line != 0
            f, line = .loader.locate(line)
        fail SipErr(msg, f, line, 0)

    # файл, в котором написан узел
    fn mod_of(node N) str
        if node.line == 0 then return .file
        f, _ = .loader.locate(node.line)
        f

    fn is_std(f str) bool = f != "" and modules.abspath(f).startswith(.std + "/")

    # поле или метод на _ доступны только в модуле, где объявлен тип
    fn private(t Ty, name str, node N, what str)
        m = base_of(t).mod
        if name.startswith("_") and m != "" and .mod_of(node) != m
            .err("{what} '{name}' of {show(t)} is private to its module", node)
        pass

    fn set_ty(n N, t Ty)
        if n.ty == 0
            .tys.append(t)
            n.ty = len(.tys) - 1
        else
            .tys[n.ty] = t
        pass

    fn ty_of(n N) Ty = .tys[n.ty]

    fn kinds() {str}
        out: {str} = set()
        for n in .records
            out.add(n)
        for n in .sums
            out.add(n)
        for n in .variants
            out.add(n)
        out

    fn unify(a0 Ty, b0 Ty) bool
        a = prune(a0)
        b = prune(b0)
        if a.id == b.id then return true
        if a.k == "tvar"
            a.ref = b
            return true
        if b.k == "tvar"
            b.ref = a
            return true
        if a.k != b.k then return false
        k = a.k
        if k == "list" or k == "opt" or k == "set" or k == "task" then return .unify(a.a[0], b.a[0])
        if k == "dict" then return .unify(a.a[0], b.a[0]) and .unify(a.a[1], b.a[1])
        if k == "tuple" or k == "fn"
            if len(a.a) != len(b.a) then return false
            for x, y in zip(a.a, b.a)
                if not .unify(x, y) then return false
            return true
        if is_gen(a)
            if base_of(a).id != base_of(b).id then return false
            for x, y in zip(a.a, b.a)
                if not .unify(x, y) then return false
            return true
        false

    # значение типа got кладётся туда, где ждут want; src — выражение (для T -> T? и T? -> T)
    fn expect(want Ty, got Ty, node N?, what str, src N? = nil)
        pw = prune(want)
        pg = prune(got)
        if pw.id == FLOAT.id and pg.id == INT.id then return
        if .to_iface(pw, pg, node, what, src) then return
        if src != nil and pw.k == "opt" and pg.k != "opt" and pg.k != "tvar" and pg.id != UNIT.id
            if not .to_iface(prune(pw.a[0]), pg, node, what, src) then .expect(pw.a[0], got, node, what)
            return
        if pg.k == "opt" and pw.k != "opt" and pw.k != "tvar"
            if src == nil or is_nil_opt(src)
                .err("{what}: {show(want)} cannot be nil (use {show(want)}? for an optional value)", node)
            .expect(want, pg.a[0], node, what)
            return
        if not .unify(want, got)
            hint = if pw.id == INT.id and pg.id == FLOAT.id then " (write 0.0 for a float)" else ""
            .err("{what}: expected {show(want)}, got {show(got)}{hint}", node)
        pass

    fn to_iface(pw Ty, pg Ty, node N?, what str, src N?) bool
        if pw.k != "iface" or not (is_gen(pg) or pg.k == "tparam" or pg.k == "iface") or pg.id == pw.id
            return false
        why = .implements(pg, pw)
        if why != "" then .err("{what}: {show(pg)} is not a {show(pw)}: {why}", node)
        if src == nil
            .err("{what}: expected {show(pw)}, got {show(pg)}; convert it where the value is created, " +
                 "e.g. `x: {show(pw)} = ...`", node)
        if pg.k == "iface" then .err("{what}: converting {show(pg)} to {show(pw)} {UNSUPPORTED}", node)
        true

    fn unite(items [(N, Ty)], what str) Ty
        anyopt = false
        for n, t in items
            if prune(t).k == "opt" then anyopt = true
        acc = tv()
        for n, t in items
            pt = prune(t)
            acc = .join(acc, if pt.k == "opt" then pt.a[0] else t, n, what)
        target = if anyopt then opt_t(acc) else acc
        for n, t in items
            .expect(target, t, n, what, n)
        target

    fn compatible(a0 Ty, b0 Ty) bool
        a = prune(a0)
        b = prune(b0)
        if a.k == "opt" then a = prune(a.a[0])
        if b.k == "opt" then b = prune(b.a[0])
        if a.k == "tvar" or b.k == "tvar" then return true
        if .numeric(a) and .numeric(b) then return true
        same(a, b)

    fn join(a Ty, b Ty, node N, what str) Ty
        pa = prune(a)
        pb = prune(b)
        if (pa.id == INT.id and pb.id == FLOAT.id) or (pa.id == FLOAT.id and pb.id == INT.id) then return FLOAT
        if not .unify(a, b) then .err("{what}: {show(a)} and {show(b)} do not match", node)
        a

    fn numeric(t Ty) bool = is_p(t, INT) or is_p(t, FLOAT)

    fn num_param(t0 Ty) bool
        t = prune(t0)
        if t.k == "tparam"
            t.needs["num"] = true
            return true
        false

    fn need_resolved(t Ty, node N?, what str)
        if not is_resolved(t)
            hint = if prune(t).k == "opt" then "x: int? = nil" else "xs: [int] = []"
            .err("cannot infer the type of {what}; add a type, e.g. {hint}", node)
        pass

    fn to_type(t N) Ty
        k = t.kind
        if k == "TName"
            n = nm(t)
            targs = t.kids[1].kids
            if n in .tscope
                if targs then .err("type parameter '{n}' takes no type arguments", t)
                return .tscope[n]
            if not targs
                if n == "int" then return INT
                if n == "float" then return FLOAT
                if n == "bool" then return BOOL
                if n == "str" then return STR
                if n == "ptr" then return PTR
            if n == "http.Response" then return RESPONSE
            if n in .records or n in .sums
                base = if n in .records then .records[n] else .sums[n]
                dn = disp(base)
                if not base.params
                    if targs then .err("type '{dn}' takes no type arguments", t)
                    return base
                if len(targs) != len(base.params)
                    ex = ", ".join(["int" for _ in base.params])
                    if not targs then .err("type '{dn}' needs {len(base.params)} type argument(s), e.g. {dn}[{ex}]", t)
                    .err("type '{dn}' takes {len(base.params)} type argument(s), got {len(targs)}", t)
                return instantiate(base, [.to_type(a) for a in targs])
            if n in .ifaces
                if targs then .err("interface '{n}' takes no type arguments", t)
                return .ifaces[n]
            if n == "Response" then return RESPONSE
            if n == "list" then .err("write [T] instead of 'list'", t)
            if n == "dict" then .err("write {{K: V}} instead of 'dict'", t)
            if n == "tuple" then .err("write (A, B) instead of 'tuple'", t)
            if n == "None" then .err("nil is not a type; write T? for a value that may be nil, e.g. int?", t)
            .err("unknown type '{n}'", t)
        if k == "TList" then return list_t(.to_type(t.kids[0]))
        if k == "TDict"
            kt = .to_type(t.kids[0])
            if not hashable(kt)
                .err("dict key type must be int, float, bool, str or a tuple of them, not {show(kt)}", t)
            return dict_t(kt, .to_type(t.kids[1]))
        if k == "TTuple" then return tuple_t([.to_type(i) for i in t.kids[0].kids])
        if k == "TSet"
            el = .to_type(t.kids[0])
            if not hashable(el) then .err("set items must be int, float, bool, str or a tuple of them, not {show(el)}", t)
            return set_t(el)
        if k == "TOptional" then return opt_of(.to_type(t.kids[0]))
        if k == "TFn"
            ps = [.to_type(p) for p in t.kids[0].kids]
            return fn_t(ps, if isn(t.kids[1]) then UNIT else .to_type(t.kids[1]))
        .err("bad type", t)
        UNIT

    # ---------- модуль ----------

    fn check(body [N])
        top_stmts: [N] = []
        fn_nodes: [N] = []
        for s in body
            k = s.kind
            if (k == "Record" or k == "SumType" or k == "Interface") and (nm(s) in .records or nm(s) in .sums or
                                                                          nm(s) in .ifaces)
                .err("type '{dname(s)}' is already defined", s)
            if k == "Interface"
                .ifaces[nm(s)] = Ty("iface", nid(), nm(s), display=dname(s))
            elif k == "Record"
                rt = Ty("record", nid(), nm(s), display=dname(s), mod=.mod_of(s))
                .records[nm(s)] = rt
                .type_params(rt, s)
            elif k == "SumType"
                st = Ty("sum", nid(), nm(s), display=dname(s), mod=.mod_of(s))
                .type_params(st, s)
                .sums[nm(s)] = st
                for v in s.kids[1].kids
                    if nm(v) in .variants or nm(v) in .records then .err("variant '{nm(v)}' is already defined", v)
                    .variants[nm(v)] = st
            elif k == "FnDef"
                fn_nodes.append(s)
            elif k == "Import" or k == "FromImport"
                .err("import {UNSUPPORTED}", s)
            else
                top_stmts.append(s)

        # параметры типов с ограничением T: Shape и методы интерфейсов
        for s in body
            if s.kind == "Record" or s.kind == "SumType"
                base = if s.kind == "Record" then .records[nm(s)] else .sums[nm(s)]
                .bind_bounds(base.params, s.kids[3].kids)
            elif s.kind == "Interface"
                it = .ifaces[nm(s)]
                for m in s.kids[1].kids
                    if nm(m) in it.imethods then .err("method '{nm(m)}' is already declared in {it.display}", m)
                    ps: [Field] = []
                    for prm in m.kids[1].kids
                        if isn(prm.kids[1]) or not isn(prm.kids[2]) or prm.kids[3].s != ""
                            .err("interface method parameter '{nm(prm)}' needs a plain type, e.g. " +
                                 "{nm(prm)} int", prm)
                        ps.append(Field(nm(prm), .to_type(prm.kids[1])))
                    it.imethods[nm(m)] = Sig(ps, if isn(m.kids[2]) then UNIT else .to_type(m.kids[2]))

        # поля и варианты (типы могут ссылаться друг на друга)
        for s in body
            if s.kind == "Record" or s.kind == "SumType"
                base = if s.kind == "Record" then .records[nm(s)] else .sums[nm(s)]
                .tscope = {}
                for P in base.params
                    .tscope[P.name] = P
            if s.kind == "Record"
                rt = .records[nm(s)]
                for f in s.kids[1].kids
                    fname = nm(f)
                    if isn(f.kids[1])
                        if isn(f.kids[2]) then .err("field '{fname}' needs a type", f)
                        rt.fields[fname] = .default_type(f.kids[2])
                    else
                        rt.fields[fname] = .to_type(f.kids[1])
                    if not isn(f.kids[2])
                        if not literal_default(f.kids[2]) then .err("default value must be a literal", f.kids[2])
                        rt.defaults[fname] = f.kids[2]
                        node = copy_n(f.kids[2])  # проверенная копия — для полей, которых нет в JSON/CSV
                        saved = .cur
                        .cur = nil
                        .expect(rt.fields[fname], .expr(node, true), node, "field '{fname}'", node)
                        .cur = saved
                for m in s.kids[2].kids
                    fi = Fn(m, nm(m), tv(), owner=rt)
                    rt.methods[nm(m)] = fi
                    .methods.append(fi)
            elif s.kind == "SumType"
                st = .sums[nm(s)]
                for v in s.kids[1].kids
                    fs: [Field] = []
                    for f in v.kids[1].kids
                        if isn(f.kids[1]) then .err("field '{nm(f)}' needs a type", f)
                        if not isn(f.kids[2]) then .err("variant field defaults {UNSUPPORTED}", f)
                        fs.append(Field(nm(f), .to_type(f.kids[1])))
                    st.variants[nm(v)] = fs
                for m in s.kids[2].kids
                    fi = Fn(m, nm(m), tv(), owner=st)
                    st.methods[nm(m)] = fi
                    .methods.append(fi)
            .tscope = {}

        for f in fn_nodes
            name = nm(f)
            if name in .fns then .err("function '{name}' is already defined", f)
            if name in .records or name in .variants or name in .ifaces then .err("'{name}' is already a type", f)
            .fns[name] = Fn(f, name, tv())
        all = [fi for fi in .fns.values()] + .methods
        for fi in all
            .signature(fi)

        # верхний уровень: присвоенные там имена — глобальные переменные
        # у каждого модуля своя функция верхнего уровня, в порядке тел: зависимости раньше
        order: [str] = []
        groups: {str: [N]} = {}
        for ts in top_stmts
            mf = .mod_of(ts)
            if mf not in groups
                groups[mf] = []
                order.append(mf)
            groups[mf].append(ts)
        if not order then order.append(.loader.files[0][1])
        for mf in order
            stmts = if mf in groups then groups[mf] else []
            topnode = mk("FnDef", 1, [S("<top>"), L([]), NONE(), L(stmts), parser.B(false), L([]), parser.B(false),
                                      L([])])
            top = Fn(topnode, "<top>", UNIT, body=stmts, is_top=true)
            for name in assigned(stmts, .kinds())
                .globals[name] = Var(name, tv(), "global")
            top.locals = .globals
            .tops.append(top)
        for top in .tops
            .cur = top
            top.state = "busy"
            .block(top.body)
            top.state = "done"
            .cur = nil

        for fi in all
            .check_fn(fi)

        .default_nils(0)
        .check_typed(0)
        for name in .globals
            .need_resolved(.globals[name].ty, nil, "global '{name}'")
        .check_instances()
        if "main" in .fns
            mainf = .fns["main"]
            if mainf.tparams then .err("main cannot have type parameters", mainf.node)
            if "**" in mainf.stars then .err("main cannot take **kwargs; use flags: fn main(name str, n = 1)", mainf.node)
            star = if "*" in mainf.stars then mainf.stars["*"] else -1
            for i, p in enumerate(mainf.params)
                pt = prune(p.ty)
                if i == star then pt = prune(pt.a[0])  # *files str — остальные позиционные аргументы
                if pt.k == "opt" and p.default != nil then pt = prune(pt.a[0])
                if not (pt.id == INT.id or pt.id == FLOAT.id or pt.id == STR.id or pt.id == BOOL.id)
                    .err("main parameter '{p.name}' must be int, float, str or bool (or T? = nil)", mainf.node)
        pass

    fn type_params(base Ty, node N)
        names: {str} = set()
        for tp in node.kids[3].kids
            if nm(tp) in names then .err("type parameter '{nm(tp)}' is repeated", tp)
            names.add(nm(tp))
            P = Ty("tparam", nid(), nm(tp))
            .all_tparams.append(P)
            base.params.append(P)
        base.a = base.params[:]

    fn bind_bounds(params [Ty], defs [N])
        for P, tp in zip(params, defs)
            if isn(tp.kids[1]) then continue
            b = .to_type(tp.kids[1])
            if b.k != "iface" then .err("'{nm(tp)}: {show(b)}': a bound must be an interface", tp)
            P.bound = b

    # почему тип t не подходит под интерфейс it ("" — подходит)
    fn implements(t0 Ty, it Ty) str
        t = prune(t0)
        if t.k == "iface"
            if t.id == it.id then return ""
            for name in it.imethods
                sig = it.imethods[name]
                if name not in t.imethods then return "{show(t)} has no method {name}()"
                sig2 = t.imethods[name]
                ok = len(sig.params) == len(sig2.params)
                if ok
                    for f1, f2 in zip(sig.params, sig2.params)
                        if not same(f1.ty, f2.ty) then ok = false
                if not ok or not same(sig.ret, sig2.ret) then return "{show(t)}.{name}() has a different signature"
            return ""
        if t.k == "tparam"
            if t.bound == nil then return "type parameter {t.name} has no bound; write [{t.name}: {show(it)}]"
            return .implements(t.bound, it)
        if not is_gen(t) then return "{show(t)} has no methods"
        m = targ_map(t)
        for name in it.imethods
            sig = it.imethods[name]
            fi0 = meths(t).get(name)
            if fi0 == nil then return "{show(t)} has no method {name}()"
            fi = meths(t)[name]
            if fi.tparams then return "{show(t)}.{name}() has type parameters"
            .ensure(fi)
            fps = [subst(p.ty, m) for p in fi.params]
            want = "(" + ", ".join([show(p.ty) for p in sig.params]) + ")" + (
                if sig.ret.id == UNIT.id then "" else " " + show(sig.ret))
            ok = len(fps) == len(sig.params)
            if ok
                for a, p in zip(fps, sig.params)
                    if not same(a, p.ty) then ok = false
            if not ok or not same(subst(.call_ret(fi), m), sig.ret) or len(fi.stars) > 0
                got = "(" + ", ".join([show(x) for x in fps]) + ")"
                r = subst(.call_ret(fi), m)
                got = got + (if is_p(r, UNIT) then "" else " " + show(r))
                return "{show(t)}.{name}{got} does not match {show(it)}.{name}{want}"
        ""

    fn need_ok(t0 Ty, need str) bool
        t = prune(t0)
        if need == "ord" then return comparable(t)
        if need == "hash" then return hashable(t)
        if t.k == "tparam"
            t.needs[need] = true
            return true
        if need == "num" then return .numeric(t)
        .numeric(t) or t.id == STR.id or t.k == "list"  # "add"

    fn total_needs() int = sum([len(P.needs) for P in .all_tparams])

    fn check_instances()
        while true
            before = .total_needs()
            for ic in .inst_checks
                for P, a in zip(ic.params, ic.args)
                    for need in [n for n in P.needs]
                        .need_ok(a, need)
            if .total_needs() == before then break
        for ic in .inst_checks
            for P, a in zip(ic.params, ic.args)
                if not is_resolved(a)
                    .err("{ic.what}: cannot infer type parameter {P.name}; give the arguments types", ic.node)
                for need in [n for n in P.needs]
                    if not .need_ok(a, need)
                        .err("{ic.what}: {P.name} = {show(a)} does not support {NEED_TEXT[need]}, " +
                             "which the function uses", ic.node)
                if P.bound != nil
                    why = .implements(a, P.bound)
                    if why != "" then .err("{ic.what}: {P.name} = {show(a)} is not a {show(P.bound)}: {why}", ic.node)
        pass

    fn ensure(fi Fn)
        if fi.state == "new" and prune(fi.ret).k == "tvar" then .check_fn(fi)
        pass

    fn call_ret(fi Fn) Ty = if fi.is_async then task_t(fi.ret) else fi.ret

    # вызов функции или метода с параметрами типа: m — уже известные (тип владельца)
    fn generic_call(e N, fi Fn, what str, m {int: Ty}) Ty
        for P in fi.tparams
            if P.id not in m then m[P.id] = tv()
        params = [PInfo(p.name, subst(p.ty, m), p.default) for p in fi.params]
        .bind_args(e, params, what, fi.stars)
        .ensure(fi)
        targs = [m[P.id] for P in fi.allparams]
        if fi.allparams then .inst_checks.append(Inst(fi.allparams, targs, e, what))
        subst(.call_ret(fi), m)

    fn default_nils(start int)
        for n in .nils[start:]
            .default_tvars(.ty_of(n))

    fn typed_result(e N, name str) Ty
        t = tv()
        .typed.append(Typed(e, t, name))
        t

    fn typed_hint(t Ty) str
        for x in .typed
            if prune(x.ty).id == prune(t).id
                ex = if x.name == ".json" then "r.json()" else "{x.name}(...)"
                return "; {ex} needs the type from the context, e.g. `data: {{str: int}} = {ex}`"
        ""

    fn check_typed(start int)
        for x in .typed[start:]
            if not is_resolved(x.ty)
                ex = if x.name == ".json" then "r.json()" else "{x.name}(...)"
                .err("{ex}: cannot infer the result type; give it one, e.g. " +
                     "`users: [User] = {ex}` or a function return type", x.node)
        pass

    fn default_tvars(t0 Ty)
        t = prune(t0)
        if t.k == "tvar"
            t.ref = INT
        elif t.k == "list" or t.k == "set" or t.k == "dict" or t.k == "opt" or t.k == "tuple" or is_gen(t)
            for x in t.a
                .default_tvars(x)
        pass

    fn default_type(e N) Ty
        if not literal_default(e) then .err("default value must be a literal", e)
        saved = .cur
        .cur = nil
        t = .expr(e, true)
        .cur = saved
        t

    fn signature(fi Fn)
        n = fi.node
        scope: {str: Ty} = {}
        if fi.parent != nil
            if n.kids[7].kids
                .err("a nested function cannot have type parameters {UNSUPPORTED}; declare it at the top level", n)
            scope = .tscope.copy()
        elif fi.owner != nil
            for P in fi.owner.params
                scope[P.name] = P
        for tp in n.kids[7].kids
            tn = nm(tp)
            if tn in scope then .err("type parameter '{tn}' is already defined", tp)
            if tn in .records or tn in .sums or tn in .ifaces or tn in ["int", "float", "str", "bool"]
                .err("type parameter '{tn}' hides the type {tn}; use another name, e.g. T", tp)
            P = Ty("tparam", nid(), tn)
            .all_tparams.append(P)
            scope[tn] = P
            fi.tparams.append(P)
        fi.tscope = scope
        fi.allparams = (if fi.owner != nil then fi.owner.params[:] else []) + fi.tparams
        saved = .tscope
        .tscope = scope
        .bind_bounds(fi.tparams, n.kids[7].kids)
        .signature_types(fi)
        .tscope = saved

    fn signature_types(fi Fn)
        n = fi.node
        fi.is_async = flag(n.kids[4])
        decorators = n.kids[5].kids
        if fi.is_async and decorators then .err("@cache cannot be used on an async fn", n)
        for d in decorators
            if d.kind == "Name" and nm(d) == "cache"
                fi.cache = true
            else
                .err("decorator {UNSUPPORTED} (only @cache)", n)
        fi.stars = {}
        for prm in n.kids[1].kids
            pname = nm(prm)
            ptype = prm.kids[1]
            pdef = prm.kids[2]
            star = prm.kids[3].s
            if star != ""
                if star in fi.stars then .err("only one {star}{pname} parameter is allowed", prm)
                if star == "*" and "**" in fi.stars then .err("*args must come before **kwargs", prm)
                if isn(ptype)
                    ex = if star == "*" then "*{pname} int" else "**{pname} str"
                    .err("parameter '{star}{pname}' needs the type of its items, e.g. {ex}", prm)
                if not isn(pdef) then .err("'{star}{pname}' cannot have a default value", prm)
                et = .to_type(ptype)
                fi.stars[star] = len(fi.params)
                fi.params.append(PInfo(pname, if star == "*" then list_t(et) else dict_t(STR, et), nil))
                continue
            if "**" in fi.stars then .err("parameters cannot follow **kwargs", prm)
            t = UNIT
            if not isn(ptype)
                t = .to_type(ptype)
                if not isn(pdef)
                    if not literal_default(pdef) then .err("default value must be a literal", pdef)
                    .expect(t, .default_type(pdef), pdef, "default of '{pname}'", pdef)
            elif not isn(pdef)
                if is_nil(pdef) then .err("parameter '{pname}' needs a type, e.g. {pname} int? = nil", prm)
                t = .default_type(pdef)
            else
                .err("parameter '{pname}' needs a type, e.g. {pname} int", prm)
            fi.params.append(PInfo(pname, t, opt_n(pdef)))
        if not isn(n.kids[2]) then fi.ret = .to_type(n.kids[2])
        if fi.cache
            for p in fi.params
                if not hashable(p.ty) then .err("@cache needs hashable parameters, '{p.name}' is {show(p.ty)}", n)
            if not fi.params then .err("@cache needs at least one parameter", n)
        pass

    fn ok_c(t Ty) bool = is_basic(t) or t.id == PTR.id

    fn check_extern(fi Fn)
        n = fi.node
        ext = n.kids[8]
        fi.state = "done"
        if ext.kids[0].s == "sip" and not .is_std(.mod_of(n))
            .err("extern \"sip\" is reserved for the standard library; use extern fn or extern \"lib\"", n)
        if fi.parent != nil then .err("extern fn must be declared at the top level", n)
        for p, c in zip(fi.params, ext.kids[2].kids)
            pt = prune(p.ty)
            if not (.ok_c(pt) or (pt.k == "opt" and (is_p(pt.a[0], STR) or is_p(pt.a[0], PTR))))
                .err("extern fn parameter '{p.name}' must be int, float, bool, str, ptr, a C number type " +
                     "(i32, u8, usize, f32, ...) or str?/ptr?, not {show(pt)}", n)
        if isn(n.kids[2]) then fi.ret = UNIT
        rt = prune(fi.ret)
        if not (.ok_c(rt) or rt.id == UNIT.id or (rt.k == "opt" and (is_p(rt.a[0], STR) or is_p(rt.a[0], PTR))))
            .err("extern fn result must be int, float, bool, str, ptr, str?, ptr? or a C number type, " +
                 "not {show(rt)}", n)
        pass

    fn check_fn(fi Fn)
        if fi.state != "new" then return
        if is_extern(fi.node)
            .check_extern(fi)
            return
        fi.state = "busy"
        saved_cur = .cur
        saved_scopes = .scopes
        saved_lams = .lams
        saved_ts = .tscope
        .cur = fi
        .scopes = []
        .lams = []
        .tscope = fi.tscope
        if fi.owner != nil then fi.locals["self"] = Var("self", fi.owner, "param")
        for p in fi.params
            fi.locals[p.name] = Var(p.name, p.ty, "param")
        if fi.parent != nil then fi.locals[fi.name] = fi.recvar  # рекурсивный вызов самой себя
        fi.body = tail(fi.node.kids[3].kids)
        names: [str] = []
        augs: [str] = []
        walk_assigned(fi.body, names, augs, true, .kinds())
        for n in augs
            if n not in names and n not in fi.locals and .outer_var(fi, n) != nil
                .err("a nested function cannot change the outer variable '{n}'; return the new value instead",
                     fi.node)
        # `count += 1` без `count = ...` в функции меняет глобальную переменную
        more = [n for n in augs if n not in names and n not in .globals]
        names.extend(more)
        for name in names
            if name not in fi.locals then fi.locals[name] = Var(name, tv(), "local")
        start = len(.nils)
        tstart = len(.typed)
        .block(fi.body)
        .default_nils(start)
        .check_typed(tstart)
        if prune(fi.ret).k == "tvar" then fi.ret.ref = UNIT
        for v in fi.locals.values()
            .need_resolved(v.ty, fi.node, "variable '{v.name}' in {fi.name}")
        if fi.cache and is_p(fi.ret, UNIT) then .err("@cache function must return a value", fi.node)
        fi.state = "done"
        .cur = saved_cur
        .scopes = saved_scopes
        .lams = saved_lams
        .tscope = saved_ts

    fn lookup(name str) Var?
        i = len(.scopes) - 1
        while i >= 0
            if name in .scopes[i] then return .scopes[i][name]
            i -= 1
        if .cur != nil
            if name in .cur.locals then return .cur.locals[name]
            v = .outer_var(.cur, name)
            if v != nil then return v
        .globals.get(name)

    # переменная из функции, внутри которой объявлена вложенная функция fi
    fn outer_var(fi0 Fn, name str) Var?
        fi = fi0
        while fi.parent != nil
            par = fi.parent
            i = len(fi.parent_scopes) - 1
            while i >= 0
                if name in fi.parent_scopes[i] then return fi.parent_scopes[i][name]
                i -= 1
            if name in par.locals and par.locals[name].kind != "global" then return par.locals[name]
            fi = par
        nil

    # ---------- инструкции ----------

    fn block(stmts [N])
        for s in stmts
            .stmt(s)

    fn stmt(s N)
        k = s.kind
        if k == "ExprStmt"
            .expr(s.kids[0])
        elif k == "Assign"
            .s_Assign(s)
        elif k == "AnnAssign"
            .s_AnnAssign(s)
        elif k == "AugAssign"
            .s_AugAssign(s)
        elif k == "If"
            for b in s.kids[0].kids
                .cond(b.kids[0])
                .block(b.kids[1].kids)
            if not isn(s.kids[1]) then .block(s.kids[1].kids)
        elif k == "While"
            .cond(s.kids[0])
            .block(s.kids[1].kids)
        elif k == "For"
            elem = .iter_elem(s.kids[1], s.kids[0])
            .assign_to(s.kids[0], elem, s)
            .block(s.kids[2].kids)
        elif k == "Return"
            .s_Return(s)
        elif k == "Break" or k == "Continue" or k == "Pass"
            pass
        elif k == "Fail"
            .s_Fail(s)
        elif k == "Assert"
            .cond(s.kids[0])
            if not isn(s.kids[1]) then .expr(s.kids[1])
        elif k == "With"
            .s_With(s)
        elif k == "Try"
            .s_Try(s)
        elif k == "Match"
            st = .expr(s.kids[0], true)
            .need_resolved(st, s.kids[0], "the match subject")
            for arm in s.kids[1].kids
                .pattern(arm.kids[0], st, arm, false)
                if not isn(arm.kids[1]) then .cond(arm.kids[1])
                .block(arm.kids[2].kids)
        elif k == "FnDef"
            .s_FnDef(s)
        elif k == "Record" or k == "SumType"
            .err("types must be defined at the top level", s)
        else
            .err("{k.lower()} {UNSUPPORTED}", s)
        pass

    fn assign_to(t N, vt Ty, node N, src N? = nil)
        if t.kind == "Name"
            var = .lookup(nm(t))
            if var == nil then .err("cannot assign to '{nm(t)}'", t)
            v = .lookup(nm(t))
            .set_ty(t, v.ty)
            .expect(v.ty, vt, node, "assignment to '{nm(t)}'", src)
        elif t.kind == "TupleLit"
            pv = prune(vt)
            items = t.kids[0].kids
            if pv.k != "tuple" or len(pv.a) != len(items)
                .err("cannot unpack {show(vt)} into {len(items)} names", node)
            .set_ty(t, vt)
            for item, it in zip(items, pv.a)
                .assign_to(item, it, node)
        else
            tt = .expr(t, true)
            if t.kind == "Index" and t.s != "list" and t.s != "dict"
                .err("cannot assign into {show(.ty_of(t.kids[0]))}", t)
            .expect(tt, vt, node, "assignment", src)
        pass

    fn s_Assign(s N)
        targets = s.kids[0].kids
        want: Ty? = nil
        if len(targets) == 1 and targets[0].kind == "Name"
            var = .lookup(nm(targets[0]))
            if var != nil then want = var.ty
        vt = .expr(s.kids[1], true, want)
        if is_p(vt, UNIT) then .err("this expression has no value", s.kids[1])
        for t in targets
            .assign_to(t, vt, s, s.kids[1])

    fn s_AnnAssign(s N)
        want = .to_type(s.kids[1])
        var = .lookup(nm(s.kids[0]))
        .expect(var.ty, want, s, "variable '{nm(s.kids[0])}'")
        .assign_to(s.kids[0], .expr(s.kids[2], true, want), s, s.kids[2])

    fn s_AugAssign(s N)
        if s.kids[0].kind == "TupleLit" then .err("cannot use an augmented assignment with several targets", s)
        tt = .expr(s.kids[0], true)
        op = s.kids[1].s
        binop = mk("BinOp", s.line, [S(op[:len(op) - 1]), s.kids[0], s.kids[2]])
        t = .expr(binop)
        if prune(tt).k == "opt"
            .expect(tt, t, s, "'{op}'", binop)  # x += 1 для x: int? — это x = x + 1 с проверкой на nil
            return
        .expect(tt, t, s, "'{op}'")

    fn cond(e N)
        t = .expr(e, true)
        if not truthy_ok(t) then .err("a condition must be bool, number, str, list or dict, not {show(t)}", e)
        pass

    fn iter_elem(it_node N, target N) Ty
        t = prune(.expr(it_node))
        if t.id == RANGE.id then return INT
        if t.k == "list" or t.k == "set" then return t.a[0]
        if t.k == "dict"
            if target.kind == "TupleLit" and len(target.kids[0].kids) == 2 then return tuple_t([t.a[0], t.a[1]])
            return t.a[0]
        if t.id == STR.id then return STR
        if t.k == "tvar" then .err("cannot iterate over a value of unknown type" + .typed_hint(t), it_node)
        .err("cannot iterate over {show(t)}", it_node)
        UNIT

    fn block_lambda() bool = len(.lams) > 0 and .lams[len(.lams) - 1].block

    fn s_Return(s N)
        value = s.kids[0]
        if .block_lambda()
            lam = .lams[len(.lams) - 1]
            t = if isn(value) then UNIT else .expr(value, true, lam.ret)
            if is_nil(value) and prune(lam.ret).k == "tvar"
                .err("the lambda returns nil here, but its result type is unknown", s)
            .expect(lam.ret, t, s, "lambda result", opt_n(value))
            return
        if .cur.is_top then .err("return outside a function", s)
        t = if isn(value) then UNIT else .expr(value, true, .cur.ret)
        if is_nil(value) and prune(.cur.ret).k == "tvar"
            .err("{.cur.name}() returns nil here: declare its return type, e.g. fn {.cur.name}(...) int?", s)
        .expect(.cur.ret, t, s, "{.cur.name}() result", opt_n(value))

    fn s_Fail(s N)
        v = s.kids[0]
        if v.kind == "Call" and v.kids[0].kind == "Name" and nm(v.kids[0]) in ERROR_KINDS
            fid = nm(v.kids[0])
            if fid not in .fns and fid not in .records and fid not in .variants
                # fail ValueError("bad input") — встроенный вид с сообщением
                args = v.kids[1].kids
                if v.kids[2].kids or len(args) > 1 then .err("{fid}() takes one message argument", v)
                if args
                    if is_p(.expr(args[0]), UNIT) then .err("the error message needs a value", args[0])
                return
        t = prune(.expr(v))
        if t.id == UNIT.id then .err("fail needs a value", s)

    # catch Kind: встроенный вид, запись, тип-сумма или один её вариант
    fn handler_kind(h N) Ty
        if isn(h.kids[0]) then return STR
        kind = h.kids[0].s
        if kind == "Exception" then return STR
        t: Ty? = nil
        if kind in .records
            t = .records[kind]
        elif kind in .sums
            t = .sums[kind]
        elif kind in .variants
            t = .variants[kind]
        if t == nil
            if kind in ERROR_KINDS then return STR
            .err("unknown error kind '{kind}'; catch a record or sum type, or one of: " +
                 "{', '.join(ERROR_KINDS)}", h)
        if t.params then .err("catch on a generic type {UNSUPPORTED}", h)
        t

    fn s_With(s N)
        for item in s.kids[0].kids
            ex = item.kids[0]
            t = prune(.expr(ex))
            if is_gen(t) and t.a then .err("with on a generic type {UNSUPPORTED}", ex)
            ms: {str: Fn} = {}
            if is_gen(t) then ms = meths(t)
            if "exit" not in ms and "enter" not in ms
                .err("with needs a record with exit() (and optionally enter()) methods, not {show(t)}", ex)
            for mname in ["enter", "exit"]
                if mname not in ms then continue
                fi = ms[mname]
                if fi.params then .err("{show(t)}.{mname}() must take no arguments", ex)
                if fi.is_async then .err("{show(t)}.{mname}() cannot be async", ex)
                .ensure(fi)
            if not isn(item.kids[1])
                name = item.kids[1].s
                var = .lookup(name)
                vt = if "enter" in ms then ms["enter"].ret else t
                .expect(var.ty, vt, ex, "with ... as {name}")
        .block(s.kids[1].kids)

    fn s_Try(s N)
        .block(s.kids[0].kids)
        for h in s.kids[1].kids
            vt = .handler_kind(h)
            if not isn(h.kids[1]) and vt.id != STR.id
                name = h.kids[1].s
                hscope: {str: Var} = {}
                hscope[name] = Var(name, vt, "comp")
                .scopes.append(hscope)
                .block(h.kids[2].kids)
                .scopes.pop()
                continue
            if not isn(h.kids[1])
                name = h.kids[1].s
                var = .lookup(name)
                .expect(var.ty, STR, h, "catch variable '{name}' (it holds the message)")
            .block(h.kids[2].kids)

    fn pattern(p N, t0 Ty, node N, in_or bool)
        t = prune(t0)
        k = p.kind
        if k == "PWild" then return
        if t.k == "opt" and k != "PCapture" and k != "POr"
            if k == "PLit" and is_nil(p.kids[0])
                .expr(p.kids[0], true)
                .set_ty(p, t)
                return
            .pattern(p, t.a[0], node, in_or)  # остальные образцы сначала проверяют, что значение не nil
            return
        if k == "PLit" and is_nil(p.kids[0]) then .err("pattern nil cannot match {show(t)}, which is never nil", p)
        if k == "PCapture" or k == "PStar"
            if in_or then .err("names cannot be bound inside '|' patterns", p)
            var = .lookup(nm(p))
            if k == "PStar" then return  # тип проверяет PList
            .expect(var.ty, t, p, "pattern variable '{nm(p)}'")
            return
        if k == "PLit"
            lt = .expr(p.kids[0])
            if not (same(lt, t) or (t.id == FLOAT.id and is_p(lt, INT)))
                .err("pattern {show(lt)} cannot match {show(t)}", p)
            .set_ty(p, t)
            return
        if k == "PClass"
            pname = nm(p)
            fields: [Field] = []
            if t.k == "sum"
                vs = variants_of(t)
                if pname not in vs then .err("'{pname}' is not a variant of {t.name}", p)
                fields = vs[pname]
            elif t.k == "record" and pname == t.name
                fs = fields_of(t)
                fields = [Field(n, fs[n]) for n in fs]
            else
                .err("pattern {pname}(...) cannot match {show(t)}", p)
            args = p.kids[1].kids
            if len(args) > len(fields) then .err("{pname} has {len(fields)} field(s), pattern gives {len(args)}", p)
            for fd, sub in zip(fields, args)
                if sub.kind != "PWild" then .private(t, fd.name, p, "field")
                .pattern(sub, fd.ty, node, in_or)
            names = [f.name for f in fields]
            for kv in p.kids[2].kids
                kname = kv.kids[0].s
                if kname not in names then .err("{pname} has no field '{kname}'", p)
                .private(t, kname, p, "field")
                ft = UNIT
                for f in fields
                    if f.name == kname then ft = f.ty
                .pattern(kv.kids[1], ft, node, in_or)
            return
        if k == "PTuple"
            items = p.kids[0].kids
            if t.k != "tuple" or len(t.a) != len(items)
                .err("tuple pattern of {len(items)} cannot match {show(t)}", p)
            for sub, it in zip(items, t.a)
                .pattern(sub, it, node, in_or)
            return
        if k == "PList"
            if t.k != "list" then .err("list pattern cannot match {show(t)}", p)
            items = p.kids[0].kids
            stars = [i for i, sub in enumerate(items) if sub.kind == "PStar"]
            if len(stars) > 1 or (stars and stars[0] != len(items) - 1)
                .err("only one *rest at the end of a list pattern is supported", p)
            for sub in items
                if sub.kind == "PStar"
                    .pattern(sub, t, node, in_or)
                    .expect(.lookup(nm(sub)).ty, t, sub, "pattern variable '{nm(sub)}'")
                else
                    .pattern(sub, t.a[0], node, in_or)
            return
        if k == "POr"
            for alt in p.kids[0].kids
                .pattern(alt, t, node, true)
            return
        .err("this pattern {UNSUPPORTED}", p)

    # вложенная функция: замыкание с телом-блоком, видит переменные снаружи
    fn s_FnDef(s N)
        if .lams then .err("a named fn cannot be declared inside a lambda; declare it before the lambda", s)
        if s.kids[5].kids then .err("decorators on nested functions {UNSUPPORTED}", s)
        if flag(s.kids[4]) then .err("nested async functions {UNSUPPORTED}", s)
        fi = Fn(s, nm(s), tv(), parent=.cur, parent_scopes=.scopes[:])
        .signature(fi)
        ft = fn_t([p.ty for p in fi.params], fi.ret)
        fi.recvar = Var(nm(s), ft, "rec")
        var = .lookup(nm(s))
        .expect(var.ty, ft, s, "function '{nm(s)}'")
        .check_fn(fi)

    # ---------- выражения ----------

    # тип выражения; если opt = false, значение T? сразу проверяется на nil и даёт T
    fn expr(e N, opt = false, want Ty? = nil) Ty
        k = e.kind
        t = UNIT
        if k == "Lambda"
            t = .e_Lambda(e, want)
        elif k == "ListLit"
            t = .e_ListLit(e, want)
        elif k == "DictLit"
            t = .e_DictLit(e, want)
        elif k == "Call"
            t = .e_Call(e, want)
        else
            t = .dispatch(e)
        .set_ty(e, t)
        pt = prune(t)
        if not opt and pt.k == "opt"
            if is_nil(e) then .err("nil cannot be used here", e)
            return pt.a[0]
        t

    fn dispatch(e N) Ty
        k = e.kind
        if k == "Num"
            s = nm(e)
            return if s.find(".") >= 0 or s.find("e") >= 0 or s.find("E") >= 0 then FLOAT else INT
        if k == "Str" then return .e_Str(e)
        if k == "Const"
            if nm(e) == "None"
                .nils.append(e)
                return opt_t(tv())
            return BOOL
        if k == "Name" then return .e_Name(e)
        if k == "SelfAttr" then return .e_SelfAttr(e)
        if k == "Attr" then return .e_Attr(e)
        if k == "Index" then return .e_Index(e)
        if k == "BinOp" then return .e_BinOp(e)
        if k == "Compare" then return .e_Compare(e)
        if k == "Unary" then return .e_Unary(e)
        if k == "IfExpr" then return .e_IfExpr(e)
        if k == "Range"
            .expect(INT, .expr(e.kids[0]), e.kids[0], "range start")
            .expect(INT, .expr(e.kids[1]), e.kids[1], "range end")
            return RANGE
        if k == "TupleLit" then return tuple_t([.expr(i, true) for i in e.kids[0].kids])
        if k == "SetLit" then return .e_SetLit(e)
        if k == "Comp" then return .e_Comp(e)
        if k == "Await" then return .e_Await(e)
        .err("{k.lower()} {UNSUPPORTED}", e)
        UNIT

    fn e_Str(e N) Ty
        for part in e.kids[0].kids
            if part.kind == "Interp"
                spec = part.kids[1]
                t = .expr(part.kids[0], isn(spec))
                if is_p(t, UNIT) then .err("this expression has no value", part.kids[0])
                if not isn(spec) and not (is_p(t, INT) or is_p(t, FLOAT) or is_p(t, STR))
                    .err("format spec needs int, float or str, not {show(t)}", part.kids[0])
        STR

    fn e_Name(e N) Ty
        id = nm(e)
        var = .lookup(id)
        if var != nil then return var.ty
        if id == "True" or id == "False" then return BOOL  # привычка из Python
        if id == "pi" or id in NATIVE_CONSTS then return FLOAT
        if id in BUILTINS and id.find(".") >= 0 then .err("'{id}' is a function; call it: {id}(...)", e)
        if id in .variants
            st = .variants[id]
            if st.variants[id] then .err("'{id}' needs its fields: {id}(...)", e)
            if st.params
                st = instantiate(st, [tv() for _ in st.params])
                .nils.append(e)  # print Empty: тип без контекста станет Opt[int]
            return st
        if id in .fns
            fi = .fns[id]
            if fi.tparams
                ps = ", ".join([p.name for p in fi.params])
                .err("generic function '{id}' cannot be used as a value; wrap it: fn({ps}) = {id}({ps})", e)
            .ensure(fi)
            return fn_t([p.ty for p in fi.params], .call_ret(fi))
        if id in BUILTINS then .err("built-in '{id}' cannot be used as a value; wrap it: fn(x) = {id}(x)", e)
        .err("unknown name '{id}'", e)
        UNIT

    # функция, чей метод сейчас проверяется (в том числе изнутри вложенной функции)
    fn owner() Fn?
        fi = .cur
        while fi != nil and fi.owner == nil
            fi = fi.parent
        fi

    fn e_SelfAttr(e N) Ty
        fi = .owner()
        name = nm(e)
        if fi == nil then .err("'.{name}' used outside a method", e)
        o = .owner().owner
        if o.k != "record" or name not in fields_of(o) then .err("{show(o)} has no field '{name}'", e)
        .lookup("self")  # внутри лямбды self попадает в окружение
        fields_of(o)[name]

    fn e_Attr(e N) Ty
        t = prune(.expr(e.kids[0]))
        name = e.kids[1].s
        if t.k == "record"
            fs = fields_of(t)
            if name not in fs then .err("{t.name} has no field '{name}'", e)
            .private(t, name, e, "field")
            return fs[name]
        .err("{show(t)} has no field '{name}'", e)
        UNIT

    fn e_Index(e N) Ty
        t = prune(.expr(e.kids[0]))
        idx = e.kids[1]
        if idx.kind == "Slice"
            if not (t.k == "list" or t.id == STR.id) then .err("cannot slice {show(t)}", e)
            if not isn(idx.kids[2]) then .err("slice step {UNSUPPORTED}", e)
            for part in [idx.kids[0], idx.kids[1]]
                if not isn(part) then .expect(INT, .expr(part), part, "slice bound")
            e.s = if t.k == "list" then "slice_list" else "slice_str"
            return t
        if t.k == "list"
            .expect(INT, .expr(idx), idx, "list index")
            e.s = "list"
            return t.a[0]
        if t.k == "dict"
            .expect(t.a[0], .expr(idx), idx, "dict key")
            e.s = "dict"
            return t.a[1]
        if t.id == STR.id
            .expect(INT, .expr(idx), idx, "string index")
            e.s = "str"
            return STR
        if t.k == "tuple"
            neg = idx.kind == "Unary" and idx.kids[0].s == "-" and idx.kids[1].kind == "Num"
            if not (idx.kind == "Num" or neg) then .err("tuple index must be a number literal", idx)
            text = if neg then nm(idx.kids[1]) else nm(idx)
            if text.find(".") >= 0 then .err("tuple index must be a number literal", idx)
            i = int(text.replace("_", ""))
            if neg then i = -i
            if i < 0 then i += len(t.a)
            if i < 0 or i >= len(t.a) then .err("tuple index out of range", idx)
            e.s = "tuple"
            return t.a[i]
        if t.k == "tvar" then .err("cannot index a value of unknown type" + .typed_hint(t), e)
        .err("cannot index {show(t)}", e)
        UNIT

    fn bind_args(call N, params [PInfo], what str, stars {str: int})
        s1 = if "*" in stars then stars["*"] else -1
        s2 = if "**" in stars then stars["**"] else -1
        si = s1
        ki = s2
        args = call.kids[1].kids[:]
        bound: [N?] = []
        for _ in params
            bound.append(nil)
        ai = -1
        nspread = 0
        for i, a in enumerate(args)
            if a.kind == "Starred"
                nspread += 1
                if ai < 0 then ai = i
        if ai >= 0
            # f(a, *xs) и f(**opts): список или словарь целиком идёт в *args / **kwargs
            a = args[ai]
            dbl = flag(a.kids[1])
            want_i = if dbl then ki else si
            if want_i < 0
                .err("{what} has no {if dbl then '**kwargs' else '*args'} parameter to unpack into", a)
            if nspread > 1 or (not dbl and ai != len(args) - 1)
                .err("only one *list may be passed, as the last positional argument", a)
            args = args[:ai] + args[ai + 1:]
            bound[want_i] = a.kids[0]
            if not dbl then si = -1  # *args уже заполнен
        positional = [i for i in 0..len(params) - 1 if i != s1 and i != s2 and (s1 < 0 or i < s1)]
        if len(args) > len(positional) and si < 0
            .err("{what} takes {len(positional)} argument(s), got {len(args)}", call)
        for i, a in zip(positional, args)
            bound[i] = a
        if si >= 0
            bound[si] = mk("ListLit", call.line, [L(args[len(positional):])])
        names = [p.name for p in params]
        extra_kw: [N] = []
        for kv in call.kids[2].kids
            k = kv.kids[0].s
            v = kv.kids[1]
            if k not in names or names.index(k) == s1 or names.index(k) == s2
                if ki >= 0
                    extra_kw.append(T([mk("Str", call.line, [L([S(k)]), S("\"")]), v]))
                    continue
                .err("{what} has no parameter '{k}'", call)
            i = names.index(k)
            if bound[i] != nil then .err("argument '{k}' given twice", call)
            bound[i] = v
        if ki >= 0 and bound[ki] == nil then bound[ki] = mk("DictLit", call.line, [L(extra_kw)])
        for i, p in enumerate(params)
            if bound[i] == nil
                if p.default == nil then .err("{what} is missing argument '{p.name}'", call)
                bound[i] = copy_n(p.default)  # свой узел: у Stack[int]() и Stack[str]() разные типы []
            b: N = bound[i]
            at = .expr(b, true, p.ty)
            .expect(p.ty, at, b, "argument '{p.name}' of {what}", b)

    # выражение в квадратных скобках Stack[int]() как тип
    fn expr_type(n N) N
        k = n.kind
        if k == "Name" then return mk("TName", n.line, [S(nm(n)), L([])])
        if k == "Index" and n.kids[0].kind == "Name"
            idx = n.kids[1]
            items = if idx.kind == "TupleLit" then idx.kids[0].kids else [idx]
            return mk("TName", n.line, [S(nm(n.kids[0])), L([.expr_type(i) for i in items])])
        if k == "ListLit" and len(n.kids[0].kids) == 1 then return mk("TList", n.line, [.expr_type(n.kids[0].kids[0])])
        if k == "SetLit" and len(n.kids[0].kids) == 1 then return mk("TSet", n.line, [.expr_type(n.kids[0].kids[0])])
        if k == "DictLit" and len(n.kids[0].kids) == 1 and not isn(n.kids[0].kids[0].kids[0])
            kv = n.kids[0].kids[0]
            return mk("TDict", n.line, [.expr_type(kv.kids[0]), .expr_type(kv.kids[1])])
        if k == "TupleLit" then return mk("TTuple", n.line, [L([.expr_type(i) for i in n.kids[0].kids])])
        if k == "Str" and len(n.kids[0].kids) == 1 and n.kids[0].kids[0].kind == "str"
            return mk("TName", n.line, [S(n.kids[0].kids[0].s), L([])])  # {name: int}: ключ-слово стал строкой
        .err("expected a type in [...]", n)
        n

    # f[int](...) / Box[str](...): явные параметры типа
    fn explicit_targs(e N, params [Ty], what str, ex [Ty], has_ex bool) [Ty]
        if not has_ex then return [tv() for _ in params]
        if not params then .err("{what} has no type parameters", e)
        if len(ex) != len(params) then .err("{what} takes {len(params)} type argument(s), got {len(ex)}", e)
        ex

    fn e_Call(e N, want Ty? = nil) Ty
        f = e.kids[0]
        ex: [Ty] = []
        has_ex = false
        if f.kind == "Index" and f.kids[0].kind == "Name" and .lookup(nm(f.kids[0])) == nil
            fid = nm(f.kids[0])
            if fid in .fns or fid in .records or fid in .variants
                idx = f.kids[1]
                items = if idx.kind == "TupleLit" then idx.kids[0].kids else [idx]
                ex = [.to_type(.expr_type(i)) for i in items]
                has_ex = true
                f = f.kids[0]
                e.kids[0] = f
        if f.kind == "SelfAttr" and .owner() != nil
            if nm(f) in meths(.owner().owner)
                f = mk("Attr", f.line, [mk("Name", f.line, [S("self")]), S(nm(f))])  # .other() внутри метода
                e.kids[0] = f
        if f.kind == "Name"
            name = nm(f)
            if .lookup(name) != nil then return .call_value(e)
            if name in .fns
                fi = .fns[name]
                dn = dname(fi.node)  # имя, как в исходнике модуля
                if fi.tparams or has_ex
                    targs = .explicit_targs(e, fi.tparams, "{dn}()", ex, has_ex)
                    m: {int: Ty} = {}
                    for P, a in zip(fi.tparams, targs)
                        m[P.id] = a
                    return .generic_call(e, fi, "{dn}()", m)
                .bind_args(e, fi.params, "{dn}()", fi.stars)
                .ensure(fi)  # вывести тип результата до использования
                return .call_ret(fi)
            if name in .records
                rt = .records[name]
                targs = .explicit_targs(e, rt.params, "type '{show(rt)}'", ex, has_ex)
                if rt.params then rt = instantiate(rt, targs)
                fs = fields_of(rt)
                defs = base_of(rt).defaults
                params = [PInfo(fname, fs[fname], defs.get(fname)) for fname in fs]
                anypriv = false
                for p in params
                    if p.name.startswith("_") then anypriv = true
                if anypriv and .mod_of(e) != base_of(rt).mod
                    # снаружи модуля приватные поля получают значения по умолчанию
                    for p in params
                        if p.name.startswith("_") and p.default == nil
                            .err("{show(rt)} has private field '{p.name}' without a default; create it with a " +
                                 "function from its module", e)
                    pub = [p for p in params if not p.name.startswith("_")]
                    privkw = false
                    for kv in e.kids[2].kids
                        if kv.kids[0].s.startswith("_") then privkw = true
                    if len(e.kids[1].kids) > len(pub) or privkw
                        pubs = ", ".join([p.name for p in pub])
                        .err("{show(base_of(rt))}() outside its module takes only public fields " +
                             "({if pubs == '' then 'none' else pubs}); private fields are set by the module", e)
                    .bind_args(e, pub, "{show(base_of(rt))}()", {})
                    for p in params
                        if p.name.startswith("_")
                            node = copy_n(p.default)
                            .expect(p.ty, .expr(node, true, p.ty), node, "field '{p.name}'", node)
                else
                    .bind_args(e, params, "{show(base_of(rt))}()", {})
                return rt
            if name in .variants
                st = .variants[name]
                targs = .explicit_targs(e, st.params, "type '{show(st)}'", ex, has_ex)
                if st.params then st = instantiate(st, targs)
                params = [PInfo(fd.name, fd.ty, nil) for fd in variants_of(st)[name]]
                .bind_args(e, params, "{name}()", {})
                return st
            if name in BUILTINS then return .builtin(e, name, want)
            .err("unknown function '{name}'", e)
        if f.kind == "Attr"
            rt = prune(.expr(f.kids[0]))
            fname = f.kids[1].s
            if rt.id == RESPONSE.id and fname == "json"  # r.json(): тип результата — из контекста
                e.kids[0] = mk("Name", f.line, [S("http.response_json")])
                e.kids[1] = L([f.kids[0]] + e.kids[1].kids)
                return .e_Call(e, want)
            if is_gen(rt) and fname in meths(rt)
                .private(rt, fname, e, "method")
                fi = meths(rt)[fname]
                if fi.allparams then return .generic_call(e, fi, "{show(rt)}.{fname}()", targ_map(rt))
                .bind_args(e, fi.params, "{rt.name}.{fname}()", fi.stars)
                .ensure(fi)
                return .call_ret(fi)
            if rt.k == "record" and fname in fields_of(rt) then return .call_value(e)
            it = rt
            if rt.k == "tparam" and rt.bound != nil then it = rt.bound
            if it.k == "iface"
                # s.area() у интерфейса — через таблицу методов; у T: Shape — метод настоящего типа
                if fname not in it.imethods
                    extra = if it.id != rt.id then " (its bound {show(it)} does not declare it)" else ""
                    .err("{show(rt)} has no method '{fname}'" + extra, e)
                sig = it.imethods[fname]
                .bind_args(e, [PInfo(p.name, p.ty, nil) for p in sig.params], "{show(rt)}.{fname}()", {})
                return sig.ret
            if rt.k == "tparam"
                .err("{rt.name} has no method '{fname}': give it a bound, e.g. [{rt.name}: Iface], " +
                     "where interface Iface declares fn {fname}(...)", e)
            return .bmethod(e, rt, fname)
        .call_value(e)

    # вызов значения-функции (лямбды, параметра типа fn(...))
    fn call_value(e N) Ty
        ft = prune(.expr(e.kids[0]))
        if ft.k == "tvar" then .err("cannot call a value of unknown type", e)
        if ft.k != "fn" then .err("{show(ft)} is not a function", e)
        if e.kids[2].kids then .err("a function value takes positional arguments only", e)
        args = e.kids[1].kids
        ps = fn_params(ft)
        if len(args) != len(ps) then .err("function takes {len(ps)} argument(s), got {len(args)}", e)
        for i, a in enumerate(args)
            .expect(ps[i], .expr(a, true, ps[i]), a, "argument {i + 1}", a)
        fn_ret(ft)

    # аргумент-функция встроенного метода: map(fn(x) = ...) и т. п.
    fn fnarg(node N, params [Ty], ret Ty, what str) Ty
        ft = prune(.expr(node, false, fn_t(params, ret)))
        if ft.k != "fn" or len(fn_params(ft)) != len(params)
            .err("{what} needs a function of {len(params)} argument(s), not {show(ft)}", node)
        for a, b in zip(fn_params(ft), params)
            if not .unify(a, b) then .err("{what}: the function takes {show(a)}, but gets {show(b)}", node)
        fn_ret(ft)

    fn kwarg(e N, name str) N?
        for kv in e.kids[2].kids
            if kv.kids[0].s == name then return kv.kids[1]
        nil

    fn args(e N, name str, lo int, hi0 int = -1, kw [str] = [], opt = false) [Ty]
        hi = if hi0 < 0 then lo else hi0
        n = len(e.kids[1].kids)
        if n < lo or n > hi
            w = if lo == hi then "{lo}" else "{lo}-{hi}"
            .err("{name}() takes {w} argument(s), got {n}", e)
        for kv in e.kids[2].kids
            if kv.kids[0].s not in kw then .err("{name}() has no parameter '{kv.kids[0].s}'", e)
        [.expr(a, opt) for a in e.kids[1].kids]

    fn arg(e N, i int) N = e.kids[1].kids[i]

    fn seq_elem(e N, t0 Ty, what str) Ty
        t = prune(t0)
        if t.k == "list" or t.k == "set" then return t.a[0]
        if t.id == RANGE.id then return INT
        .err("{what}() needs a list, set or range, not {show(t)}", e)
        UNIT

    fn sort_kwargs(e N, elem Ty, what str)
        rev = .kwarg(e, "reverse")
        if rev != nil then .expect(BOOL, .expr(rev), rev, "reverse")
        keyf = .kwarg(e, "key")
        if keyf != nil
            kt = .fnarg(keyf, [elem], tv(), "{what} key")
            if not comparable(kt) then .err("{what} key must be comparable, not {show(kt)}", keyf)
        elif not comparable(elem)
            .err("cannot sort {show(elem)}", e)
        pass

    fn http_kw(e N)
        for kv in e.kids[2].kids
            k = kv.kids[0].s
            v = kv.kids[1]
            if k == "timeout"
                if not .numeric(.expr(v)) then .err("timeout must be a number of seconds", v)
            elif k == "headers"
                .expect(dict_t(STR, STR), .expr(v), v, "headers")
            elif k == "body"
                .expect(STR, .expr(v), v, "body")
            elif k == "json"
                .expr(v, true)
        if .kwarg(e, "body") != nil and .kwarg(e, "json") != nil
            .err("http.post(): give either body: or json:, not both", e)
        pass

    fn builtin(e N, name str, want Ty?) Ty
        if name in NATIVE_SIGS
            sig = NATIVE_SIGS[name]
            lo = if name == "math.log" then 1 else len(sig.params)
            ts = .args(e, name, lo, len(sig.params))
            for i, t in enumerate(ts)
                w = sig.params[i]
                if w.id == NUM.id
                    if not .numeric(t) then .err("{name}() needs a number, not {show(t)}", .arg(e, i))
                else
                    .expect(w, t, .arg(e, i), "{name}() argument {i + 1}")
            return sig.ret
        if name == "print"
            for kv in e.kids[2].kids
                .err("print() has no parameter '{kv.kids[0].s}'", e)
            for a in e.kids[1].kids
                if is_p(.expr(a, true), UNIT) then .err("this expression has no value", a)
            return UNIT
        if name == "len"
            t = .args(e, name, 1)[0]
            pt = prune(t)
            if not (pt.id == STR.id or pt.id == RANGE.id or pt.k == "list" or pt.k == "dict" or pt.k == "tuple" or
                    pt.k == "set")
                .err("len() needs str, list, dict, tuple or range, not {show(t)}", e)
            return INT
        if name == "str"
            t = .args(e, name, 1, -1, [], true)[0]
            if is_p(t, UNIT) then .err("this expression has no value", e)
            return STR
        if name == "int"
            t = .args(e, name, 1)[0]
            pt = prune(t)
            if not (pt.id == STR.id or pt.id == INT.id or pt.id == FLOAT.id or pt.id == BOOL.id)
                .err("int() needs str, int, float or bool, not {show(t)}", e)
            return INT
        if name == "float"
            t = .args(e, name, 1)[0]
            pt = prune(t)
            if not (pt.id == STR.id or pt.id == INT.id or pt.id == FLOAT.id)
                .err("float() needs str, int or float, not {show(t)}", e)
            return FLOAT
        if name == "bool"
            t = .args(e, name, 1, -1, [], true)[0]
            if not truthy_ok(t) then .err("bool() cannot convert {show(t)}", e)
            return BOOL
        if name == "abs"
            t = .args(e, name, 1)[0]
            if not .numeric(t) and not .num_param(t) then .err("abs() needs a number, not {show(t)}", e)
            return t
        if name == "ord"
            .expect(STR, .args(e, name, 1)[0], e, "ord() argument")
            return INT
        if name == "chr"
            .expect(INT, .args(e, name, 1)[0], e, "chr() argument")
            return STR
        if name == "min" or name == "max"
            ts = .args(e, name, 1, 16, ["key"])
            keyf = .kwarg(e, "key")
            if len(ts) == 1
                elem = .seq_elem(e, ts[0], name)
                if keyf != nil
                    kt = .fnarg(keyf, [elem], tv(), "{name}() key")
                    if not comparable(kt) then .err("{name}() key must be comparable, not {show(kt)}", keyf)
                elif not comparable(elem)
                    .err("{name}() cannot compare {show(elem)}", e)
                return elem
            if keyf != nil then .err("{name}(..., key:) works with one list argument", e)
            t = ts[0]
            for i in 1..len(ts) - 1
                t = .join(t, ts[i], .arg(e, i), "{name}() arguments")
            if not comparable(t) then .err("{name}() cannot compare {show(t)}", e)
            return t
        if name == "sum" or name == "avg"
            elem = .seq_elem(e, .args(e, name, 1)[0], name)
            if not .numeric(elem) and not .num_param(elem) then .err("{name}() needs numbers, not {show(elem)}", e)
            return if name == "sum" then elem else FLOAT
        if name == "any" or name == "all"
            elem = .seq_elem(e, .args(e, name, 1)[0], name)
            if not truthy_ok(elem) then .err("{name}() cannot test {show(elem)}", e)
            return BOOL
        if name == "sorted"
            t = .args(e, name, 1, -1, ["reverse", "key"])[0]
            pt = prune(t)
            if pt.k == "set" then pt = list_t(pt.a[0])
            if pt.k != "list" then .err("sorted() needs a list or set, not {show(t)}", e)
            .sort_kwargs(e, pt.a[0], "sorted()")
            return pt
        if name == "list"
            t = .args(e, name, 1)[0]
            pt = prune(t)
            if pt.id == RANGE.id then return list_t(INT)
            if pt.k == "list" then return pt
            if pt.id == STR.id then return list_t(STR)
            if pt.k == "dict" or pt.k == "set" then return list_t(pt.a[0])
            .err("list() cannot convert {show(t)}", e)
        if name == "set"
            ts = .args(e, name, 0, 1)
            if not ts
                .nils.append(e)
                return set_t(tv())  # set(): тип придёт из аннотации, s: {int} = set()
            pt = prune(ts[0])
            el = UNIT
            ok = true
            if pt.id == RANGE.id
                el = INT
            elif pt.id == STR.id
                el = STR
            elif pt.k == "dict" or pt.k == "list" or pt.k == "set"
                el = pt.a[0]
            else
                ok = false
            if not ok then .err("set() cannot convert {show(pt)}", e)
            if not hashable(el) then .err("set items must be hashable, not {show(el)}", e)
            return set_t(el)
        if name == "count"
            elem = .seq_elem(e, .args(e, name, 1)[0], "count")
            if not hashable(elem) then .err("count() needs hashable items, not {show(elem)}", e)
            return dict_t(elem, INT)
        if name == "read"
            .expect(STR, .args(e, name, 1)[0], e, "read() path")
            return STR
        if name == "write"
            ts = .args(e, name, 2)
            .expect(STR, ts[0], e, "write() path")
            .expect(STR, ts[1], e, "write() text")
            return UNIT
        if name == "input"
            ts = .args(e, name, 0, 1)
            if ts then .expect(STR, ts[0], e, "input() prompt")
            return STR
        if name == "round"
            ts = .args(e, name, 1, 2)
            if not .numeric(ts[0]) then .err("round() needs a number, not {show(ts[0])}", e)
            if len(ts) == 2
                .expect(INT, ts[1], e, "round() digits")
                return FLOAT
            return INT
        if name == "zip"
            ts = .args(e, name, 2)
            ea = .seq_elem(e, ts[0], "zip")
            eb = .seq_elem(e, ts[1], "zip")
            return list_t(tuple_t([ea, eb]))
        if name == "enumerate"
            t = .args(e, name, 1)[0]
            return list_t(tuple_t([INT, .seq_elem(e, t, "enumerate")]))
        if name == "exit"
            ts = .args(e, name, 0, 1)
            if ts then .expect(INT, ts[0], e, "exit() code")
            return UNIT
        if name == "json.parse" or name == "json.read"
            t = .args(e, name, 1)[0]
            .expect(STR, t, .arg(e, 0), "{name}() argument")
            return .typed_result(e, name)
        if name == "json.stringify"
            .args(e, name, 1, -1, ["indent"], true)
            ind = .kwarg(e, "indent")
            if ind != nil then .expect(INT, .expr(ind), ind, "indent")
            return STR
        if name == "json.write"
            ts = .args(e, name, 2, -1, ["indent"], true)
            .expect(STR, ts[0], .arg(e, 0), "json.write() path", .arg(e, 0))
            ind = .kwarg(e, "indent")
            if ind != nil then .expect(INT, .expr(ind), ind, "indent")
            return UNIT
        if name == "csv.read" or name == "csv.parse"
            t = .args(e, name, 1, -1, ["delimiter"])[0]
            .expect(STR, t, .arg(e, 0), "{name}() argument")
            d = .kwarg(e, "delimiter")
            if d != nil then .expect(STR, .expr(d), d, "delimiter")
            if want != nil
                pw = prune(want)
                if pw.k == "list" then return want
            return list_t(dict_t(STR, STR))
        if name == "csv.write"
            ts = .args(e, name, 2, -1, ["delimiter"])
            .expect(STR, ts[0], .arg(e, 0), "csv.write() path")
            if prune(ts[1]).k != "list" then .err("csv.write() needs a list of rows, not {show(ts[1])}", .arg(e, 1))
            d = .kwarg(e, "delimiter")
            if d != nil then .expect(STR, .expr(d), d, "delimiter")
            return UNIT
        if name == "http.get" or name == "http.post"
            kw = if name == "http.get" then ["timeout", "headers"] else ["timeout", "headers", "body", "json"]
            t = .args(e, name, 1, -1, kw)[0]
            .expect(STR, t, .arg(e, 0), "{name}() url")
            .http_kw(e)
            return RESPONSE
        if name == "http.response_json"
            ts = .args(e, "r.json", 1)
            .expect(RESPONSE, ts[0], .arg(e, 0), ".json()")
            return .typed_result(e, ".json")
        if name == "random.choice"
            t = .args(e, name, 1)[0]
            pt = prune(t)
            if pt.k != "list" then .err("random.choice() needs a list, not {show(t)}", e)
            return pt.a[0]
        if name == "random.shuffle"
            t = .args(e, name, 1)[0]
            if prune(t).k != "list" then .err("random.shuffle() needs a list, not {show(t)}", e)
            return UNIT
        .err("unknown function '{name}'", e)
        UNIT

    fn bmethod(e N, t0 Ty, name str) Ty
        t = prune(t0)
        if t.id == STR.id
            if name not in STR_METHODS then .err("str has no method '{name}'", e)
            return .str_method(e, name)
        if t.k == "list"
            if name not in LIST_METHODS then .err("list has no method '{name}'", e)
            return .list_method(e, t, name)
        if t.k == "dict"
            if name not in DICT_METHODS then .err("dict has no method '{name}'", e)
            return .dict_method(e, t, name)
        if t.k == "set"
            if name not in SET_METHODS then .err("set has no method '{name}'", e)
            return .set_method(e, t, name)
        if t.k == "tvar" then .err("cannot call .{name}() on a value of unknown type" + .typed_hint(t), e)
        .err("{show(t)} has no method '{name}'", e)
        UNIT

    fn str_method(e N, name str) Ty
        if name in ["lower", "upper", "strip", "lstrip", "rstrip", "capitalize", "title"]
            .args(e, name, 0)
            return STR
        if name == "splitlines"
            .args(e, name, 0)
            return list_t(STR)
        if name in ["isdigit", "isalpha", "isspace", "isalnum", "isupper", "islower"]
            .args(e, name, 0)
            return BOOL
        if name == "split"
            ts = .args(e, name, 0, 1)
            if ts then .expect(STR, ts[0], e, "split() separator")
            return list_t(STR)
        if name in ["startswith", "endswith", "find", "count", "rfind", "removeprefix", "removesuffix"]
            .expect(STR, .args(e, name, 1)[0], e, "{name}() argument")
            if name == "startswith" or name == "endswith" then return BOOL
            if name == "removeprefix" or name == "removesuffix" then return STR
            return INT
        if name == "replace"
            ts = .args(e, name, 2)
            .expect(STR, ts[0], e, "replace() old")
            .expect(STR, ts[1], e, "replace() new")
            return STR
        if name == "join"
            t = .args(e, name, 1)[0]
            if prune(t).k != "list" then .err("join() needs a list, not {show(t)}", e)
            return STR
        .expect(INT, .args(e, name, 1)[0], e, "{name}() width")  # zfill, ljust, rjust
        STR

    fn list_method(e N, t Ty, name str) Ty
        elem = t.a[0]
        if name == "append"
            x = .args(e, name, 1, -1, [], true)[0]
            .expect(elem, x, e, "append()", .arg(e, 0))
            return UNIT
        if name == "pop"
            ts = .args(e, name, 0, 1)
            if ts then .expect(INT, ts[0], e, "pop() index")
            return elem
        if name == "insert"
            ts = .args(e, name, 2, -1, [], true)
            .expect(INT, ts[0], e, "insert() index", .arg(e, 0))
            .expect(elem, ts[1], e, "insert() value", .arg(e, 1))
            return UNIT
        if name == "extend"
            .expect(t, .args(e, name, 1)[0], e, "extend()")
            return UNIT
        if name == "clear" or name == "reverse"
            .args(e, name, 0)
            return UNIT
        if name == "copy"
            .args(e, name, 0)
            return t
        if name == "index"
            .expect(elem, .args(e, name, 1)[0], e, "index()")
            return INT
        if name == "count"
            ts = .args(e, name, 0, 1)
            if ts
                .expect(elem, ts[0], e, "count()")
                return INT
            if not hashable(elem) then .err("count() needs hashable items, not {show(elem)}", e)
            return dict_t(elem, INT)
        if name == "sort"
            .args(e, name, 0, -1, ["reverse", "key"])
            .sort_kwargs(e, elem, "sort()")
            return UNIT
        if name == "join"
            ts = .args(e, name, 0, 1)
            if ts then .expect(STR, ts[0], e, "join() separator")
            return STR
        if name == "sum" or name == "avg"
            .args(e, name, 0)
            if not .numeric(elem) then .err("{name}() needs numbers, not {show(elem)}", e)
            return if name == "avg" then FLOAT else elem
        if name == "top"
            ts = .args(e, name, 0, 1)
            if ts then .expect(INT, ts[0], e, "top() count")
            if not hashable(elem) then .err("top() needs hashable items, not {show(elem)}", e)
            return list_t(tuple_t([elem, INT]))
        if name == "map" or name == "filter" or name == "group_by"
            if len(e.kids[1].kids) != 1 or e.kids[2].kids then .err("{name}() takes a function", e)
            ret = .fnarg(.arg(e, 0), [elem], tv(), "{name}()")
            if name == "map"
                if is_p(ret, UNIT) then .err("map() needs a function that returns a value", e)
                return list_t(ret)
            if name == "filter"
                if not truthy_ok(ret) then .err("filter() function must return bool, not {show(ret)}", e)
                return t
            if not hashable(ret)
                .err("group_by() key must be int, float, bool, str or a tuple, not {show(ret)}", e)
            return dict_t(ret, t)
        if name == "sort_by"
            if len(e.kids[1].kids) != 1 then .err("sort_by() takes a function", e)
            for kv in e.kids[2].kids
                if kv.kids[0].s != "reverse" then .err("sort_by() has no parameter '{kv.kids[0].s}'", e)
            e.kids[2] = L(e.kids[2].kids + [T([S("key"), .arg(e, 0)])])
            .sort_kwargs(e, elem, "sort_by()")
            return t
        .args(e, name, 0)  # first
        opt_t(elem)

    fn dict_method(e N, t Ty, name str) Ty
        key = t.a[0]
        val = t.a[1]
        if name == "pop" or name == "get"
            ts = .args(e, name, 1, 2, [], true)
            .expect(key, ts[0], e, "{name}() key", .arg(e, 0))
            if name == "get" and len(ts) == 1 then return opt_t(val)  # d.get(k): nil, если ключа нет
            if len(ts) == 2 then .expect(val, ts[1], e, "{name}() default", .arg(e, 1))
            return val
        if name == "update"
            .expect(t, .args(e, name, 1)[0], e, "update()")
            return UNIT
        if name == "top"
            ts = .args(e, name, 0, 1)
            if ts then .expect(INT, ts[0], e, "top() count")
            if not is_p(val, INT) then .err("top() needs a dict of counts {{K: int}}, not {show(t)}", e)
            return list_t(tuple_t([key, INT]))
        .args(e, name, 0)
        if name == "clear" then return UNIT
        if name == "keys" then return list_t(key)
        if name == "values" then return list_t(val)
        if name == "items" then return list_t(tuple_t([key, val]))
        t  # copy

    fn set_method(e N, t Ty, name str) Ty
        if name == "add" or name == "remove" or name == "discard"
            x = .args(e, name, 1, -1, [], true)[0]
            .expect(t.a[0], x, e, "{name}()", .arg(e, 0))
            return UNIT
        if name == "clear" or name == "copy"
            .args(e, name, 0)
            return if name == "clear" then UNIT else t
        .expect(t, .args(e, name, 1)[0], e, "{name}()")
        if name == "update" then return UNIT
        if name == "issubset" then return BOOL
        t

    fn e_BinOp(e N) Ty
        op = e.kids[0].s
        left = e.kids[1]
        right = e.kids[2]
        if op == "and" or op == "or"
            lt = .expr(left, true)
            rt = .expr(right, true)
            if not truthy_ok(lt) then .err("'{op}' needs bool, number, str, list or dict, not {show(lt)}", left)
            if not truthy_ok(rt) then .err("'{op}' needs bool, number, str, list or dict, not {show(rt)}", right)
            pl = prune(lt)
            pr = prune(rt)
            if op == "or" and pl.k == "opt" and pr.k != "opt" and pr.k != "tvar" and .compatible(pl.a[0], pr)
                return .join(pl.a[0], rt, e, "'or'")  # name or "anon": nil заменяется вторым
            if not .compatible(lt, rt) then return BOOL  # x and x.n > 0: в условии важна только истинность
            return .unite([(left, lt), (right, rt)], "'{op}'")
        lt = .expr(left)
        rt = .expr(right)
        pl = prune(lt)
        pr = prune(rt)
        # неизвестный тип (рекурсия) принимает тип другой стороны
        if pl.k == "tvar" and pr.k != "tvar"
            .unify(pl, pr)
        elif pr.k == "tvar" and pl.k != "tvar"
            .unify(pr, pl)
        elif pl.k == "tvar" and pr.k == "tvar"
            .unify(pl, pr)
            return pl
        pl = prune(lt)
        pr = prune(rt)
        arith = op in ["+", "-", "*", "/", "//", "%", "**"]
        if pl.k == "tparam" or pr.k == "tparam"
            if pl.id != pr.id or not arith
                extra = if "+-*/%".find(op) >= 0 then " (both sides must be the same type parameter)" else ""
                .err("cannot apply '{op}' to {show(lt)} and {show(rt)}" + extra, e)
            pl.needs[if op == "+" then "add" else "num"] = true
            return pl
        if pl.k == "set" and pr.k == "set" and op in ["|", "&", "-", "^"] then return .join(lt, rt, e, "'{op}'")
        if arith
            if .numeric(pl) and .numeric(pr) then return if pl.id == FLOAT.id or pr.id == FLOAT.id then FLOAT else INT
            if op == "+" and pl.id == STR.id and pr.id == STR.id then return STR
            if op == "+" and pl.k == "list" and pr.k == "list" then return .join(lt, rt, e, "'+'")
            if op == "*" and (pl.id == STR.id or pl.k == "list") and pr.id == INT.id then return pl
            .err("cannot apply '{op}' to {show(lt)} and {show(rt)}", e)
        if op == "|" or op == "&" or op == "^"
            if pl.id == INT.id and pr.id == INT.id then return INT
            if pl.id == BOOL.id and pr.id == BOOL.id then return BOOL
            if op == "|" and pl.k == "dict" and pr.k == "dict" then return .join(lt, rt, e, "'|'")
            .err("cannot apply '{op}' to {show(lt)} and {show(rt)}", e)
        .err("operator '{op}' {UNSUPPORTED}", e)
        UNIT

    fn e_Compare(e N) Ty
        ops = e.kids[1].kids
        eqish = true
        for o in ops
            if o.kids[0].s not in ["==", "!=", "is", "is not"] then eqish = false
        left = .expr(e.kids[0], eqish)
        lnode = e.kids[0]
        for o in ops
            op = o.kids[0].s
            right = o.kids[1]
            rt = .expr(right, eqish)
            eqop = op == "==" or op == "!=" or op == "is" or op == "is not"
            if eqop and (is_nil(right) or is_nil(lnode))
                ot = if is_nil(right) then left else rt
                po = prune(ot)
                if po.k == "tvar"
                    .unify(po, opt_t(tv()))
                elif po.k != "opt"
                    .err("{show(ot)} is never nil", e)
                left = rt
                lnode = right
                continue
            if op == "is" or op == "is not" then .err("'{op}' works only with nil; use == or !=", e)
            if (op == "==" or op == "!=") and (prune(left).k == "opt" or prune(rt).k == "opt")
                .unite([(lnode, left), (right, rt)], "'{op}'")
                left = rt
                lnode = right
                continue
            if op == "in" or op == "not in"
                c = prune(rt)
                if c.k == "list" or c.k == "set"
                    .expect(c.a[0], left, e, "'{op}'")
                elif c.k == "dict"
                    .expect(c.a[0], left, e, "'{op}'")
                elif c.id == STR.id
                    .expect(STR, left, e, "'{op}'")
                elif c.id == RANGE.id
                    .expect(INT, left, e, "'{op}'")
                else
                    .err("'{op}' needs a list, dict, str or range on the right, not {show(rt)}", right)
            else
                if not (.numeric(left) and .numeric(rt)) then .join(left, rt, e, "'{op}'")
                if op != "==" and op != "!=" and not comparable(left) and prune(left).k != "set"
                    .err("cannot order {show(left)} with '{op}'", e)
            left = rt
            lnode = right
        BOOL

    fn e_Unary(e N) Ty
        op = e.kids[0].s
        t = .expr(e.kids[1], op == "not")
        if op == "not"
            if not truthy_ok(t) then .err("'not' needs bool, number, str, list or dict, not {show(t)}", e)
            return BOOL
        if op == "-" or op == "+"
            if .num_param(t) then return t
            if not .numeric(t) then .err("cannot apply '{op}' to {show(t)}", e)
            return t
        if op == "~"
            .expect(INT, t, e, "'~'")
            return INT
        .err("operator '{op}' {UNSUPPORTED}", e)
        UNIT

    fn e_IfExpr(e N) Ty
        .cond(e.kids[0])
        a = .expr(e.kids[1], true)
        b = .expr(e.kids[2], true)
        pa = prune(a)
        pb = prune(b)
        # `if ... then "Fizz" else i`: ветки разных типов, одна из них str -> обе в str
        if (is_resolved(a) and is_resolved(b) and (pa.id == STR.id or pb.id == STR.id) and not same(a, b) and
                pa.k != "opt" and pb.k != "opt")
            return STR
        .unite([(e.kids[1], a), (e.kids[2], b)], "if-expression branches")

    fn wants_iface(t0 Ty) bool
        t = prune(t0)
        t.k == "iface" or (t.k == "opt" and prune(t.a[0]).k == "iface")

    fn e_ListLit(e N, want Ty?) Ty
        items = e.kids[0].kids
        if want != nil
            pw = prune(want)
            if pw.k == "list" and items and .wants_iface(pw.a[0])
                # shapes: [Shape] = [Circle(1), Rect(2, 3)]: каждый элемент упаковывается в интерфейс
                for item in items
                    if item.kind == "Starred" then .err("*spread {UNSUPPORTED}", item)
                    .expect(pw.a[0], .expr(item, true), item, "list item", item)
                return list_t(pw.a[0])
        typed: [(N, Ty)] = []
        for item in items
            if item.kind == "Starred" then .err("*spread {UNSUPPORTED}", item)
            typed.append((item, .expr(item, true)))
        if not typed
            .nils.append(e)  # [] без контекста (print []) станет [int]
            return list_t(tv())
        list_t(.unite(typed, "list items"))

    fn e_DictLit(e N, want Ty?) Ty
        pairs = e.kids[0].kids
        if want != nil
            pw = prune(want)
            allk = true
            for kv in pairs
                if isn(kv.kids[0]) then allk = false
            if pw.k == "dict" and pairs and .wants_iface(pw.a[1]) and allk
                for kv in pairs
                    .expect(pw.a[0], .expr(kv.kids[0]), kv.kids[0], "dict key")
                    .expect(pw.a[1], .expr(kv.kids[1], true), kv.kids[1], "dict value", kv.kids[1])
                return dict_t(pw.a[0], pw.a[1])
        kt = tv()
        vals: [(N, Ty)] = []
        for kv in pairs
            if isn(kv.kids[0]) then .err("**spread {UNSUPPORTED}; use a | b", kv.kids[1])
            kt = .join(kt, .expr(kv.kids[0]), kv.kids[0], "dict keys")
            vals.append((kv.kids[1], .expr(kv.kids[1], true)))
        vt = if vals then .unite(vals, "dict values") else tv()
        if not vals then .nils.append(e)
        if is_resolved(kt) and not hashable(kt) then .err("dict key type must be hashable, not {show(kt)}", e)
        dict_t(kt, vt)

    fn e_SetLit(e N) Ty
        typed: [(N, Ty)] = []
        for item in e.kids[0].kids
            if item.kind == "Starred" then .err("*spread {UNSUPPORTED}", item)
            typed.append((item, .expr(item)))
        el = .unite(typed, "set items")
        if is_resolved(el) and not hashable(el) then .err("set items must be hashable, not {show(el)}", e)
        set_t(el)

    fn e_Comp(e N) Ty
        scope: {str: Var} = {}
        .scopes.append(scope)
        for c in e.kids[3].kids
            elem = .iter_elem(c.kids[1], c.kids[0])
            .bind_comp_target(c.kids[0], elem, scope, c)
            for cd in c.kids[2].kids
                .cond(cd)
        kind = e.kids[0].s
        elt = .expr(e.kids[1], kind != "dict")
        if is_p(elt, UNIT) then .err("this expression has no value", e.kids[1])
        result = list_t(elt)
        if kind == "set"
            if not hashable(elt) then .err("set items must be hashable, not {show(elt)}", e.kids[1])
            result = set_t(elt)
        if kind == "dict"
            kt = .expr(e.kids[2])
            result = dict_t(kt, elt)
        .scopes.pop()
        result

    fn bind_comp_target(t N, ty Ty, scope {str: Var}, node N)
        if t.kind == "Name"
            scope[nm(t)] = Var(nm(t), ty, "comp")
            .set_ty(t, ty)
        elif t.kind == "TupleLit"
            pt = prune(ty)
            items = t.kids[0].kids
            if pt.k != "tuple" or len(pt.a) != len(items)
                .err("cannot unpack {show(ty)} into {len(items)} names", node)
            .set_ty(t, ty)
            for item, it in zip(items, pt.a)
                .bind_comp_target(item, it, scope, node)
        pass

    fn e_Lambda(e N, want Ty?) Ty
        has_fn = false
        pw = UNIT
        if want != nil
            pw = prune(want)
            if pw.k == "opt" then pw = prune(pw.a[0])
            has_fn = pw.k == "fn"
        params = [p.s for p in e.kids[0].kids]
        ptypes = [if isn(tn) then tv() else .to_type(tn) for tn in e.kids[2].kids]
        if has_fn
            wps = fn_params(pw)
            if len(wps) != len(ptypes)
                .err("expected a function of {len(wps)} argument(s), got {len(ptypes)}", e)
            for i, a in enumerate(ptypes)
                if not .unify(a, wps[i])
                    .err("parameter '{params[i]}' is {show(a)}, but the function gets {show(wps[i])}", e)
        for i, t in enumerate(ptypes)
            if not is_resolved(t) then .err("cannot infer the type of '{params[i]}'; write fn({params[i]} int) = ...", e)
        scope: {str: Var} = {}
        for i, n in enumerate(params)
            scope[n] = Var(n, ptypes[i], "lparam")
        if not isn(e.kids[3]) then return .lambda_block(e, scope, ptypes, pw, has_fn)
        .scopes.append(scope)
        .lams.append(Lam(false, UNIT))
        rt = .expr(e.kids[1], true)
        .lams.pop()
        .scopes.pop()
        if has_fn
            .expect(fn_ret(pw), rt, e.kids[1], "function result", e.kids[1])
            rt = fn_ret(pw)
        fn_t(ptypes, rt)

    # fn(x) с телом на следующих строках: свои локальные переменные и return
    fn lambda_block(e N, scope {str: Var}, ptypes [Ty], pw Ty, has_fn bool) Ty
        e.kids[3] = L(tail(e.kids[3].kids))
        body = e.kids[3].kids
        names: [str] = []
        augs: [str] = []
        walk_assigned(body, names, augs, true, .kinds())
        for n in augs
            if n in names or n in scope then continue
            outer = false
            for sc in .scopes
                if n in sc then outer = true
            if .cur != nil
                if not .cur.is_top and n in .cur.locals then outer = true
            if outer then .err("a lambda cannot change the outer variable '{n}'; return the new value instead", e)
        locals: [Var] = []
        for n in names
            if n not in scope
                v = Var(n, tv(), "local")
                scope[n] = v
                locals.append(v)
        ret = if has_fn then fn_ret(pw) else tv()
        .scopes.append(scope)
        .lams.append(Lam(true, ret))
        start = len(.nils)
        .block(body)
        .lams.pop()
        .scopes.pop()
        .default_nils(start)
        if prune(ret).k == "tvar" then ret.ref = UNIT
        for v in locals
            .need_resolved(v.ty, e, "variable '{v.name}' in the lambda")
        fn_t(ptypes, ret)

    fn e_Await(e N) Ty
        if e.s != "implicit"
            is_async = false
            where = "top-level code"
            if .cur != nil
                is_async = flag(.cur.node.kids[4])
                if .cur.name != "<top>" then where = "'{.cur.name}'"
            if .lams or not is_async
                .err("await is only allowed inside an async fn ({where} is not async; " +
                     "write `async fn ...`, e.g. `async fn main()`)", e)
        v = e.kids[0]
        if (v.kind == "Call" and v.kids[0].kind == "Name" and nm(v.kids[0]) == "all" and "all" not in .fns and
                .lookup("all") == nil)
            if len(v.kids[1].kids) != 1 or v.kids[2].kids
                .err("await all() takes one argument: a list of tasks or a generator, " +
                     "e.g. await all(fetch(u) for u in urls)", e)
            a = v.kids[1].kids[0]
            res = UNIT
            if a.kind == "Comp" and (a.kids[0].s == "gen" or a.kids[0].s == "list")
                # await all(f(x) for x in xs): каждый элемент — отдельная задача fn() = await f(x)
                elt = a.kids[1]
                inner = mk("Await", elt.line, [elt])
                inner.s = "implicit"
                a.kids[1] = mk("Lambda", elt.line, [L([]), inner, L([]), NONE()])
                a.kids[0] = S("list")
                lt = prune(.expr(a))
                res = fn_ret(prune(lt.a[0]))
            else
                lt = prune(.expr(a))
                if not (lt.k == "list" and prune(lt.a[0]).k == "task")
                    .err("await all() needs a list of tasks (calls of async fn) or a generator, " +
                         "not {show(lt)}", a)
                res = prune(lt.a[0]).a[0]
            return if is_p(res, UNIT) then UNIT else list_t(res)
        t = .expr(v, true)
        pt = prune(t)
        if pt.k == "task" then return pt.a[0]
        t  # await обычного значения (например, http.get) — само значение

# ---------- запуск ----------

# дерево, как у parser.sip, и у каждого выражения его тип: Вид@строка :: тип
fn dump_into(n N, depth int, out [str], tys [Ty])
    pad = "  " * depth
    k = n.kind
    if k == "str"
        out.append(pad + "s{len(n.s)}:" + n.s)
    elif k == "None"
        out.append(pad + "_")
    elif k == "bool"
        out.append(pad + (if n.s == "True" then "T" else "F"))
    elif k == "list" or k == "tuple"
        out.append(pad + (if k == "list" then "[" else "<") + "{len(n.kids)}")
        for c in n.kids
            dump_into(c, depth + 1, out, tys)
    else
        line = pad + "{k}@{n.line}"
        if n.ty != 0 then line = line + " :: " + show(tys[n.ty])
        out.append(line)
        for c in n.kids
            dump_into(c, depth + 1, out, tys)
    pass

fn check_source(file str, src str, std str) str
    ld = modules.Loader(std)
    body = ld.load_root(file, src)
    mod = mk("Module", 1, [L(body)])
    c = Checker(file, std, ld, tys=[UNIT])
    c.check(body)
    out: [str] = []
    dump_into(mod, 0, out, c.tys)
    "\n".join(out) + "\n"

fn where(path str, line int, col int) str
    if line == 0 then return path
    if col == 0 then return "{path}:{line}"
    "{path}:{line}:{col}"

fn main(file str, std = "")
    try
        write("/dev/stdout", check_source(file, read(file), if std != "" then std else modules.abspath("siplang/std")))
    catch SipErr e
        print "{where(e.file, e.line, e.col)}: {e.msg}"
        exit(1)
