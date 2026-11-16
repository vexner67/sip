"""Проверка и вывод типов.

Проход по дереву: каждому выражению ставится атрибут `.ty`, каждому вызову —
`.ckind` (что именно вызывается), каждому имени — ссылка на переменную.
Генератор C пользуется только этой разметкой и ничего не выводит сам.
"""

from __future__ import annotations

from .errors import SipError
from .nodes import *  # noqa: F403
from .types import (BOOL, FLOAT, INT, RANGE, STR, UNIT, DictT, FnT, ListT, OptT, Prim, RecordT, SumT, TupleT,
                    TVar, comparable, deep, hashable, is_resolved, opt, prune, same, show, truthy_ok)

ERROR_KINDS = ["Error", "NotFound", "ParseError", "IndexError", "KeyError", "ValueError",
               "ZeroDivisionError", "AssertionError", "IOError", "NilError"]
CATCH_ALL = {"Exception"}

UNSUPPORTED = "is not supported by the native compiler yet"


class Var:
    def __init__(self, name: str, ty, cname: str, kind: str):
        self.name = name
        self.ty = ty
        self.cname = cname
        self.kind = kind  # local, param, global, comp

    def __repr__(self):
        return f"Var({self.name}: {show(self.ty)})"


class FnInfo:
    def __init__(self, node: FnDef, cname: str, owner=None):
        self.node = node
        self.name = node.name
        self.cname = cname
        self.owner = owner          # RecordT или SumT для методов
        self.params: list = []      # [(имя, тип, узел значения по умолчанию)]
        self.ret = TVar()
        self.locals: dict = {}      # имя -> Var
        self.extra: list = []       # переменные генераторов списков
        self.body: list = []
        self.state = "new"
        self.has_try = False
        self.cache = False

    @property
    def line(self):
        return self.node.line


class Program:
    def __init__(self):
        self.records: dict = {}
        self.sums: dict = {}
        self.variants: dict = {}   # имя варианта -> SumT
        self.fns: dict = {}        # имя -> FnInfo (функции верхнего уровня)
        self.methods: list = []    # все методы
        self.globals: dict = {}
        self.top: FnInfo | None = None
        self.main: FnInfo | None = None


def tail(stmts: list) -> list:
    """Неявный return: последнее выражение функции — её результат."""
    if not stmts:
        return stmts
    return stmts[:-1] + [_tail_stmt(stmts[-1])]


def _tail_stmt(s):
    if isinstance(s, ExprStmt):
        e = s.expr
        if isinstance(e, Call) and isinstance(e.func, Name) and e.func.id == "print":
            return s
        return Return(e, line=s.line)
    if isinstance(s, If):
        return If([(c, tail(b)) for c, b in s.branches], tail(s.orelse) if s.orelse else None, line=s.line)
    if isinstance(s, Try):
        return Try(tail(s.body), [Handler(h.kind, h.name, tail(h.body), line=h.line) for h in s.handlers],
                   line=s.line)
    if isinstance(s, Match):
        return Match(s.subject, [Arm(a.pattern, a.guard, tail(a.body), line=a.line) for a in s.arms],
                     line=s.line)
    return s


def literal_default(e) -> bool:
    """Значение по умолчанию подставляется в месте вызова, поэтому только литералы."""
    if isinstance(e, (Num, Const)):
        return True
    if isinstance(e, Str):
        return all(isinstance(p, str) for p in e.parts)
    if isinstance(e, Unary) and e.op == "-":
        return isinstance(e.operand, Num)
    if isinstance(e, (ListLit, TupleLit)):
        return all(literal_default(i) for i in e.items)
    if isinstance(e, DictLit):
        return all(k is not None and literal_default(k) and literal_default(v) for k, v in e.pairs)
    return False


