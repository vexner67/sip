"""Генератор Python-кода из дерева Sip.

Генератор учитывает приоритеты операторов и ставит скобки только там,
где они нужны, поэтому результат читается как обычный Python.
Для каждой строки вывода запоминается строка исходника (linemap),
чтобы ошибки времени выполнения показывать в координатах .sip-файла.
"""

import keyword

from .errors import SipError
from .nodes import *  # noqa: F403

# Методы, которые Sip добавляет к спискам, строкам и словарям: `xs.count().top(3)`.
# Вызов `obj.m(...)` превращается в `_sip.m_m(obj, ...)`. Если у объекта
# есть собственный метод с таким именем, рантайм вызовет его.
EXT_METHODS = {"count", "top", "group_by", "avg", "sum", "map", "filter", "sort_by", "first", "join"}

PREC = {
    "lambda": 0, "if": 1, "or": 2, "and": 3, "not": 4, "cmp": 5,
    "|": 6, "^": 7, "&": 8, "+": 10, "-": 10, "*": 11, "/": 11, "//": 11, "%": 11,
    "unary": 12, "**": 13, "await": 14,
}
ATOM = 16


def ident(name: str) -> str:
    """Имя Sip, которое в Python оказалось ключевым словом, получает `_` в конце."""
    if keyword.iskeyword(name) and name not in ("True", "False", "None"):
        return name + "_"
    return name


def tail(stmts: list) -> list:
    """Неявный return: последнее выражение функции становится её результатом."""
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
    if isinstance(s, With):
        return With(s.items, tail(s.body), line=s.line)
    return s