class Checker:
    def __init__(self, file: str = "<input>"):
        self.file = file
        self.p = Program()
        self.cur: FnInfo | None = None
        self.scopes: list = []
        self.uid = 0
        self.lambdas: list = []  # лямбды, тело которых проверяется сейчас (вложенные — в конце)
        self.nils: list = []     # литералы nil: тип без контекста потом станет int?

    # ---------- общее ----------

    def err(self, msg: str, node=None):
        raise SipError(msg, getattr(node, "line", 0) or 0, 0, self.file)

    def fresh(self, prefix: str) -> str:
        self.uid += 1
        return f"{prefix}{self.uid}"

    def unify(self, a, b) -> bool:
        a, b = prune(a), prune(b)
        if a is b:
            return True
        if isinstance(a, TVar):
            a.ref = b
            return True
        if isinstance(b, TVar):
            b.ref = a
            return True
        if type(a) is not type(b):
            return False
        if isinstance(a, ListT):
            return self.unify(a.elem, b.elem)
        if isinstance(a, DictT):
            return self.unify(a.key, b.key) and self.unify(a.val, b.val)
        if isinstance(a, TupleT):
            return len(a.items) == len(b.items) and all(self.unify(x, y) for x, y in zip(a.items, b.items))
        if isinstance(a, OptT):
            return self.unify(a.inner, b.inner)
        if isinstance(a, FnT):
            return (len(a.params) == len(b.params) and all(self.unify(x, y) for x, y in zip(a.params, b.params))
                    and self.unify(a.ret, b.ret))
        return False  # разные Prim, разные записи

    def expect(self, want, got, node, what: str, src=None):
        """Значение типа got кладётся туда, где ждут want.

        int становится float сам. Если передано выражение src, разрешены и
        преобразования T -> T? (обёртка) и T? -> T (проверка на nil при
        выполнении); они записываются в src.cty для генератора C.
        """
        pw, pg = prune(want), prune(got)
        if pw is FLOAT and pg is INT:
            return
        if src is not None and isinstance(pw, OptT) and not isinstance(pg, (OptT, TVar)) and pg is not UNIT:
            self.expect(pw.inner, got, node, what)
            src.cty = want
            return
        if isinstance(pg, OptT) and not isinstance(pw, (OptT, TVar)):
            if is_nil(src) or src is None:
                self.err(f"{what}: {show(want)} cannot be nil (use {show(want)}? for an optional value)", node)
            self.expect(want, pg.inner, node, what)
            src.cty = want
            return
        if not self.unify(want, got):
            hint = " (write 0.0 for a float)" if pw is INT and pg is FLOAT else ""
            self.err(f"{what}: expected {show(want)}, got {show(got)}{hint}", node)

    def unite(self, items, what: str):
        """Общий тип нескольких значений [(узел, тип)]: int+float -> float, T+nil -> T?."""
        anyopt = any(isinstance(prune(t), OptT) for _, t in items)
        acc = TVar()
        for n, t in items:
            pt = prune(t)
            acc = self.join(acc, pt.inner if isinstance(pt, OptT) else t, n, what)
        target = OptT(acc) if anyopt else acc
        for n, t in items:
            self.expect(target, t, n, what, src=n)
        return target

    def compatible(self, a, b) -> bool:
        a, b = prune(a), prune(b)
        a = prune(a.inner) if isinstance(a, OptT) else a
        b = prune(b.inner) if isinstance(b, OptT) else b
        if isinstance(a, TVar) or isinstance(b, TVar):
            return True
        if a in (INT, FLOAT) and b in (INT, FLOAT):
            return True
        return same(a, b)

    def join(self, a, b, node, what: str):
        """Общий тип двух веток: int и float дают float."""
        pa, pb = prune(a), prune(b)
        if {id(pa), id(pb)} == {id(INT), id(FLOAT)}:
            return FLOAT
        if not self.unify(a, b):
            self.err(f"{what}: {show(a)} and {show(b)} do not match", node)
        return a

    def numeric(self, t) -> bool:
        return prune(t) in (INT, FLOAT)

    def need_resolved(self, t, node, what: str):
        if not is_resolved(t):
            hint = "x: int? = nil" if isinstance(prune(t), OptT) else "xs: [int] = []"
            self.err(f"cannot infer the type of {what}; add a type, e.g. {hint}", node)

    def to_type(self, t):
        if isinstance(t, TName):
            n = t.name
            simple = {"int": INT, "float": FLOAT, "bool": BOOL, "str": STR}
            if n in simple and not t.args:
                return simple[n]
            if n in self.p.records:
                return self.p.records[n]
            if n in self.p.sums:
                return self.p.sums[n]
            if n in ("list", "dict", "tuple"):
                self.err(f"write {'[T]' if n == 'list' else '{K: V}' if n == 'dict' else '(A, B)'} "
                         f"instead of '{n}'", t)
            if n == "None":
                self.err("nil is not a type; write T? for a value that may be nil, e.g. int?", t)
            self.err(f"unknown type '{n}'", t)
        if isinstance(t, TList):
            return ListT(self.to_type(t.item))
        if isinstance(t, TDict):
            k = self.to_type(t.key)
            if not hashable(k):
                self.err(f"dict key type must be int, float, bool, str or a tuple of them, not {show(k)}", t)
            return DictT(k, self.to_type(t.value))
        if isinstance(t, TTuple):
            return TupleT([self.to_type(i) for i in t.items])
        if isinstance(t, TOptional):
            return opt(self.to_type(t.inner))
        if isinstance(t, TFn):
            return FnT([self.to_type(p) for p in t.params], UNIT if t.ret is None else self.to_type(t.ret))
        self.err("bad type", t)

    # ---------- модуль ----------

    def check(self, mod: Module) -> Program:
        p = self.p
        top_stmts = []
        fn_nodes = []
        for s in mod.body:
            if isinstance(s, Record):
                if s.name in p.records or s.name in p.sums:
                    self.err(f"type '{s.name}' is already defined", s)
                p.records[s.name] = RecordT(s.name)
            elif isinstance(s, SumType):
                if s.name in p.records or s.name in p.sums:
                    self.err(f"type '{s.name}' is already defined", s)
                st = SumT(s.name)
                p.sums[s.name] = st
                for v in s.variants:
                    if v.name in p.variants or v.name in p.records:
                        self.err(f"variant '{v.name}' is already defined", v)
                    p.variants[v.name] = st
            elif isinstance(s, FnDef):
                fn_nodes.append(s)
            elif isinstance(s, (Import, FromImport)):
                self.err(f"import {UNSUPPORTED}", s)
            else:
                top_stmts.append(s)

        # поля и варианты (типы могут ссылаться друг на друга)
        for s in mod.body:
            if isinstance(s, Record):
                rt = p.records[s.name]
                for f in s.fields:
                    if f.type is None:
                        if f.default is None:
                            self.err(f"field '{f.name}' needs a type", f)
                        rt.fields[f.name] = self.default_type(f.default)
                    else:
                        rt.fields[f.name] = self.to_type(f.type)
                    if f.default is not None:
                        if not literal_default(f.default):
                            self.err("default value must be a literal", f.default)
                        rt.defaults[f.name] = f.default
                for m in s.methods:
                    fi = FnInfo(m, f"m_{s.name}_{m.name}", rt)
                    rt.methods[m.name] = fi
                    p.methods.append(fi)
            elif isinstance(s, SumType):
                st = p.sums[s.name]
                for v in s.variants:
                    fields = []
                    for f in v.fields:
                        if f.type is None:
                            self.err(f"field '{f.name}' needs a type", f)
                        if f.default is not None:
                            self.err(f"variant field defaults {UNSUPPORTED}", f)
                        fields.append((f.name, self.to_type(f.type)))
                    st.variants[v.name] = fields
                for m in s.methods:
                    fi = FnInfo(m, f"m_{s.name}_{m.name}", st)
                    st.methods[m.name] = fi
                    p.methods.append(fi)

        for fn in fn_nodes:
            if fn.name in p.fns:
                self.err(f"function '{fn.name}' is already defined", fn)
            if fn.name in p.records or fn.name in p.variants:
                self.err(f"'{fn.name}' is already a type", fn)
            p.fns[fn.name] = FnInfo(fn, f"f_{fn.name}")
        for fi in list(p.fns.values()) + p.methods:
            self.signature(fi)

        # верхний уровень: присвоенные там имена — глобальные переменные
        top = FnInfo(FnDef("<top>", [], None, top_stmts, line=1), "sip_toplevel")
        top.ret = UNIT
        top.body = top_stmts
        p.top = top
        for name in self.assigned(top_stmts):
            p.globals[name] = Var(name, TVar(), f"g_{name}", "global")
        top.locals = p.globals
        self.cur = top
        top.state = "busy"
        self.block(top_stmts)
        top.state = "done"
        self.cur = None

        for fi in list(p.fns.values()) + p.methods:
            self.check_fn(fi)

        self.default_nils(0)
        for name, v in p.globals.items():
            self.need_resolved(v.ty, None, f"global '{name}'")
        if "main" in p.fns:
            m = p.fns["main"]
            for name, t, d in m.params:
                pt = prune(t)
                if isinstance(pt, OptT) and d is not None:
                    pt = prune(pt.inner)
                if pt not in (INT, FLOAT, STR, BOOL):
                    self.err(f"main parameter '{name}' must be int, float, str or bool (or T? = nil)", m.node)
            p.main = m
        return p

    def default_nils(self, start: int):
        """nil, тип которого ничто не уточнило (print nil, (1, nil)), хранится как int?."""
        for n in self.nils[start:]:
            if not is_resolved(n.ty):
                self.unify(prune(n.ty).inner, INT)

    def default_type(self, e):
        if not literal_default(e):
            self.err("default value must be a literal", e)
        saved, self.cur = self.cur, None
        t = self.expr(e, opt=True)
        self.cur = saved
        return t

    def signature(self, fi: FnInfo):
        n = fi.node
        if n.is_async:
            self.err(f"async functions {UNSUPPORTED}", n)
        for d in n.decorators:
            if isinstance(d, Name) and d.id == "cache":
                fi.cache = True
            else:
                self.err(f"decorator {UNSUPPORTED} (only @cache)", n)
        for prm in n.params:
            if prm.star:
                self.err(f"*args {UNSUPPORTED}", prm)
            if prm.type is not None:
                t = self.to_type(prm.type)
                if prm.default is not None:
                    if not literal_default(prm.default):
                        self.err("default value must be a literal", prm.default)
                    self.expect(t, self.default_type(prm.default), prm.default, f"default of '{prm.name}'",
                                src=prm.default)
            elif prm.default is not None:
                if is_nil(prm.default):
                    self.err(f"parameter '{prm.name}' needs a type, e.g. {prm.name} int? = nil", prm)
                t = self.default_type(prm.default)
            else:
                self.err(f"parameter '{prm.name}' needs a type, e.g. {prm.name} int", prm)
            fi.params.append((prm.name, t, prm.default))
        if n.ret is not None:
            fi.ret = self.to_type(n.ret)
        if fi.cache:
            for name, t, _ in fi.params:
                if not hashable(t):
                    self.err(f"@cache needs hashable parameters, '{name}' is {show(t)}", n)
            if not fi.params:
                self.err("@cache needs at least one parameter", n)

    def check_fn(self, fi: FnInfo):
        if fi.state != "new":
            return
        fi.state = "busy"
        saved = (self.cur, self.scopes, self.lambdas)
        self.cur, self.scopes, self.lambdas = fi, [], []
        if fi.owner is not None:
            fi.locals["self"] = Var("self", fi.owner, "self", "param")
        for name, t, _ in fi.params:
            fi.locals[name] = Var(name, t, f"v_{name}", "param")
        fi.body = tail(fi.node.body)
        augs: list = []
        names = self.assigned(fi.body, augs)
        # `count += 1` без `count = ...` в функции меняет глобальную переменную
        names += [n for n in augs if n not in names and n not in self.p.globals]
        for name in names:
            if name not in fi.locals:
                fi.locals[name] = Var(name, TVar(), f"v_{name}", "local")
        start = len(self.nils)
        self.block(fi.body)
        self.default_nils(start)
        if isinstance(prune(fi.ret), TVar):
            fi.ret.ref = UNIT
        for v in fi.locals.values():
            self.need_resolved(v.ty, fi.node, f"variable '{v.name}' in {fi.name}")
        if fi.cache and prune(fi.ret) is UNIT:
            self.err("@cache function must return a value", fi.node)
        fi.state = "done"
        self.cur, self.scopes, self.lambdas = saved

    def assigned(self, stmts: list, augs: list | None = None) -> list:
        """Имена, которым что-то присваивается: это локальные переменные.

        Если передан augs, имена, которые только изменяются через `+=` и т. п.,
        попадают туда, а не в результат: это может быть глобальная переменная.
        """
        names: list = []

        def add(n):
            if n not in names:
                names.append(n)

        def target(t):
            if isinstance(t, Name):
                add(t.id)
            elif isinstance(t, TupleLit):
                for i in t.items:
                    target(i)

        def pattern(pt):
            if isinstance(pt, PCapture):
                add(pt.name)
            elif isinstance(pt, PStar):
                add(pt.name)
            elif isinstance(pt, PClass):
                for a in pt.args:
                    pattern(a)
                for _, a in pt.kwargs:
                    pattern(a)
            elif isinstance(pt, (PTuple, PList)):
                for a in pt.items:
                    pattern(a)

        def walk(ss):
            for s in ss:
                if isinstance(s, (Assign,)):
                    for t in s.targets:
                        target(t)
                elif isinstance(s, AugAssign) and augs is not None and isinstance(s.target, Name):
                    if s.target.id not in augs:
                        augs.append(s.target.id)
                elif isinstance(s, (AugAssign, AnnAssign)):
                    target(s.target)
                elif isinstance(s, For):
                    target(s.target)
                    walk(s.body)
                elif isinstance(s, While):
                    walk(s.body)
                elif isinstance(s, If):
                    for _, b in s.branches:
                        walk(b)
                    if s.orelse:
                        walk(s.orelse)
                elif isinstance(s, Try):
                    walk(s.body)
                    for h in s.handlers:
                        if h.name:
                            add(h.name)
                        walk(h.body)
                elif isinstance(s, Match):
                    for a in s.arms:
                        pattern(a.pattern)
                        walk(a.body)

        walk(stmts)
        return names

    def lookup(self, name: str):
        for i in range(len(self.scopes) - 1, -1, -1):
            if name in self.scopes[i]:
                var = self.scopes[i][name]
                self.capture(var, i)
                return var
        if self.cur is not None and name in self.cur.locals:
            var = self.cur.locals[name]
            if var.kind != "global":
                self.capture(var, -1)
            return var
        return self.p.globals.get(name)

    def capture(self, var, level: int):
        """Переменная из внешней области видимости, использованная в лямбде, копируется в её окружение."""
        for lam in self.lambdas:
            if level < lam.depth and var.cname not in lam.captures:
                lam.captures[var.cname] = var

    # ---------- инструкции ----------

    def block(self, stmts):
        for s in stmts:
            self.stmt(s)

    def stmt(self, s):
        m = getattr(self, "s_" + type(s).__name__, None)
        if m is None:
            self.err(f"{type(s).__name__.lower()} {UNSUPPORTED}", s)
        m(s)

    def s_ExprStmt(self, s):
        self.expr(s.expr)

    def assign_to(self, t, vt, node, src=None):
        if isinstance(t, Name):
            var = self.lookup(t.id)
            if var is None:
                self.err(f"cannot assign to '{t.id}'", t)
            t.var = var
            t.ty = var.ty
            self.expect(var.ty, vt, node, f"assignment to '{t.id}'", src)
        elif isinstance(t, TupleLit):
            pv = prune(vt)
            if not isinstance(pv, TupleT) or len(pv.items) != len(t.items):
                self.err(f"cannot unpack {show(vt)} into {len(t.items)} names", node)
            t.ty = vt
            for item, it in zip(t.items, pv.items):
                self.assign_to(item, it, node)
        else:
            tt = self.expr(t, opt=True)
            if isinstance(t, Index) and getattr(t, "index_kind", "") not in ("list", "dict"):
                self.err(f"cannot assign into {show(t.obj.ty)}", t)
            self.expect(tt, vt, node, "assignment", src)

    def s_Assign(self, s):
        want = None
        if len(s.targets) == 1 and isinstance(s.targets[0], Name):
            var = self.lookup(s.targets[0].id)
            want = var.ty if var is not None else None
        vt = self.expr(s.value, opt=True, want=want)
        if prune(vt) is UNIT:
            self.err("this expression has no value", s.value)
        for t in s.targets:
            self.assign_to(t, vt, s, s.value)

    def s_AnnAssign(self, s):
        want = self.to_type(s.type)
        var = self.lookup(s.target.id)
        self.expect(var.ty, want, s, f"variable '{s.target.id}'")
        self.assign_to(s.target, self.expr(s.value, opt=True, want=want), s, s.value)

    def s_AugAssign(self, s):
        if isinstance(s.target, TupleLit):
            self.err("cannot use an augmented assignment with several targets", s)
        tt = self.expr(s.target, opt=True)
        s.binop = BinOp(s.op[:-1], s.target, s.value, line=s.line)
        t = self.expr(s.binop)
        if isinstance(prune(tt), OptT):
            # x += 1 для x: int? — это x = x + 1 с проверкой на nil
            s.as_assign = Assign([s.target], s.binop, line=s.line)
            self.expect(tt, t, s, f"'{s.op}'", src=s.binop)
            return
        self.expect(tt, t, s, f"'{s.op}'")

    def cond(self, e):
        t = self.expr(e, opt=True)
        if not truthy_ok(t):
            self.err(f"a condition must be bool, number, str, list or dict, not {show(t)}", e)

    def s_If(self, s):
        for c, b in s.branches:
            self.cond(c)
            self.block(b)
        if s.orelse:
            self.block(s.orelse)

    def s_While(self, s):
        self.cond(s.cond)
        self.block(s.body)

    def iter_elem(self, holder, it_node, target):
        t = prune(self.expr(it_node))
        if t is RANGE:
            holder.iter_kind = "range"
            return INT
        if isinstance(t, ListT):
            holder.iter_kind = "list"
            return t.elem
        if isinstance(t, DictT):
            if isinstance(target, TupleLit) and len(target.items) == 2:
                holder.iter_kind = "dict_items"
                return TupleT([t.key, t.val])
            holder.iter_kind = "dict_keys"
            return t.key
        if t is STR:
            holder.iter_kind = "str"
            return STR
        if isinstance(t, TVar):
            self.err("cannot iterate over a value of unknown type", it_node)
        self.err(f"cannot iterate over {show(t)}", it_node)

    def s_For(self, s):
        elem = self.iter_elem(s, s.iter, s.target)
        self.assign_to(s.target, elem, s)
        self.block(s.body)

    def s_Return(self, s):
        if self.cur is self.p.top:
            self.err("return outside a function", s)
        if s.value is None:
            t = UNIT
        else:
            t = self.expr(s.value, opt=True, want=self.cur.ret)
        if is_nil(s.value) and isinstance(prune(self.cur.ret), TVar):
            self.err(f"{self.cur.name}() returns nil here: declare its return type, e.g. fn {self.cur.name}(...) int?", s)
        self.expect(self.cur.ret, t, s, f"{self.cur.name}() result", src=s.value)

    def s_Break(self, s):
        pass

    def s_Continue(self, s):
        pass

    def s_Pass(self, s):
        pass

    def s_Fail(self, s):
        t = self.expr(s.value)
        if prune(t) is UNIT:
            self.err("fail needs a value", s)

    def s_Assert(self, s):
        self.cond(s.cond)
        if s.msg is not None:
            self.expr(s.msg)

    def s_Try(self, s):
        self.cur.has_try = True
        self.block(s.body)
        for h in s.handlers:
            if h.kind is not None and h.kind not in ERROR_KINDS and h.kind not in CATCH_ALL:
                self.err(f"unknown error kind '{h.kind}'; known: {', '.join(ERROR_KINDS)}", h)
            if h.name:
                var = self.lookup(h.name)
                self.expect(var.ty, STR, h, f"catch variable '{h.name}' (it holds the message)")
                h.var = var
            self.block(h.body)

    def s_Match(self, s):
        st = self.expr(s.subject, opt=True)
        self.need_resolved(st, s.subject, "the match subject")
        for arm in s.arms:
            self.pattern(arm.pattern, st, arm)
            if arm.guard is not None:
                self.cond(arm.guard)
            self.block(arm.body)

    def pattern(self, p, t, node, in_or=False):
        t = prune(t)
        if isinstance(p, PWild):
            return
        if isinstance(t, OptT) and not isinstance(p, (PCapture, POr)):
            if isinstance(p, PLit) and is_nil(p.expr):
                self.expr(p.expr, opt=True)
                p.nil = True
                p.ty = t
                return
            p.unwrap = True  # остальные образцы сначала проверяют, что значение не nil
            self.pattern(p, t.inner, node, in_or)
            return
        if isinstance(p, PLit) and is_nil(p.expr):
            self.err(f"pattern nil cannot match {show(t)}, which is never nil", p)
        if isinstance(p, (PCapture, PStar)):
            if in_or:
                self.err("names cannot be bound inside '|' patterns", p)
            var = self.lookup(p.name)
            p.var = var
            if isinstance(p, PStar):
                return  # тип проверяет PList
            self.expect(var.ty, t, p, f"pattern variable '{p.name}'")
            return
        if isinstance(p, PLit):
            lt = self.expr(p.expr)
            if not (same(lt, t) or (t is FLOAT and prune(lt) is INT)):
                self.err(f"pattern {show(lt)} cannot match {show(t)}", p)
            p.ty = t
            return
        if isinstance(p, PClass):
            if isinstance(t, SumT):
                if p.name not in t.variants:
                    self.err(f"'{p.name}' is not a variant of {t.name}", p)
                fields = t.variants[p.name]
                p.variant = t.index(p.name)
            elif isinstance(t, RecordT) and p.name == t.name:
                fields = list(t.fields.items())
                p.variant = None
            else:
                self.err(f"pattern {p.name}(...) cannot match {show(t)}", p)
            if len(p.args) > len(fields):
                self.err(f"{p.name} has {len(fields)} field(s), pattern gives {len(p.args)}", p)
            p.fields = []
            for (fname, ftype), sub in zip(fields, p.args):
                p.fields.append(fname)
                self.pattern(sub, ftype, node, in_or)
            names = [f for f, _ in fields]
            p.kwfields = []
            for kname, sub in p.kwargs:
                if kname not in names:
                    self.err(f"{p.name} has no field '{kname}'", p)
                p.kwfields.append(kname)
                self.pattern(sub, dict(fields)[kname], node, in_or)
            return
        if isinstance(p, PTuple):
            if not isinstance(t, TupleT) or len(t.items) != len(p.items):
                self.err(f"tuple pattern of {len(p.items)} cannot match {show(t)}", p)
            for sub, it in zip(p.items, t.items):
                self.pattern(sub, it, node, in_or)
            return
        if isinstance(p, PList):
            if not isinstance(t, ListT):
                self.err(f"list pattern cannot match {show(t)}", p)
            stars = [i for i, sub in enumerate(p.items) if isinstance(sub, PStar)]
            if len(stars) > 1 or (stars and stars[0] != len(p.items) - 1):
                self.err("only one *rest at the end of a list pattern is supported", p)
            for sub in p.items:
                if isinstance(sub, PStar):
                    self.pattern(sub, t, node, in_or)
                    self.expect(sub.var.ty, t, sub, f"pattern variable '{sub.name}'")
                else:
                    self.pattern(sub, t.elem, node, in_or)
            return
        if isinstance(p, POr):
            for alt in p.alts:
                self.pattern(alt, t, node, True)
            return
        self.err(f"this pattern {UNSUPPORTED}", p)

    def s_FnDef(self, s):
        self.err(f"nested functions {UNSUPPORTED}", s)

    def s_Record(self, s):
        self.err("types must be defined at the top level", s)

    s_SumType = s_Record

    # ---------- выражения ----------

    def expr(self, e, opt=False, want=None):
        """Тип выражения. Если opt=False, значение T? сразу проверяется на nil и даёт T."""
        if isinstance(e, Lambda):
            t = self.e_Lambda(e, want)
        else:
            m = getattr(self, "e_" + type(e).__name__, None)
            if m is None:
                self.err(f"{type(e).__name__.lower()} {UNSUPPORTED}", e)
            t = m(e)
        e.ty = t
        pt = prune(t)
        if not opt and isinstance(pt, OptT):
            if is_nil(e):
                self.err("nil cannot be used here", e)
            e.cty = pt.inner
            return pt.inner
        return t

    def e_Num(self, e):
        return FLOAT if any(c in e.text for c in ".eE") else INT

    def e_Str(self, e):
        for part in e.parts:
            if isinstance(part, Interp):
                t = self.expr(part.expr, opt=part.spec is None)
                if prune(t) is UNIT:
                    self.err("this expression has no value", part.expr)
                if part.spec is not None and prune(t) not in (INT, FLOAT, STR):
                    self.err(f"format spec needs int, float or str, not {show(t)}", part.expr)
        return STR

    def e_Const(self, e):
        if e.value == "None":
            self.nils.append(e)
            return OptT(TVar())
        return BOOL

    def e_Name(self, e):
        var = self.lookup(e.id)
        if var is not None:
            e.var = var
            return var.ty
        if e.id in ("True", "False"):  # привычка из Python
            e.const = e.id.lower()
            return BOOL
        if e.id == "pi":
            e.const = "SIP_PI"
            return FLOAT
        if e.id in self.p.variants:
            st = self.p.variants[e.id]
            if st.variants[e.id]:
                self.err(f"'{e.id}' needs its fields: {e.id}(...)", e)
            e.variant = (st, e.id)
            return st
        if e.id in self.p.fns:
            fi = self.p.fns[e.id]
            if fi.state == "new" and isinstance(prune(fi.ret), TVar):
                self.check_fn(fi)
            e.fnref = fi
            return FnT([t for _, t, _ in fi.params], fi.ret)
        if e.id in BUILTINS:
            self.err(f"built-in '{e.id}' cannot be used as a value; wrap it: fn(x) = {e.id}(x)", e)
        self.err(f"unknown name '{e.id}'", e)

    def e_SelfAttr(self, e):
        fi = self.cur
        if fi is None or fi.owner is None:
            self.err(f"'.{e.name}' used outside a method", e)
        if not isinstance(fi.owner, RecordT) or e.name not in fi.owner.fields:
            self.err(f"{show(fi.owner)} has no field '{e.name}'", e)
        self.lookup("self")  # внутри лямбды self попадает в окружение
        return fi.owner.fields[e.name]

    def e_Attr(self, e):
        t = prune(self.expr(e.obj))
        if isinstance(t, RecordT):
            if e.name not in t.fields:
                self.err(f"{t.name} has no field '{e.name}'", e)
            return t.fields[e.name]
        self.err(f"{show(t)} has no field '{e.name}'", e)

    def e_Index(self, e):
        t = prune(self.expr(e.obj))
        if isinstance(e.index, Slice):
            if not (isinstance(t, ListT) or t is STR):
                self.err(f"cannot slice {show(t)}", e)
            sl = e.index
            if sl.step is not None:
                self.err(f"slice step {UNSUPPORTED}", e)
            for part in (sl.lo, sl.hi):
                if part is not None:
                    self.expect(INT, self.expr(part), part, "slice bound")
            e.index_kind = "slice_list" if isinstance(t, ListT) else "slice_str"
            return t
        if isinstance(t, ListT):
            self.expect(INT, self.expr(e.index), e.index, "list index")
            e.index_kind = "list"
            return t.elem
        if isinstance(t, DictT):
            self.expect(t.key, self.expr(e.index), e.index, "dict key")
            e.index_kind = "dict"
            return t.val
        if t is STR:
            self.expect(INT, self.expr(e.index), e.index, "string index")
            e.index_kind = "str"
            return STR
        if isinstance(t, TupleT):
            idx = e.index
            neg = isinstance(idx, Unary) and idx.op == "-" and isinstance(idx.operand, Num)
            if not (isinstance(idx, Num) or neg) or "." in (idx.operand.text if neg else idx.text):
                self.err("tuple index must be a number literal", idx)
            i = -int(idx.operand.text) if neg else int(idx.text)
            if i < 0:
                i += len(t.items)
            if not 0 <= i < len(t.items):
                self.err("tuple index out of range", idx)
            e.index_kind = "tuple"
            e.tuple_index = i
            return t.items[i]
        if isinstance(t, TVar):
            self.err("cannot index a value of unknown type", e)
        self.err(f"cannot index {show(t)}", e)

    def bind_args(self, call, params, what):
        if any(isinstance(a, Starred) for a in call.args):
            self.err(f"*args {UNSUPPORTED}", call)
        if len(call.args) > len(params):
            self.err(f"{what} takes {len(params)} argument(s), got {len(call.args)}", call)
        bound = list(call.args) + [None] * (len(params) - len(call.args))
        names = [n for n, _, _ in params]
        for k, v in call.kwargs:
            if k not in names:
                self.err(f"{what} has no parameter '{k}'", call)
            i = names.index(k)
            if bound[i] is not None:
                self.err(f"argument '{k}' given twice", call)
            bound[i] = v
        for i, (n, t, default) in enumerate(params):
            if bound[i] is None:
                if default is None:
                    self.err(f"{what} is missing argument '{n}'", call)
                bound[i] = default
            at = self.expr(bound[i], opt=True, want=t)
            self.expect(t, at, bound[i], f"argument '{n}' of {what}", src=bound[i])
        call.bound = bound

    def e_Call(self, e):
        f = e.func
        if isinstance(f, SelfAttr) and self.cur is not None and self.cur.owner is not None \
                and f.name in self.cur.owner.methods:
            f = e.func = Attr(Name("self", line=f.line), f.name, line=f.line)  # .other() внутри метода
        if isinstance(f, Name):
            name = f.id
            if self.lookup(name) is not None:
                return self.call_value(e)
            if name in self.p.fns:
                fi = self.p.fns[name]
                self.bind_args(e, fi.params, f"{name}()")
                e.ckind, e.fn = "fn", fi
                if fi.state == "new" and isinstance(prune(fi.ret), TVar):
                    self.check_fn(fi)  # вывести тип результата до использования
                return fi.ret
            if name in self.p.records:
                rt = self.p.records[name]
                params = [(fn, ft, rt.defaults.get(fn)) for fn, ft in rt.fields.items()]
                self.bind_args(e, params, f"{name}()")
                e.ckind, e.record = "ctor", rt
                return rt
            if name in self.p.variants:
                st = self.p.variants[name]
                params = [(fn, ft, None) for fn, ft in st.variants[name]]
                self.bind_args(e, params, f"{name}()")
                e.ckind, e.variant = "variant", (st, name)
                return st
            if name in BUILTINS:
                e.ckind, e.bname = "builtin", name
                return BUILTINS[name](self, e)
            self.err(f"unknown function '{name}'", e)
        if isinstance(f, Attr):
            rt = prune(self.expr(f.obj))
            if isinstance(rt, (RecordT, SumT)) and f.name in rt.methods:
                fi = rt.methods[f.name]
                self.bind_args(e, fi.params, f"{rt.name}.{f.name}()")
                e.ckind, e.fn = "method", fi
                if fi.state == "new" and isinstance(prune(fi.ret), TVar):
                    self.check_fn(fi)
                return fi.ret
            if isinstance(rt, RecordT) and f.name in rt.fields:
                return self.call_value(e)
            e.ckind, e.mname, e.recv = "bmethod", f.name, f.obj
            return self.bmethod(e, rt, f.name)
        return self.call_value(e)

    def call_value(self, e):
        """Вызов значения-функции (лямбды, параметра типа fn(...))."""
        ft = prune(self.expr(e.func))
        if isinstance(ft, TVar):
            self.err("cannot call a value of unknown type", e)
        if not isinstance(ft, FnT):
            self.err(f"{show(ft)} is not a function", e)
        if e.kwargs:
            self.err("a function value takes positional arguments only", e)
        if len(e.args) != len(ft.params):
            self.err(f"function takes {len(ft.params)} argument(s), got {len(e.args)}", e)
        for i, (a, pt) in enumerate(zip(e.args, ft.params)):
            self.expect(pt, self.expr(a, opt=True, want=pt), a, f"argument {i + 1}", src=a)
        e.ckind, e.bound = "closure", list(e.args)
        return ft.ret

    def fnarg(self, node, params, ret, what):
        """Аргумент-функция встроенного метода: map(fn(x) = ...) и т. п."""
        ft = prune(self.expr(node, want=FnT(params, ret)))
        if not isinstance(ft, FnT) or len(ft.params) != len(params):
            self.err(f"{what} needs a function of {len(params)} argument(s), not {show(ft)}", node)
        for a, b in zip(ft.params, params):
            if not self.unify(a, b):
                self.err(f"{what}: the function takes {show(a)}, but gets {show(b)}", node)
        return ft.ret

    def kwarg(self, e, name):
        for k, v in e.kwargs:
            if k == name:
                return v
        return None

    def args(self, e, lo: int, hi: int | None = None, kw=(), opt=False):
        hi = lo if hi is None else hi
        name = e.bname if getattr(e, "ckind", "") == "builtin" else e.mname
        if not lo <= len(e.args) <= hi:
            want = str(lo) if lo == hi else f"{lo}-{hi}"
            self.err(f"{name}() takes {want} argument(s), got {len(e.args)}", e)
        for k, _ in e.kwargs:
            if k not in kw:
                self.err(f"{name}() has no parameter '{k}'", e)
        return [self.expr(a, opt=opt) for a in e.args]

    def bmethod(self, e, t, name):
        t = prune(t)
        if t is STR:
            spec = STR_METHODS.get(name)
            if spec is None:
                self.err(f"str has no method '{name}'", e)
            return spec(self, e)
        if isinstance(t, ListT):
            spec = LIST_METHODS.get(name)
            if spec is None:
                self.err(f"list has no method '{name}'", e)
            return spec(self, e, t)
        if isinstance(t, DictT):
            spec = DICT_METHODS.get(name)
            if spec is None:
                self.err(f"dict has no method '{name}'", e)
            return spec(self, e, t)
        if isinstance(t, TVar):
            self.err(f"cannot call .{name}() on a value of unknown type", e)
        self.err(f"{show(t)} has no method '{name}'", e)

    def e_BinOp(self, e):
        op = e.op
        if op in ("and", "or"):
            lt, rt = self.expr(e.left, opt=True), self.expr(e.right, opt=True)
            for side, st in ((e.left, lt), (e.right, rt)):
                if not truthy_ok(st):
                    self.err(f"'{op}' needs bool, number, str, list or dict, not {show(st)}", side)
            pl, pr = prune(lt), prune(rt)
            if op == "or" and isinstance(pl, OptT) and not isinstance(pr, (OptT, TVar)) \
                    and self.compatible(pl.inner, pr):
                e.opt_or = True  # name or "anon": nil (и пустое значение) заменяется вторым
                res = self.join(pl.inner, rt, e, "'or'")
                e.right.cty = res
                return res
            if not self.compatible(lt, rt):
                e.logic_bool = True  # x and x.n > 0: в условии важна только истинность
                return BOOL
            return self.unite([(e.left, lt), (e.right, rt)], f"'{op}'")
        lt, rt = self.expr(e.left), self.expr(e.right)
        pl, pr = prune(lt), prune(rt)
        # неизвестный тип (рекурсия) принимает тип другой стороны
        if isinstance(pl, TVar) and not isinstance(pr, TVar):
            self.unify(pl, pr)
        elif isinstance(pr, TVar) and not isinstance(pl, TVar):
            self.unify(pr, pl)
        elif isinstance(pl, TVar) and isinstance(pr, TVar):
            self.unify(pl, pr)
            return pl
        pl, pr = prune(lt), prune(rt)
        if op in ("+", "-", "*", "/", "//", "%", "**"):
            if self.numeric(pl) and self.numeric(pr):
                return FLOAT if FLOAT in (pl, pr) else INT
            if op == "+" and pl is STR and pr is STR:
                return STR
            if op == "+" and isinstance(pl, ListT) and isinstance(pr, ListT):
                return self.join(lt, rt, e, "'+'")
            if op == "*" and (pl is STR or isinstance(pl, ListT)) and pr is INT:
                return pl
            self.err(f"cannot apply '{op}' to {show(lt)} and {show(rt)}", e)
        if op in ("|", "&", "^"):
            if pl is INT and pr is INT:
                return INT
            if pl is BOOL and pr is BOOL:
                return BOOL
            if op == "|" and isinstance(pl, DictT) and isinstance(pr, DictT):
                return self.join(lt, rt, e, "'|'")
            self.err(f"cannot apply '{op}' to {show(lt)} and {show(rt)}", e)
        self.err(f"operator '{op}' {UNSUPPORTED}", e)

    def e_Compare(self, e):
        eqish = all(op in ("==", "!=", "is", "is not") for op, _ in e.ops)
        left = self.expr(e.left, opt=eqish)
        lnode = e.left
        e.nilcmp = []
        for op, right in e.ops:
            rt = self.expr(right, opt=eqish)
            nil_side = right if is_nil(right) else lnode if is_nil(lnode) else None
            if op in ("==", "!=", "is", "is not") and nil_side is not None:
                other, ot = (lnode, left) if nil_side is right else (right, rt)
                po = prune(ot)
                if isinstance(po, TVar):
                    self.unify(po, OptT(TVar()))
                elif not isinstance(po, OptT):
                    self.err(f"{show(ot)} is never nil", e)
                e.nilcmp.append(True)
                left, lnode = rt, right
                continue
            e.nilcmp.append(False)
            if op in ("is", "is not"):
                self.err(f"'{op}' works only with nil; use == or !=", e)
            if op in ("==", "!=") and (isinstance(prune(left), OptT) or isinstance(prune(rt), OptT)):
                self.unite([(lnode, left), (right, rt)], f"'{op}'")
                left, lnode = rt, right
                continue
            if op in ("in", "not in"):
                c = prune(rt)
                if isinstance(c, ListT):
                    self.expect(c.elem, left, e, f"'{op}'")
                elif isinstance(c, DictT):
                    self.expect(c.key, left, e, f"'{op}'")
                elif c is STR:
                    self.expect(STR, left, e, f"'{op}'")
                elif c is RANGE:
                    self.expect(INT, left, e, f"'{op}'")
                else:
                    self.err(f"'{op}' needs a list, dict, str or range on the right, not {show(rt)}", right)
            elif op in ("is", "is not"):
                self.err(f"'{op}' {UNSUPPORTED}; use == or !=", e)
            else:
                if not (self.numeric(left) and self.numeric(rt)):
                    self.join(left, rt, e, f"'{op}'")
                if op not in ("==", "!=") and not comparable(left):
                    self.err(f"cannot order {show(left)} with '{op}'", e)
            left, lnode = rt, right
        return BOOL

    def e_Unary(self, e):
        t = self.expr(e.operand, opt=e.op == "not")
        if e.op == "not":
            if not truthy_ok(t):
                self.err(f"'not' needs bool, number, str, list or dict, not {show(t)}", e)
            return BOOL
        if e.op in ("-", "+"):
            if not self.numeric(t):
                self.err(f"cannot apply '{e.op}' to {show(t)}", e)
            return t
        if e.op == "~":
            self.expect(INT, t, e, "'~'")
            return INT
        self.err(f"operator '{e.op}' {UNSUPPORTED}", e)

    def e_IfExpr(self, e):
        self.cond(e.cond)
        a, b = self.expr(e.then, opt=True), self.expr(e.other, opt=True)
        pa, pb = deep(a), deep(b)
        # `if ... then "Fizz" else i`: ветки разных типов, одна из них str -> обе в str
        if is_resolved(pa) and is_resolved(pb) and STR in (pa, pb) and not same(pa, pb) \
                and not isinstance(pa, OptT) and not isinstance(pb, OptT):
            e.stringify = True
            return STR
        return self.unite([(e.then, a), (e.other, b)], "if-expression branches")

    def e_Range(self, e):
        self.expect(INT, self.expr(e.lo), e.lo, "range start")
        self.expect(INT, self.expr(e.hi), e.hi, "range end")
        return RANGE

    def e_ListLit(self, e):
        items = []
        for item in e.items:
            if isinstance(item, Starred):
                self.err(f"*spread {UNSUPPORTED}", item)
            items.append((item, self.expr(item, opt=True)))
        return ListT(self.unite(items, "list items") if items else TVar())

    def e_TupleLit(self, e):
        return TupleT([self.expr(i, opt=True) for i in e.items])

    def e_DictLit(self, e):
        kt = TVar()
        vals = []
        for k, v in e.pairs:
            if k is None:
                self.err(f"**spread {UNSUPPORTED}; use a | b", v)
            kt = self.join(kt, self.expr(k), k, "dict keys")
            vals.append((v, self.expr(v, opt=True)))
        vt = self.unite(vals, "dict values") if vals else TVar()
        if is_resolved(kt) and not hashable(kt):
            self.err(f"dict key type must be hashable, not {show(kt)}", e)
        return DictT(kt, vt)

    def e_Comp(self, e):
        if e.kind == "set":
            self.err(f"sets {UNSUPPORTED}", e)
        scope: dict = {}
        self.scopes.append(scope)
        for c in e.clauses:
            elem = self.iter_elem(c, c.iter, c.target)
            self.bind_comp_target(c.target, elem, scope, c)
            for cond in c.conds:
                self.cond(cond)
        elt = self.expr(e.elt, opt=e.kind != "dict")
        if prune(elt) is UNIT:
            self.err("this expression has no value", e.elt)
        result = ListT(elt)
        if e.kind == "dict":
            kt = self.expr(e.key)
            result = DictT(kt, elt)
        self.scopes.pop()
        return result

    def bind_comp_target(self, t, ty, scope, node):
        if isinstance(t, Name):
            var = Var(t.id, ty, self.fresh(f"c_{t.id}_"), "comp")
            scope[t.id] = var
            (self.lambdas[-1].extra if self.lambdas else self.cur.extra).append(var)
            t.var = var
            t.ty = ty
        elif isinstance(t, TupleLit):
            pt = prune(ty)
            if not isinstance(pt, TupleT) or len(pt.items) != len(t.items):
                self.err(f"cannot unpack {show(ty)} into {len(t.items)} names", node)
            t.ty = ty
            for item, it in zip(t.items, pt.items):
                self.bind_comp_target(item, it, scope, node)

    def e_Lambda(self, e, want=None):
        pw = prune(want) if want is not None else None
        if isinstance(pw, OptT):
            pw = prune(pw.inner)
        ptypes = [self.to_type(tn) if tn is not None else TVar() for tn in e.types]
        if isinstance(pw, FnT):
            if len(pw.params) != len(ptypes):
                self.err(f"expected a function of {len(pw.params)} argument(s), got {len(ptypes)}", e)
            for name, a, b in zip(e.params, ptypes, pw.params):
                if not self.unify(a, b):
                    self.err(f"parameter '{name}' is {show(a)}, but the function gets {show(b)}", e)
        for name, t in zip(e.params, ptypes):
            if not is_resolved(t):
                self.err(f"cannot infer the type of '{name}'; write fn({name} int) = ...", e)
        e.lid = self.fresh("")
        e.captures = {}
        e.extra = []
        e.pvars = [Var(n, t, f"a{e.lid}_{n}", "lparam") for n, t in zip(e.params, ptypes)]
        e.depth = len(self.scopes)
        self.scopes.append({v.name: v for v in e.pvars})
        self.lambdas.append(e)
        try:
            rt = self.expr(e.body, opt=True)
        finally:
            self.lambdas.pop()
            self.scopes.pop()
        if isinstance(pw, FnT):
            self.expect(pw.ret, rt, e.body, "function result", src=e.body)
            rt = pw.ret
        return FnT(ptypes, rt)

    def e_Await(self, e):
        self.err(f"await {UNSUPPORTED}", e)


# ---------- встроенные функции ----------

def _seq_elem(c: Checker, e, t, what):
    t = prune(t)
    if isinstance(t, ListT):
        return t.elem
    if t is RANGE:
        return INT
    c.err(f"{what}() needs a list or range, not {show(t)}", e)


def b_print(c, e):
    for k, _ in e.kwargs:
        c.err(f"print() has no parameter '{k}'", e)
    for a in e.args:
        if prune(c.expr(a, opt=True)) is UNIT:
            c.err("this expression has no value", a)
    return UNIT


def b_len(c, e):
    (t,) = c.args(e, 1)
    pt = prune(t)
    if not (pt in (STR, RANGE) or isinstance(pt, (ListT, DictT, TupleT))):
        c.err(f"len() needs str, list, dict, tuple or range, not {show(t)}", e)
    return INT


def b_str(c, e):
    (t,) = c.args(e, 1, opt=True)
    if prune(t) is UNIT:
        c.err("this expression has no value", e)
    return STR


def b_int(c, e):
    (t,) = c.args(e, 1)
    if prune(t) not in (STR, INT, FLOAT, BOOL):
        c.err(f"int() needs str, int, float or bool, not {show(t)}", e)
    return INT


def b_float(c, e):
    (t,) = c.args(e, 1)
    if prune(t) not in (STR, INT, FLOAT):
        c.err(f"float() needs str, int or float, not {show(t)}", e)
    return FLOAT