class CodeGen:
    def __init__(self, file: str = "<input>"):
        self.file = file
        self.lines: list[str] = []
        self.linemap: list[int] = []  # строка Python (с 0) -> строка Sip
        self.depth = 0
        self.in_method = False

    def emit(self, text: str, line: int):
        self.lines.append("    " * self.depth + text)
        self.linemap.append(line)

    def error(self, msg: str, node):
        raise SipError(msg, node.line, 0, self.file)

    # ---------- модуль ----------

    def module(self, mod: Module) -> str:
        self.emit("from __future__ import annotations", 0)
        self.emit("import siplang.runtime as _sip", 0)
        self.emit("from siplang.runtime import *", 0)
        for s in mod.body:
            self.stmt(s)
        if any(isinstance(s, FnDef) and s.name == "main" for s in mod.body):
            self.emit("", 0)
            self.emit("if __name__ == '__main__':", 0)
            self.emit("    _sip.run_main(main)", 0)
        return "\n".join(self.lines) + "\n"

    def block(self, stmts: list, line: int = 0):
        self.depth += 1
        if not stmts:
            self.emit("pass", line)
        for s in stmts:
            self.stmt(s)
        self.depth -= 1

    # ---------- инструкции ----------

    def stmt(self, s):
        # пустая строка перед определениями верхнего уровня, как принято в Python
        if self.depth == 0 and isinstance(s, (FnDef, Record, SumType)) and self.lines and self.lines[-1]:
            self.emit("", 0)
        getattr(self, "s_" + type(s).__name__)(s)

    def value(self, e) -> str:
        """Правая часть присваивания или return: кортеж без лишних скобок."""
        if isinstance(e, TupleLit) and len(e.items) > 1:
            return ", ".join(self.expr(i) for i in e.items)
        return self.expr(e)

    def s_ExprStmt(self, s):
        self.emit(self.expr(s.expr), s.line)

    def s_Assign(self, s):
        parts = [self.target(t) for t in s.targets] + [self.value(s.value)]
        self.emit(" = ".join(parts), s.line)

    def s_AugAssign(self, s):
        t = self.target(s.target)
        if s.op == "/=":
            self.emit(f"{t} = _sip.div({t}, {self.expr(s.value)})", s.line)
        else:
            self.emit(f"{t} {s.op} {self.expr(s.value)}", s.line)

    def s_If(self, s):
        for i, (cond, body) in enumerate(s.branches):
            self.emit(f"{'if' if i == 0 else 'elif'} {self.expr(cond)}:", cond.line or s.line)
            self.block(body, s.line)
        if s.orelse:
            self.emit("else:", s.orelse[0].line)
            self.block(s.orelse, s.line)

    def s_For(self, s):
        self.emit(f"for {self.target(s.target)} in {self.iter_expr(s.target, s.iter)}:", s.line)
        self.block(s.body, s.line)

    def s_While(self, s):
        self.emit(f"while {self.expr(s.cond)}:", s.line)
        self.block(s.body, s.line)

    def s_Return(self, s):
        self.emit("return" if s.value is None else f"return {self.value(s.value)}", s.line)

    def s_Break(self, s):
        self.emit("break", s.line)

    def s_Continue(self, s):
        self.emit("continue", s.line)

    def s_Pass(self, s):
        self.emit("pass", s.line)

    def s_Fail(self, s):
        self.emit(f"raise _sip.fail({self.expr(s.value)})", s.line)

    def s_Assert(self, s):
        msg = f", {self.expr(s.msg)}" if s.msg else ""
        self.emit(f"assert {self.expr(s.cond)}{msg}", s.line)

    def s_Try(self, s):
        self.emit("try:", s.line)
        self.block(s.body, s.line)
        for h in s.handlers:
            kind = h.kind or "Exception"
            name = f" as {ident(h.name)}" if h.name else ""
            self.emit(f"except {kind}{name}:", h.line)
            self.block(h.body, h.line)

    def s_Match(self, s):
        self.emit(f"match {self.expr(s.subject)}:", s.line)
        self.depth += 1
        for arm in s.arms:
            guard = f" if {self.expr(arm.guard)}" if arm.guard else ""
            self.emit(f"case {self.pattern(arm.pattern)}{guard}:", arm.line)
            self.block(arm.body, arm.line)
        self.depth -= 1

    def s_With(self, s):
        items = ", ".join(self.expr(e) + (f" as {ident(n)}" if n else "") for e, n in s.items)
        self.emit(f"with {items}:", s.line)
        self.block(s.body, s.line)

    def s_Import(self, s):
        self.emit(f"import {s.module}" + (f" as {s.alias}" if s.alias else ""), s.line)

    def s_FromImport(self, s):
        names = ", ".join(n + (f" as {a}" if a else "") for n, a in s.names)
        self.emit(f"from {s.module} import {names}", s.line)

    def param(self, p: Param) -> str:
        code = p.star + ident(p.name)
        if p.type is not None:
            code += f": {self.type(p.type)}"
            if p.default is not None:
                code += f" = {self.expr(p.default)}"
        elif p.default is not None:
            code += f"={self.expr(p.default)}"
        return code

    def s_FnDef(self, s):
        for d in s.decorators:
            self.emit("@" + self.expr(d), s.line)
        params = (["self"] if s.is_method else []) + [self.param(p) for p in s.params]
        ret = f" -> {self.type(s.ret)}" if s.ret else ""
        prefix = "async def" if s.is_async else "def"
        self.emit(f"{prefix} {ident(s.name)}({', '.join(params)}){ret}:", s.line)
        saved = self.in_method
        self.in_method = s.is_method or saved
        self.block(tail(s.body), s.line)
        self.in_method = saved

    def fields(self, fields: list, line: int):
        for f in fields:
            t = self.type(f.type) if f.type is not None else "object"
            code = f"{ident(f.name)}: {t}"
            if f.default is not None:
                d = f.default
                if isinstance(d, (ListLit, DictLit, SetLit, Comp)):
                    code += f" = _sip.field(default_factory=lambda: {self.expr(d)})"
                else:
                    code += f" = {self.expr(d)}"
            self.emit(code, f.line or line)

    def s_Record(self, s):
        self.emit("@_sip.dataclass", s.line)
        self.emit(f"class {s.name}:", s.line)
        self.depth += 1
        if not s.fields and not s.methods:
            self.emit("pass", s.line)
        self.fields(s.fields, s.line)
        for m in s.methods:
            self.stmt(m)
        self.depth -= 1

    def s_SumType(self, s):
        self.emit(f"class {s.name}:", s.line)
        self.depth += 1
        if not s.methods:
            self.emit("pass", s.line)
        for m in s.methods:
            self.stmt(m)
        self.depth -= 1
        for v in s.variants:
            self.emit("@_sip.dataclass", v.line)
            self.emit(f"class {v.name}({s.name}):", v.line)
            self.depth += 1
            if not v.fields:
                self.emit("pass", v.line)
            self.fields(v.fields, v.line)
            self.depth -= 1

    # ---------- типы ----------

    def type(self, t) -> str:
        if isinstance(t, TName):
            if t.args:
                return f"{t.name}[{', '.join(self.type(a) for a in t.args)}]"
            return t.name
        if isinstance(t, TList):
            return f"list[{self.type(t.item)}]"
        if isinstance(t, TDict):
            return f"dict[{self.type(t.key)}, {self.type(t.value)}]"
        if isinstance(t, TTuple):
            return f"tuple[{', '.join(self.type(i) for i in t.items)}]"
        if isinstance(t, TOptional):
            return f"{self.type(t.inner)} | None"
        raise TypeError(t)

    # ---------- образцы ----------

    def pattern(self, p) -> str:
        if isinstance(p, PWild):
            return "_"
        if isinstance(p, PCapture):
            return ident(p.name)
        if isinstance(p, PLit):
            return self.expr(p.expr)
        if isinstance(p, PValue):
            return p.dotted
        if isinstance(p, PClass):
            args = [self.pattern(a) for a in p.args] + [f"{k}={self.pattern(v)}" for k, v in p.kwargs]
            return f"{p.name}({', '.join(args)})"
        if isinstance(p, PTuple):
            items = [self.pattern(i) for i in p.items]
            return f"({items[0]},)" if len(items) == 1 else f"({', '.join(items)})"
        if isinstance(p, PList):
            return f"[{', '.join(self.pattern(i) for i in p.items)}]"
        if isinstance(p, PStar):
            return "*" + ident(p.name)
        if isinstance(p, POr):
            return " | ".join(self.pattern(a) for a in p.alts)
        raise TypeError(p)

    # ---------- выражения ----------

    def target(self, t) -> str:
        if isinstance(t, TupleLit):
            return ", ".join(self.target(i) for i in t.items)
        return self.expr(t)

    def iter_expr(self, target, it) -> str:
        # `for k, v in d` перебирает пары ключ-значение, если d — словарь
        if isinstance(target, TupleLit):
            return f"_sip.pairs({self.expr(it)})"
        return self.expr(it, PREC["or"])

    def expr(self, e, prec: int = 0) -> str:
        code, p = getattr(self, "e_" + type(e).__name__)(e)
        return f"({code})" if p < prec else code

    def e_Name(self, e):
        return ident(e.id), ATOM

    def e_SelfAttr(self, e):
        if not self.in_method:
            self.error(f"'.{e.name}' used outside a method", e)
        return f"self.{e.name}", ATOM

    def e_Num(self, e):
        return e.text, ATOM

    def e_Const(self, e):
        return e.value, ATOM

    def e_Str(self, e):
        q = e.quote
        if all(isinstance(p, str) for p in e.parts):
            return q + "".join(e.parts) + q, ATOM
        out = []
        for p in e.parts:
            if isinstance(p, str):
                out.append(p.replace("{", "{{").replace("}", "}}"))
            else:
                code = self.expr(p.expr, PREC["if"])
                if code.startswith("{"):
                    code = " " + code + " "
                out.append("{" + code + (":" + p.spec if p.spec is not None else "") + "}")
        return "f" + q + "".join(out) + q, ATOM

    def e_Attr(self, e):
        return f"{self.expr(e.obj, ATOM)}.{e.name}", ATOM

    def e_Index(self, e):
        idx = e.index
        if isinstance(idx, Slice):
            code = self.slice(idx)
        elif isinstance(idx, TupleLit):
            code = ", ".join(self.expr(i) for i in idx.items)
        else:
            code = self.expr(idx)
        return f"{self.expr(e.obj, ATOM)}[{code}]", ATOM

    def slice(self, s):
        lo = self.expr(s.lo) if s.lo else ""
        hi = self.expr(s.hi) if s.hi else ""
        code = f"{lo}:{hi}"
        if s.step:
            code += ":" + self.expr(s.step)
        return code

    def e_Slice(self, e):
        return self.slice(e), ATOM

    def e_Starred(self, e):
        return ("**" if e.double else "*") + self.expr(e.value, ATOM), ATOM

    def call_args(self, args, kwargs, prefix=()) -> str:
        parts = list(prefix)
        if len(args) == 1 and not kwargs and not prefix and isinstance(args[0], Comp) and args[0].kind == "gen":
            return self.comp_inner(args[0])
        parts += [self.expr(a) for a in args]
        parts += [f"{ident(k)}={self.expr(v)}" for k, v in kwargs]
        return ", ".join(parts)

    def e_Call(self, e):
        f = e.func
        if isinstance(f, Attr) and f.name in EXT_METHODS:
            return f"_sip.m_{f.name}({self.call_args(e.args, e.kwargs, [self.expr(f.obj)])})", ATOM
        return f"{self.expr(f, ATOM)}({self.call_args(e.args, e.kwargs)})", ATOM

    def e_Await(self, e):
        v = e.value
        # `await all(xs)` запускает все ожидания параллельно
        if isinstance(v, Call) and isinstance(v.func, Name) and v.func.id == "all":
            return f"await _sip.gather({self.call_args(v.args, v.kwargs)})", PREC["await"]
        return f"await {self.expr(v, ATOM)}", PREC["await"]

    def e_BinOp(self, e):
        op = e.op
        if op == "/":
            return f"_sip.div({self.expr(e.left)}, {self.expr(e.right)})", ATOM
        p = PREC[op]
        if op == "**":
            return f"{self.expr(e.left, p + 1)} ** {self.expr(e.right, p)}", p
        return f"{self.expr(e.left, p)} {op} {self.expr(e.right, p + 1)}", p

    def e_Compare(self, e):
        p = PREC["cmp"]
        code = self.expr(e.left, p + 1)
        for op, right in e.ops:
            code += f" {op} {self.expr(right, p + 1)}"
        return code, p

    def e_Unary(self, e):
        if e.op == "not":
            return f"not {self.expr(e.operand, PREC['not'])}", PREC["not"]
        return f"{e.op}{self.expr(e.operand, PREC['unary'])}", PREC["unary"]

    def e_IfExpr(self, e):
        p = PREC["if"]
        return f"{self.expr(e.then, p + 1)} if {self.expr(e.cond, p + 1)} else {self.expr(e.other, p)}", p

    def e_Range(self, e):
        hi = e.hi
        if isinstance(hi, Num) and hi.text.isdigit():
            end = str(int(hi.text) + 1)
        else:
            end = f"{self.expr(hi, PREC['+'])} + 1"
        return f"range({self.expr(e.lo)}, {end})", ATOM

    def e_ListLit(self, e):
        return f"[{', '.join(self.expr(i) for i in e.items)}]", ATOM

    def e_TupleLit(self, e):
        items = [self.expr(i) for i in e.items]
        if len(items) == 1:
            return f"({items[0]},)", ATOM
        return f"({', '.join(items)})", ATOM

    def e_DictLit(self, e):
        parts = [f"**{self.expr(v, ATOM)}" if k is None else f"{self.expr(k)}: {self.expr(v)}" for k, v in e.pairs]
        return "{" + ", ".join(parts) + "}", ATOM

    def e_SetLit(self, e):
        return "{" + ", ".join(self.expr(i) for i in e.items) + "}", ATOM

    def comp_inner(self, e) -> str:
        if e.kind == "dict":
            head = f"{self.expr(e.key, PREC['if'])}: {self.expr(e.elt, PREC['if'])}"
        else:
            head = self.expr(e.elt, PREC["if"])
        clauses = []
        for c in e.clauses:
            code = f"for {self.target(c.target)} in {self.iter_expr(c.target, c.iter)}"
            code += "".join(f" if {self.expr(cond, PREC['or'])}" for cond in c.conds)
            clauses.append(code)
        return head + " " + " ".join(clauses)

    def e_Comp(self, e):
        inner = self.comp_inner(e)
        if e.kind == "list":
            return f"[{inner}]", ATOM
        if e.kind == "gen":
            return f"({inner})", ATOM
        return "{" + inner + "}", ATOM

    def e_Lambda(self, e):
        params = ", ".join(ident(p) for p in e.params)
        head = f"lambda {params}" if params else "lambda"
        return f"{head}: {self.expr(e.body)}", PREC["lambda"]


def generate(mod: Module, file: str = "<input>") -> tuple[str, list[int]]:
    gen = CodeGen(file)
    code = gen.module(mod)
    return code, gen.linemap