def b_bool(c, e):
    (t,) = c.args(e, 1, opt=True)
    if not truthy_ok(t):
        c.err(f"bool() cannot convert {show(t)}", e)
    return BOOL


def b_abs(c, e):
    (t,) = c.args(e, 1)
    if not c.numeric(t):
        c.err(f"abs() needs a number, not {show(t)}", e)
    return t


def b_minmax(c, e):
    ts = c.args(e, 1, 16, kw=("key",))
    keyf = c.kwarg(e, "key")
    if len(ts) == 1:
        elem = _seq_elem(c, e, ts[0], e.bname)
        e.minmax_key = keyf
        if keyf is not None:
            kt = c.fnarg(keyf, [elem], TVar(), f"{e.bname}() key")
            if not comparable(kt):
                c.err(f"{e.bname}() key must be comparable, not {show(kt)}", keyf)
        elif not comparable(elem):
            c.err(f"{e.bname}() cannot compare {show(elem)}", e)
        e.minmax_seq = True
        return elem
    if keyf is not None:
        c.err(f"{e.bname}(..., key:) works with one list argument", e)
    t = ts[0]
    for other, node in zip(ts[1:], e.args[1:]):
        t = c.join(t, other, node, f"{e.bname}() arguments")
    if not comparable(t):
        c.err(f"{e.bname}() cannot compare {show(t)}", e)
    e.minmax_seq = False
    return t


def b_sum(c, e):
    (t,) = c.args(e, 1)
    elem = _seq_elem(c, e, t, "sum")
    if not c.numeric(elem):
        c.err(f"sum() needs numbers, not {show(elem)}", e)
    return elem


def b_avg(c, e):
    (t,) = c.args(e, 1)
    elem = _seq_elem(c, e, t, "avg")
    if not c.numeric(elem):
        c.err(f"avg() needs numbers, not {show(elem)}", e)
    return FLOAT


def b_anyall(c, e):
    (t,) = c.args(e, 1)
    elem = _seq_elem(c, e, t, e.bname)
    if not truthy_ok(elem):
        c.err(f"{e.bname}() cannot test {show(elem)}", e)
    return BOOL


def _sort_kwargs(c, e, elem, what):
    rev = c.kwarg(e, "reverse")
    if rev is not None:
        c.expect(BOOL, c.expr(rev), rev, "reverse")
    keyf = c.kwarg(e, "key")
    e.sort_key = keyf
    if keyf is not None:
        kt = c.fnarg(keyf, [elem], TVar(), f"{what} key")
        if not comparable(kt):
            c.err(f"{what} key must be comparable, not {show(kt)}", keyf)
        e.sort_key_ty = kt
    elif not comparable(elem):
        c.err(f"cannot sort {show(elem)}", e)


def b_sorted(c, e):
    (t,) = c.args(e, 1, kw=("reverse", "key"))
    pt = prune(t)
    if not isinstance(pt, ListT):
        c.err(f"sorted() needs a list, not {show(t)}", e)
    _sort_kwargs(c, e, pt.elem, "sorted()")
    return pt


def b_list(c, e):
    (t,) = c.args(e, 1)
    pt = prune(t)
    if pt is RANGE:
        return ListT(INT)
    if isinstance(pt, ListT):
        return pt
    if pt is STR:
        return ListT(STR)
    if isinstance(pt, DictT):
        return ListT(pt.key)
    c.err(f"list() cannot convert {show(t)}", e)


def b_count(c, e):
    (t,) = c.args(e, 1)
    elem = _seq_elem(c, e, t, "count")
    if not hashable(elem):
        c.err(f"count() needs hashable items, not {show(elem)}", e)
    return DictT(elem, INT)


def b_read(c, e):
    (t,) = c.args(e, 1)
    c.expect(STR, t, e, "read() path")
    return STR


def b_write(c, e):
    a, b = c.args(e, 2)
    c.expect(STR, a, e, "write() path")
    c.expect(STR, b, e, "write() text")
    return UNIT


def b_input(c, e):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(STR, ts[0], e, "input() prompt")
    return STR


def b_round(c, e):
    ts = c.args(e, 1, 2)
    if not c.numeric(ts[0]):
        c.err(f"round() needs a number, not {show(ts[0])}", e)
    if len(ts) == 2:
        c.expect(INT, ts[1], e, "round() digits")
        return FLOAT
    return INT


def b_zip(c, e):
    a, b = c.args(e, 2)
    ea = _seq_elem(c, e, a, "zip")
    eb = _seq_elem(c, e, b, "zip")
    return ListT(TupleT([ea, eb]))


def b_enumerate(c, e):
    (t,) = c.args(e, 1)
    return ListT(TupleT([INT, _seq_elem(c, e, t, "enumerate")]))


def b_exit(c, e):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(INT, ts[0], e, "exit() code")
    return UNIT


BUILTINS = {
    "print": b_print, "len": b_len, "str": b_str, "int": b_int, "float": b_float, "bool": b_bool,
    "abs": b_abs, "min": b_minmax, "max": b_minmax, "sum": b_sum, "avg": b_avg, "any": b_anyall,
    "all": b_anyall, "sorted": b_sorted, "list": b_list, "count": b_count, "read": b_read,
    "write": b_write, "input": b_input, "round": b_round, "zip": b_zip, "enumerate": b_enumerate,
    "exit": b_exit,
}


# ---------- методы встроенных типов ----------

def _str_noarg(result):
    def spec(c, e):
        c.args(e, 0)
        return result
    return spec


def _str_onestr(result):
    def spec(c, e):
        (t,) = c.args(e, 1)
        c.expect(STR, t, e, f"{e.mname}() argument")
        return result
    return spec


def m_str_split(c, e):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(STR, ts[0], e, "split() separator")
    return ListT(STR)


def m_str_replace(c, e):
    a, b = c.args(e, 2)
    c.expect(STR, a, e, "replace() old")
    c.expect(STR, b, e, "replace() new")
    return STR


def m_str_join(c, e):
    (t,) = c.args(e, 1)
    pt = prune(t)
    if not isinstance(pt, ListT):
        c.err(f"join() needs a list, not {show(t)}", e)
    return STR


STR_METHODS = {
    "lower": _str_noarg(STR), "upper": _str_noarg(STR), "strip": _str_noarg(STR),
    "lstrip": _str_noarg(STR), "rstrip": _str_noarg(STR), "splitlines": _str_noarg(ListT(STR)),
    "isdigit": _str_noarg(BOOL), "isalpha": _str_noarg(BOOL), "isspace": _str_noarg(BOOL),
    "split": m_str_split, "startswith": _str_onestr(BOOL), "endswith": _str_onestr(BOOL),
    "find": _str_onestr(INT), "count": _str_onestr(INT), "replace": m_str_replace, "join": m_str_join,
}


def m_list_append(c, e, t):
    (x,) = c.args(e, 1, opt=True)
    c.expect(t.elem, x, e, "append()", src=e.args[0])
    return UNIT


def m_list_pop(c, e, t):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(INT, ts[0], e, "pop() index")
    return t.elem


def m_list_insert(c, e, t):
    i, x = c.args(e, 2, opt=True)
    c.expect(INT, i, e, "insert() index", src=e.args[0])
    c.expect(t.elem, x, e, "insert() value", src=e.args[1])
    return UNIT


def m_list_extend(c, e, t):
    (x,) = c.args(e, 1)
    c.expect(t, x, e, "extend()")
    return UNIT


def m_list_noarg(result):
    def spec(c, e, t):
        c.args(e, 0)
        return result(t) if callable(result) else result
    return spec


def m_list_index(c, e, t):
    (x,) = c.args(e, 1)
    c.expect(t.elem, x, e, "index()")
    return INT


def m_list_count(c, e, t):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(t.elem, ts[0], e, "count()")
        return INT
    if not hashable(t.elem):
        c.err(f"count() needs hashable items, not {show(t.elem)}", e)
    return DictT(t.elem, INT)


def m_list_sort(c, e, t):
    c.args(e, 0, kw=("reverse", "key"))
    _sort_kwargs(c, e, t.elem, "sort()")
    return UNIT


def m_list_map(c, e, t):
    if len(e.args) != 1 or e.kwargs:
        c.err("map() takes a function", e)
    ret = c.fnarg(e.args[0], [t.elem], TVar(), "map()")
    if prune(ret) is UNIT:
        c.err("map() needs a function that returns a value", e)
    return ListT(ret)


def m_list_filter(c, e, t):
    if len(e.args) != 1 or e.kwargs:
        c.err("filter() takes a function", e)
    ret = c.fnarg(e.args[0], [t.elem], TVar(), "filter()")
    if not truthy_ok(ret):
        c.err(f"filter() function must return bool, not {show(ret)}", e)
    return t


def m_list_sort_by(c, e, t):
    if len(e.args) != 1:
        c.err("sort_by() takes a function", e)
    for k, _ in e.kwargs:
        if k != "reverse":
            c.err(f"sort_by() has no parameter '{k}'", e)
    e.kwargs = e.kwargs + [("key", e.args[0])]
    _sort_kwargs(c, e, t.elem, "sort_by()")
    return t


def m_list_group_by(c, e, t):
    if len(e.args) != 1 or e.kwargs:
        c.err("group_by() takes a function", e)
    kt = c.fnarg(e.args[0], [t.elem], TVar(), "group_by()")
    if not hashable(kt):
        c.err(f"group_by() key must be int, float, bool, str or a tuple, not {show(kt)}", e)
    return DictT(kt, t)


def m_list_first(c, e, t):
    c.args(e, 0)
    return OptT(t.elem)


def m_list_join(c, e, t):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(STR, ts[0], e, "join() separator")
    return STR


def m_list_num(result_float):
    def spec(c, e, t):
        c.args(e, 0)
        if not c.numeric(t.elem):
            c.err(f"{e.mname}() needs numbers, not {show(t.elem)}", e)
        return FLOAT if result_float else t.elem
    return spec


def m_list_top(c, e, t):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(INT, ts[0], e, "top() count")
    if not hashable(t.elem):
        c.err(f"top() needs hashable items, not {show(t.elem)}", e)
    return ListT(TupleT([t.elem, INT]))


LIST_METHODS = {
    "append": m_list_append, "pop": m_list_pop, "insert": m_list_insert, "extend": m_list_extend,
    "clear": m_list_noarg(UNIT), "reverse": m_list_noarg(UNIT), "copy": m_list_noarg(lambda t: t),
    "index": m_list_index, "count": m_list_count, "sort": m_list_sort, "join": m_list_join,
    "sum": m_list_num(False), "avg": m_list_num(True), "top": m_list_top,
    "map": m_list_map, "filter": m_list_filter, "sort_by": m_list_sort_by, "group_by": m_list_group_by,
    "first": m_list_first,
}


def m_dict_get(c, e, t):
    ts = c.args(e, 1, 2, opt=True)
    c.expect(t.key, ts[0], e, "get() key", src=e.args[0])
    if len(ts) == 1:
        return OptT(t.val)  # d.get(k): nil, если ключа нет
    c.expect(t.val, ts[1], e, "get() default", src=e.args[1])
    return t.val


def m_dict_top(c, e, t):
    ts = c.args(e, 0, 1)
    if ts:
        c.expect(INT, ts[0], e, "top() count")
    if prune(t.val) is not INT:
        c.err(f"top() needs a dict of counts {{K: int}}, not {show(t)}", e)
    return ListT(TupleT([t.key, INT]))


DICT_METHODS = {
    "get": m_dict_get, "keys": lambda c, e, t: (c.args(e, 0), ListT(t.key))[1],
    "values": lambda c, e, t: (c.args(e, 0), ListT(t.val))[1],
    "items": lambda c, e, t: (c.args(e, 0), ListT(TupleT([t.key, t.val])))[1],
    "copy": lambda c, e, t: (c.args(e, 0), t)[1], "top": m_dict_top,
}


def is_nil(e) -> bool:
    return isinstance(e, Const) and e.value == "None"


def check_program(mod: Module, file: str = "<input>") -> Program:
    return Checker(file).check(mod)


__all__ = ["check_program", "Program", "FnInfo", "Var", "ERROR_KINDS", "tail", "Prim"]
