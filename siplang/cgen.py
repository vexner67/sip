"""Генератор C из проверенного дерева Sip.

Выражения превращаются в выражения C. Если для выражения нужны инструкции
(генератор списка, строка с подстановками), они выводятся перед текущей
инструкцией во временные переменные. Короткое вычисление `and`, `or` и
if-выражений сохраняется: такие инструкции попадают внутрь условия.
"""

from __future__ import annotations

import ast
import re
from pathlib import Path

from .checker import ERROR_KINDS, Program
from .cregistry import JsonTypeError, Registry, cmp_fn, eq_expr, fmt_call, hash_fn, nil_code, opt_has, opt_val
from .errors import SipError
from .nodes import *  # noqa: F403
from . import types as T_
from .types import (BOOL, FLOAT, INT, RANGE, STR, UNIT, DictT, FnT, Generic, IfaceT, ListT, OptT, RecordT, SetT, SumT,
                    TaskT, TupleT,
                    ctype,
                    deep, is_ref, key, prune)

RUNTIME = (Path(__file__).parent / "native" / "sip_rt.h").read_text(encoding="utf-8")
SIMPLE = re.compile(r"^[A-Za-z_][A-Za-z_0-9]*$|^-?[0-9.]+(LL)?$")


def c_bytes(data: bytes) -> str:
    out = []
    for b in data:
        ch = chr(b)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "?":
            out.append("\\?")
        elif 32 <= b < 127:
            out.append(ch)
        else:
            out.append(f"\\{b:03o}")
    return '"' + "".join(out) + '"'


def has_call(node) -> bool:
    """Есть ли в выражении вызов (тогда важен порядок вычисления)."""
    if isinstance(node, (Call, Comp)):
        return True
    if isinstance(node, Str):
        return any(isinstance(p, Interp) for p in node.parts)
    for v in getattr(node, "__dict__", {}).values():
        if isinstance(v, Node) and not isinstance(v, (TName, TList, TDict, TTuple)) and has_call(v):
            return True
        if isinstance(v, list):
            for i in v:
                if isinstance(i, Node) and has_call(i):
                    return True
                if isinstance(i, tuple) and any(isinstance(x, Node) and has_call(x) for x in i):
                    return True
    return False


class CGen:
    def __init__(self, prog: Program, file: str, srcmap):
        self.p = prog
        self.file = file
        self.srcmap = srcmap
        self.reg = Registry()
        self.reg.const_code = self.const_code
        self.uses_http = False
        self.uses_async = False
        self.lam_rets: list = []  # тип результата многострочных лямбд, которые сейчас генерируются
        self.uid = 0
        self.fn_code: list[str] = []
        self.protos: list[str] = []
        self.statics: list[str] = []
        self.wrappers: set = set()
        self.insts: dict = {}     # имя экземпляра обобщённой функции -> (FnInfo, типы)
        self.pending: list = []   # экземпляры, код которых ещё не сгенерирован
        self.isuf = ""            # суффикс имён лямбд и вложенных функций внутри экземпляра
        self.vtables: set = set()
        # состояние текущей функции
        self.fi = None
        self.lines: list = []
        self.depth = 1
        self.decls: list[str] = []
        self.ctl: list[str] = []

    # ---------- общее ----------

    def err(self, msg, node):
        raise SipError(msg, getattr(node, "line", 0) or 0, 0, self.file)

    def ty(self, node):
        """Тип значения, которое даёт ex(node): с учётом преобразований T <-> T?."""
        return deep(getattr(node, "cty", None) or node.ty)

    def c(self, t) -> str:
        self.reg.need(t)
        return ctype(t)

    def k(self, t) -> str:
        return self.reg.need(t)

    def fresh(self, prefix="t") -> str:
        self.uid += 1
        return f"_{prefix}{self.uid}"

    def tmp(self, ct: str, prefix="t") -> str:
        name = self.fresh(prefix)
        self.decls.append(f"{ct} {name};")
        return name

    def emit(self, text: str):
        self.lines.append((self.depth, text))

    def capture(self, fn):
        saved, saved_depth = self.lines, self.depth
        self.lines = []
        code = fn()
        lines = self.lines
        self.lines, self.depth = saved, saved_depth
        return code, [(d - saved_depth, t) for d, t in lines]

    def replay(self, lines):
        for d, t in lines:
            self.lines.append((self.depth + d, t))

    def spill(self, code: str, t) -> str:
        if SIMPLE.match(code):
            return code
        name = self.tmp(self.c(t))
        self.emit(f"{name} = {code};")
        return name

    # ---------- программа ----------

    def generate(self) -> str:
        p = self.p
        for fi in list(p.fns.values()) + p.methods:
            if not fi.allparams:
                self.gen_fn(fi)  # обобщённые — по экземпляру на каждый набор типов, когда их вызовут
        self.gen_fn(p.top, top=True)
        main = self.gen_main()
        while self.pending:
            self.gen_instance(*self.pending.pop(0))
        globals_ = [f"static {self.c(v.ty)} {v.cname};" for v in p.globals.values()]
        src_lines = [line for _, _, lines in self.srcmap.files for line in lines]
        header = [
            f"/* Generated by sip from {Path(self.file).name}. Do not edit. */",
            "static const struct { int start; const char *name; } SIP_FILES[] = {",
            *[f"    {{{off}, {c_bytes(path.encode())}}}," for off, path, _ in self.srcmap.files],
            "};",
            f"#define SIP_NFILES {len(self.srcmap.files)}",
            "static const char *const SIP_SRC[] = {",
            *[f"    {c_bytes(line.encode())}," for line in src_lines],
            "};",
            f"#define SIP_NSRC {len(src_lines)}",
            *(["#define SIP_USE_HTTP 1"] if self.uses_http else []),
            *(["#define SIP_USE_ASYNC 1"] if self.uses_async else []),
        ]
        return "\n".join([*header, RUNTIME, self.reg.code(), "/* ---- программа ---- */", *globals_,
                          *self.statics, *self.protos, *self.fn_code, main]) + "\n"

    def gen_main(self) -> str:
        self.begin(self.p.top)
        m = self.p.main
        if m is not None:
            usage = Path(self.file).stem
            star = getattr(m, "stars", {}).get("*")
            for idx, (name, t, d) in enumerate(m.params):
                flag = name.replace("_", "-")
                if isinstance(prune(t), OptT):
                    t = prune(t).inner
                if idx == star:
                    usage += f" [{name.upper()}...]"
                elif d is None:
                    usage += f" {name.upper()}"
                elif prune(t) is BOOL:
                    usage += f" [--{flag}]"
                else:
                    usage += f" [--{flag} {name.upper()}]"
            u = c_bytes(usage.encode())
            self.emit("sip_args_init(argc, argv);")
            self.emit(f"sip_args_help({u});")
            args = []
            pos = 0
            rest = None
            for idx, (name, t, d) in enumerate(m.params):
                flag = c_bytes(name.replace("_", "-").encode())
                full = deep(t)
                pt = prune(full.inner) if isinstance(full, OptT) else full
                conv = {INT: "sip_arg_int", FLOAT: "sip_arg_float", BOOL: "sip_arg_bool"}.get(pt)
                var = self.tmp(self.c(full), "a")
                if idx == star:
                    rest = (var, full, flag)  # заполняется после флагов: им нужны свои значения
                elif d is None:
                    s = f"sip_positional({pos}, {c_bytes(name.encode())}, {u})"
                    pos += 1
                    self.emit(f"{var} = " + (f"{conv}({s}, {flag}, {u});" if conv else f"sip_cstr({s});"))
                elif pt is BOOL and full is pt:
                    self.emit(f"{var} = sip_flag_bool({flag}, {self.ex(d)});")
                else:
                    s = self.tmp("const char *", "s")
                    self.emit(f"{s} = sip_flag({flag}, {u});")
                    val = f"{conv}({s}, {flag}, {u})" if conv else f"sip_cstr({s})"
                    self.emit(f"{var} = {s} ? {self.convert(val, pt, full, 0)} : {self.ex(d)};")
                args.append(var)
            if rest is not None:
                var, full, flag = rest
                k = self.k(full)
                et = deep(full.elem)
                conv = {INT: "sip_arg_int", FLOAT: "sip_arg_float", BOOL: "sip_arg_bool"}.get(et)
                s = self.tmp("const char *", "s")
                val = f"{conv}({s}, {flag}, {u})" if conv else f"sip_cstr({s})"
                self.emit(f"{var} = {k}_new(0);")
                self.emit(f"while (({s} = sip_rest_next()) != NULL) {k}_push({var}, {val});")
            self.emit("sip_args_done(" + u + ");")
            call = f"{m.cname}({', '.join(args)})"
            if getattr(m, "is_async", False):  # async fn main: сразу выполнить задачу
                call = f"{self.k(TaskT(deep(m.ret)))}_await({call}, {m.node.line})"
            self.emit(call + ";")
        body = self.finish()
        return ("int main(int argc, char **argv) {\n"
                "    sip_gc_init(__builtin_frame_address(0));\n"
                "    static char sip_outbuf[1 << 16];\n"
                "    setvbuf(stdout, sip_outbuf, _IOFBF, sizeof sip_outbuf);\n"
                "    (void)argc; (void)argv;\n"
                "    sip_toplevel();\n"
                f"{body}"
                "    fflush(stdout);\n"
                "    return 0;\n"
                "}\n")

    def begin(self, fi):
        self.fi = fi
        self.lines = []
        self.decls = []
        self.depth = 1
        self.ctl = []

    def finish(self) -> str:
        out = [f"    {d}" for d in self.decls]
        out += ["    " * d + t for d, t in self.lines]
        return "\n".join(out) + ("\n" if out else "")

    def gen_fn(self, fi, top=False):
        self.begin(fi)
        vol = "volatile " if fi.has_try else ""
        params = []
        if fi.owner is not None:
            params.append(f"{self.c(fi.owner)} self")
        nested = getattr(fi, "parent", None) is not None
        if nested:
            params.append("void *envp")
            if fi.captures:
                self.decls.append(f"struct env_{fi.cname} *env = envp;")
                for v in fi.captures.values():
                    self.decls.append(f"{self.c(v.ty)} {v.cname} = env->{v.cname};")
            self.decls.append(f"{self.c(fi.recvar.ty)} {fi.recvar.cname} = {{{fi.cname}, envp}};")
        for name, t, _ in fi.params:
            var = fi.locals[name]
            if fi.has_try:
                params.append(f"{self.c(t)} p_{name}")
                self.decls.append(f"volatile {self.c(t)} {var.cname} = p_{name};")
            else:
                params.append(f"{self.c(t)} {var.cname}")
        if not top:
            for var in fi.locals.values():
                if var.kind == "local":
                    self.decls.append(f"{vol}{self.c(var.ty)} {var.cname} = {{0}};")
        for var in fi.extra:
            self.decls.append(f"{self.c(var.ty)} {var.cname} = {{0}};")
        self.block(fi.body)
        ret = deep(fi.ret)
        if ret is not UNIT:
            self.emit(f'sip_raise(SIP_E_Error, SIP_LIT("{fi.name}() ended without returning a value"), '
                      f"{self.last_line(fi)});")
        rt = self.c(ret)
        name = fi.cname + ("_impl" if fi.cache else "") + ("_body" if getattr(fi, "is_async", False) else "")
        sig = f"static {rt} {name}({', '.join(params) or 'void'})"
        self.protos.append(sig + ";")
        self.fn_code.append(sig + " {\n" + self.finish() + "}\n")
        if getattr(fi, "is_async", False):
            self.gen_async(fi, params, name, ret)
        if fi.cache:
            self.gen_cache(fi, params)

    def instance(self, fi, targs) -> str:
        """Имя C экземпляра fi для настоящих типов targs (генерируется позже)."""
        args = [deep(a) for a in targs]
        name = getattr(fi, "cname0", fi.cname) + "__" + "_".join(key(a) for a in args)
        if name not in self.insts:
            if len(self.insts) > 5000:
                self.err(f"{fi.name}(): too many instances of a generic function (recursion over growing types?)",
                         fi.node)
            self.insts[name] = (fi, args)
            self.pending.append((fi, args, name))
        return name

    def gen_instance(self, fi, args, name):
        fi.cname0 = getattr(fi, "cname0", fi.cname)
        T_.SUBST.clear()
        T_.SUBST.update(zip(fi.allparams, args))
        fi.cname = name
        self.isuf = name[len(fi.cname0):]
        try:
            self.gen_fn(fi)
        finally:
            fi.cname = fi.cname0
            self.isuf = ""
            T_.SUBST.clear()

    def call_name(self, e) -> str:
        """Имя функции C для вызова e.fn (экземпляр, если функция обобщённая)."""
        fi = e.fn
        if not fi.allparams:
            return fi.cname
        return self.instance(fi, e.targs)

    def method_name(self, fi, rt) -> str:
        """Метод fi настоящего типа rt (для T: Shape и таблиц интерфейсов)."""
        if not fi.allparams:
            return fi.cname
        return self.instance(fi, list(rt.args))

    def vtable(self, it, rt) -> str:
        """Таблица методов интерфейса it для типа rt: адрес static const структуры."""
        ik, rk = self.k(it), self.k(rt)
        name = f"vt_{ik}__{rk}"
        if name in self.vtables:
            return f"&{name}"
        self.vtables.add(name)
        rc = self.c(rt)
        slots = []
        for mname, (ps, ret) in it.methods.items():
            fi = rt.methods[mname]
            cname = self.method_name(fi, rt)
            pdecl = ", ".join(["void *o"] + [f"{self.c(t)} p{i}" for i, (_, t) in enumerate(ps)])
            args = ", ".join([f"({rc})o"] + [f"p{i}" for i in range(len(ps))])
            thunk = f"vtm_{ik}__{rk}_{mname}"
            sig = f"static {self.c(ret)} {thunk}({pdecl})"
            self.protos.append(sig + ";")
            body = f"{cname}({args});" if deep(ret) is UNIT else f"return {cname}({args});"
            self.fn_code.append(f"{sig} {{ {body} }}\n")
            slots.append(thunk)
        rthunk = f"vtr_{ik}__{rk}"
        self.protos.append(f"static void {rthunk}(sip_sb *b, void *o);")
        self.fn_code.append(f"static void {rthunk}(sip_sb *b, void *o) {{ {fmt_call(rt, 'b', f'({rc})o')} }}\n")
        slots.append(rthunk)
        self.protos.append(f"static const struct {ik}_vt {name};")
        self.fn_code.append(f"static const struct {ik}_vt {name} = {{{', '.join(slots)}}};\n")
        return f"&{name}"

    def gen_async(self, fi, params, body_name, ret):
        """async fn f(a, b): f(a, b) только создаёт задачу, тело (f_body) выполнит await."""
        self.uses_async = True
        tt = TaskT(ret)
        tk = self.k(tt)
        ft = self.k(FnT([], ret))
        names = [p.split()[-1].lstrip("*") for p in params]
        env = f"aenv_{fi.cname}"
        fields = " ".join(p + ";" for p in params) or "char _unused;"
        call = f"{body_name}({', '.join('e->' + n for n in names)})"
        thunk = (f"static {self.c(ret)} athunk_{fi.cname}(void *envp) {{ struct {env} *e = envp; (void)e; "
                 f"{'' if ret is UNIT else 'return '}{call}; }}")
        sig = f"static {tk} {fi.cname}({', '.join(params) or 'void'})"
        self.protos.append(f"struct {env} {{ {fields} }};")
        self.protos.append(sig + ";")
        sets = " ".join(f"e->{n} = {n};" for n in names)
        self.fn_code.append(thunk + "\n" + sig + f" {{ struct {env} *e = sip_alloc(sizeof *e); {sets} "
                            f"return {tk}_new(({ft}){{athunk_{fi.cname}, e}}); }}\n")

    def e_Await(self, e):
        gather = getattr(e, "gather", None)
        if gather is None:
            if e.kind == "value":
                return self.ex(e.value)
            tt = self.ty(e.value)
            return f"{self.k(tt)}_await({self.ex(e.value)}, {e.line})"
        self.uses_async = True
        res = deep(e.res)
        tt = TaskT(res)
        tk = self.k(tt)
        a = e.value.args[0]
        lt = self.ty(a)
        lst = self.spill(self.ex(a), lt)
        ts = self.tmp("sip_task **", "ts")
        i = self.tmp("int64_t", "i")
        self.emit(f"{ts} = sip_alloc((size_t)({lst}->n ? {lst}->n : 1) * sizeof(sip_task *));")
        if gather == "fns":
            self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {ts}[{i}] = &{tk}_new({lst}->d[{i}])->base;")
        else:
            self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {ts}[{i}] = &{lst}->d[{i}]->base;")
        self.emit(f"sip_gather({ts}, {lst}->n, {e.line});")
        if res is UNIT:
            return "((void)0)"
        out_t = ListT(res)
        ok = self.k(out_t)
        out = self.tmp(ok, "r")
        self.emit(f"{out} = {ok}_new({lst}->n);")
        self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {ok}_push({out}, (({tk}){ts}[{i}])->result);")
        return out

    def last_line(self, fi) -> int:
        body = fi.node.body
        return body[-1].line if body else fi.node.line

    def gen_cache(self, fi, params):
        names = [fi.locals[n].cname if not fi.has_try else f"p_{n}" for n, _, _ in fi.params]
        types = [t for _, t, _ in fi.params]
        kt = types[0] if len(types) == 1 else TupleT(types)
        dk = self.k(DictT(kt, fi.ret))
        kc = self.c(kt)
        keyexpr = names[0] if len(types) == 1 else f"(({kc}){{{', '.join(names)}}})"
        rt = self.c(fi.ret)
        memo = f"memo_{fi.cname}"
        self.statics.append(f"static {dk} {memo};")
        sig = f"static {rt} {fi.cname}({', '.join(params)})"
        self.protos.append(sig + ";")
        self.fn_code.append(f"""{sig} {{
    {kc} key = {keyexpr};
    if (SIP_UNLIKELY(!{memo})) {memo} = {dk}_new();
    int64_t j = {dk}_find({memo}, key, {hash_fn(kt)}(key));
    if (j >= 0) return {memo}->e[j].v;
    {rt} r = {fi.cname}_impl({', '.join(names)});
    {dk}_set({memo}, key, r);
    return r;
}}
""")

    # ---------- инструкции ----------

    def block(self, stmts):
        for s in stmts:
            getattr(self, "s_" + type(s).__name__)(s)

    def sub(self, stmts):
        self.depth += 1
        self.block(stmts)
        self.depth -= 1

    def s_ExprStmt(self, s):
        e = s.expr
        code = self.ex(e)
        if not code:
            return
        if isinstance(e, Call) or prune(e.ty) is UNIT:
            self.emit(code + ";")
        else:
            self.emit(f"(void)({code});")

    def store(self, target, code: str, vt):
        """Присваивание code в target. code уже вычислен (или прост)."""
        if isinstance(target, Name):
            self.emit(f"{target.var.cname} = {code};")
        elif isinstance(target, TupleLit):
            tv = self.spill(code, vt)
            items = deep(vt).items
            for i, (item, it) in enumerate(zip(target.items, items)):
                self.store(item, f"{tv}.f{i}", it)
        elif isinstance(target, SelfAttr):
            self.emit(f"self->f_{target.name} = {code};")
        elif isinstance(target, Attr):
            self.emit(f"({self.ex(target.obj)})->f_{target.name} = {code};")
        elif isinstance(target, Index):
            ot = self.ty(target.obj)
            obj = self.ex(target.obj)
            idx = self.ex(target.index)
            if target.index_kind == "list":
                self.emit(f"*{self.k(ot)}_ref({obj}, {idx}, {target.line}) = {code};")
            else:
                self.emit(f"{self.k(ot)}_set({obj}, {idx}, {code});")
        else:
            self.err("cannot assign here", target)

    def s_Assign(self, s):
        vt = self.ty(s.value)
        code = self.ex(s.value)
        complex_target = len(s.targets) > 1 or not isinstance(s.targets[0], Name)
        if complex_target:
            code = self.spill(code, vt)
        for t in s.targets:
            self.store(t, code, vt)

    def s_AnnAssign(self, s):
        self.store(s.target, self.ex(s.value), self.ty(s.value))

    def s_AugAssign(self, s):
        if hasattr(s, "as_assign"):
            return self.s_Assign(s.as_assign)
        b = s.binop
        t = s.target
        vt = self.ty(s.value)
        val = self.spill(self.ex(s.value), vt)
        tt = self.ty(t)
        if isinstance(t, Name):
            lv = t.var.cname
        elif isinstance(t, SelfAttr):
            lv = f"self->f_{t.name}"
        elif isinstance(t, Attr):
            obj = self.spill(self.ex(t.obj), self.ty(t.obj))
            lv = f"{obj}->f_{t.name}"
        elif isinstance(t, Index):
            ot = self.ty(t.obj)
            obj, idx = self.eval_args([t.obj, t.index])
            ptr = self.tmp(self.c(tt) + " *", "p")
            if t.index_kind == "list":
                self.emit(f"{ptr} = {self.k(ot)}_ref({obj}, {idx}, {t.line});")
            else:
                self.emit(f"{ptr} = {self.k(ot)}_ref({obj}, {idx}, {t.line});")
            lv = f"(*{ptr})"
        else:
            self.err("cannot assign here", t)
        self.emit(f"{lv} = {self.binop_code(b.op, tt, vt, self.ty(b), lv, val, s.line)};")

    def truthy(self, code: str, t) -> str:
        t = deep(t)
        if t is BOOL:
            return code
        if t is INT:
            return f"({code} != 0)"
        if t is FLOAT:
            return f"({code} != 0.0)"
        if t is STR:
            return f"(({code}).n != 0)"
        if t is RANGE:
            r = self.spill(code, t)
            return f"({r}.hi >= {r}.lo)"
        if isinstance(t, OptT):
            v = self.spill(code, t)
            inner = deep(t.inner)
            if isinstance(inner, (RecordT, SumT, FnT)):
                return opt_has(t, v)
            return f"({opt_has(t, v)} && {self.truthy(opt_val(t, v), inner)})"
        if isinstance(t, (RecordT, SumT, FnT)):
            return "true"
        return f"(({code})->n != 0)"

    def cond(self, node) -> str:
        return self.truthy(self.ex(node), self.ty(node))

    def s_If(self, s):
        opened = 0
        for i, (c, body) in enumerate(s.branches):
            code, pre = self.capture(lambda c=c: self.cond(c))
            if i == 0:
                self.replay(pre)
                self.emit(f"if ({code}) {{")
            elif not pre:
                self.emit(f"}} else if ({code}) {{")
            else:
                self.emit("} else {")
                self.depth += 1
                opened += 1
                self.replay(pre)
                self.emit(f"if ({code}) {{")
            self.sub(body)
        if s.orelse:
            self.emit("} else {")
            self.sub(s.orelse)
        self.emit("}")
        for _ in range(opened):
            self.depth -= 1
            self.emit("}")

    def s_While(self, s):
        code, pre = self.capture(lambda: self.cond(s.cond))
        self.ctl.append("loop")
        if not pre:
            self.emit(f"while ({code}) {{")
        else:
            self.emit("for (;;) {")
            self.depth += 1
            self.replay(pre)
            self.emit(f"if (!{code}) break;")
            self.depth -= 1
        self.sub(s.body)
        self.emit("}")
        self.ctl.pop()

    def loop(self, kind: str, it, on_elem):
        """Цикл по range, списку, словарю или строке. on_elem(code, type) пишет тело."""
        t = self.ty(it)
        k = self.tmp("int64_t", "i")
        if kind == "range":
            if isinstance(it, Range):
                lo = self.ex(it.lo)
                hi = self.spill(self.ex(it.hi), INT)
            else:
                r = self.spill(self.ex(it), RANGE)
                lo, hi = f"{r}.lo", f"{r}.hi"
            self.emit(f"for ({k} = {lo}; {k} <= {hi}; {k}++) {{")
            elem, et = k, INT
        elif kind == "list":
            lst = self.spill(self.ex(it), t)
            self.emit(f"for ({k} = 0; {k} < {lst}->n; {k}++) {{")
            elem, et = f"{lst}->d[{k}]", t.elem
        elif kind == "set":
            d = self.spill(self.ex(it), t)
            self.emit(f"for ({k} = 0; {k} < {d}->n; {k}++) {{")
            elem, et = f"{d}->e[{k}].k", t.elem
        elif kind in ("dict_keys", "dict_items"):
            d = self.spill(self.ex(it), t)
            self.emit(f"for ({k} = 0; {k} < {d}->n; {k}++) {{")
            if kind == "dict_keys":
                elem, et = f"{d}->e[{k}].k", t.key
            else:
                et = TupleT([t.key, t.val])
                elem = f"(({self.c(et)}){{{d}->e[{k}].k, {d}->e[{k}].v}})"
        elif kind == "str":
            s = self.spill(self.ex(it), STR)
            self.emit(f"for ({k} = 0; {k} < {s}.n; {k}++) {{")
            elem, et = f"((sip_str){{{s}.p + {k}, 1}})", STR
        else:
            raise AssertionError(kind)
        self.depth += 1
        on_elem(elem, et)
        self.depth -= 1
        self.emit("}")

    def bind(self, target, code, t):
        if isinstance(target, Name):
            self.emit(f"{target.var.cname} = {code};")
        else:
            self.store(target, code, t)

    def s_For(self, s):
        def body(elem, et):
            self.bind(s.target, elem, et)
            self.ctl.append("loop")
            self.block(s.body)
            self.ctl.pop()
        self.loop(s.iter_kind, s.iter, body)

    def pops(self, until_loop: bool) -> str:
        """Код выхода из блоков try и with при return/break/continue (изнутри наружу)."""
        out = ""
        for c in reversed(self.ctl):
            if c == "loop" and until_loop:
                break
            if c == "try":
                out += "sip_try_pop(); "
            elif isinstance(c, tuple) and c[0] == "with":
                out += f"sip_try_pop(); {c[1]}; "
        return out

    def s_With(self, s):
        """with x as y: y = x.enter() (если есть), в конце — x.exit(), в том числе при ошибке."""
        closes = []
        for (expr, _), (ct, enter, exit_, var) in zip(s.items, s.info):
            ctx = self.tmp(self.c(ct), "ctx")
            self.emit(f"{ctx} = {self.ex(expr)};")
            if var is not None:
                self.emit(f"{var.cname} = " + (f"{enter.cname}({ctx});" if enter is not None else f"{ctx};"))
            elif enter is not None:
                self.emit(f"{enter.cname}({ctx});")
            exit_code = f"{exit_.cname}({ctx})" if exit_ is not None else "((void)0)"
            t = self.tmp("sip_try", "try")
            self.emit(f"sip_try_push(&{t});")
            self.emit(f"if (setjmp({t}.jb) == 0) {{")
            self.depth += 1
            self.ctl.append(("with", exit_code))
            closes.append(exit_code)
        self.block(s.body)
        for exit_code in reversed(closes):
            self.ctl.pop()
            self.emit(f"sip_try_pop(); {exit_code};")
            self.depth -= 1
            self.emit("} else {")
            self.emit(f"    {exit_code};")
            self.emit("    sip_reraise();")
            self.emit("}")

    def s_Return(self, s):
        n = self.pops(False)
        if s.value is None or deep(s.value.ty) is UNIT:
            if s.value is not None:
                code = self.ex(s.value)
                if code:
                    self.emit(code + ";")
            self.emit(n + "return;")
            return
        code = self.ex(s.value)
        if n:
            code = self.spill(code, self.lam_rets[-1] if self.lam_rets else self.fi.ret)
        self.emit(n + f"return {code};")

    def s_Break(self, s):
        self.emit(self.pops(True) + "break;")

    def s_Continue(self, s):
        self.emit(self.pops(True) + "continue;")

    def s_Pass(self, s):
        pass

    def s_FnDef(self, s):
        fi = s.fi
        base = fi.cname
        fi.cname = base + self.isuf  # своя копия в каждом экземпляре обобщённой функции
        try:
            self.nested_fn(s, fi)
        finally:
            fi.cname = base

    def nested_fn(self, s, fi):
        caps = list(fi.captures.values())
        if caps:
            fields = " ".join(f"{self.c(v.ty)} {v.cname};" for v in caps)
            self.statics.append(f"struct env_{fi.cname} {{ {fields} }};")
        saved = (self.fi, self.lines, self.decls, self.depth, self.ctl)
        self.gen_fn(fi)
        self.fi, self.lines, self.decls, self.depth, self.ctl = saved
        fk = self.k(s.var.ty)
        env = "NULL"
        if caps:
            env = self.tmp(f"struct env_{fi.cname} *", "env")
            self.emit(f"{env} = sip_alloc(sizeof *{env});")
            for v in caps:
                self.emit(f"{env}->{v.cname} = {v.cname};")
        self.emit(f"{s.var.cname} = (({fk}){{{fi.cname}, {env}}});")

    def to_str(self, code: str, t) -> str:
        t = deep(t)
        if t is STR:
            return code
        if t is INT:
            return f"sip_int_to_str({code})"
        sb = self.tmp("sip_sb", "sb")
        self.emit(f"{sb} = sip_sb_new();")
        self.emit(fmt_call(t, f"&{sb}", code))
        return f"sip_sb_done(&{sb})"

    def s_Fail(self, s):
        msg = self.to_str(self.ex(s.value), self.ty(s.value))
        self.emit(f"sip_raise(SIP_E_Error, {msg}, {s.line});")

    def s_Assert(self, s):
        c = self.cond(s.cond)
        self.emit(f"if (SIP_UNLIKELY(!{c})) {{")
        self.depth += 1
        msg = self.to_str(self.ex(s.msg), self.ty(s.msg)) if s.msg is not None else 'SIP_LIT("assertion failed")'
        self.emit(f"sip_raise(SIP_E_AssertionError, {msg}, {s.line});")
        self.depth -= 1
        self.emit("}")

    def s_Try(self, s):
        t = self.tmp("sip_try", "try")
        self.emit(f"sip_try_push(&{t});")
        self.emit(f"if (setjmp({t}.jb) == 0) {{")
        self.ctl.append("try")
        self.sub(s.body)
        self.ctl.pop()
        self.depth += 1
        self.emit("sip_try_pop();")
        self.depth -= 1
        self.emit("} else {")
        self.depth += 1
        for i, h in enumerate(s.handlers):
            if h.kind is None or h.kind == "Exception":
                c = "1"
            else:
                c = f"sip_kind_matches(sip_err_kind, SIP_E_{h.kind})"
            self.emit(("if" if i == 0 else "} else if") + f" ({c}) {{")
            self.depth += 1
            if h.name:
                self.emit(f"{h.var.cname} = sip_err_msg;")
            self.block(h.body)
            self.depth -= 1
        self.emit("} else {")
        self.emit("    sip_reraise();")
        self.emit("}")
        self.depth -= 1
        self.emit("}")

    def s_Match(self, s):
        st = self.ty(s.subject)
        subj = self.spill(self.ex(s.subject), st)
        end = self.fresh("match_end")
        for arm in s.arms:
            tests, binds = self.pat(arm.pattern, subj, st)
            self.emit(f"if ({' && '.join(tests) or '1'}) {{")
            self.depth += 1
            for b in binds:
                self.emit(b)
            if arm.guard is not None:
                g = self.cond(arm.guard)
                self.emit(f"if ({g}) {{")
                self.sub(arm.body)
                self.depth += 1
                self.emit(f"goto {end};")
                self.depth -= 1
                self.emit("}")
            else:
                self.block(arm.body)
                self.emit(f"goto {end};")
            self.depth -= 1
            self.emit("}")
        self.emit(f"{end}:;")

    def pat(self, p, path: str, t):
        t = deep(t)
        if isinstance(p, PWild):
            return [], []
        if getattr(p, "nil", False):
            return [f"(!{opt_has(t, path)})"], []
        if getattr(p, "unwrap", False) and isinstance(t, OptT):
            inner = opt_val(t, path)
            p.unwrap = False
            try:
                tests, binds = self.pat(p, inner, t.inner)
            finally:
                p.unwrap = True
            return [opt_has(t, path)] + tests, binds
        if isinstance(p, PCapture):
            return [], [f"{p.var.cname} = {path};"]
        if isinstance(p, PLit):
            return [eq_expr(t, path, self.ex(p.expr))], []
        if isinstance(p, PClass):
            tests, binds = [], []
            if isinstance(t, SumT):
                tests.append(f"{path}->tag == {p.variant}")
                base = f"{path}->u.{p.name}"
                fields = dict(t.variants[p.name])
            else:
                base = path
                fields = t.fields
            pairs = list(zip(p.fields, p.args)) + list(zip(p.kwfields, [v for _, v in p.kwargs]))
            for fname, sub in pairs:
                st, sb = self.pat(sub, f"{base}{'.' if isinstance(t, SumT) else '->'}f_{fname}", fields[fname])
                tests += st
                binds += sb
            return tests, binds
        if isinstance(p, PTuple):
            tests, binds = [], []
            for i, (sub, it) in enumerate(zip(p.items, t.items)):
                st, sb = self.pat(sub, f"({path}).f{i}", it)
                tests += st
                binds += sb
            return tests, binds
        if isinstance(p, PList):
            star = p.items and isinstance(p.items[-1], PStar)
            fixed = len(p.items) - (1 if star else 0)
            tests = [f"{path}->n {'>=' if star else '=='} {fixed}"]
            binds = []
            for i, sub in enumerate(p.items[:fixed]):
                st, sb = self.pat(sub, f"{path}->d[{i}]", t.elem)
                tests += st
                binds += sb
            if star:
                binds.append(f"{p.items[-1].var.cname} = {self.k(t)}_slice({path}, {fixed}, 0, true, false);")
            return tests, binds
        if isinstance(p, POr):
            alts = []
            for alt in p.alts:
                st, _ = self.pat(alt, path, t)
                alts.append("(" + (" && ".join(st) or "1") + ")")
            return ["(" + " || ".join(alts) + ")"], []
        self.err("unsupported pattern", p)

    # ---------- выражения ----------

    def ex(self, e) -> str:
        code = getattr(self, "e_" + type(e).__name__)(e)
        to = getattr(e, "cty", None)
        if to is not None and code:
            code = self.convert(code, e.ty, to, e.line)
        return code

    def convert(self, code: str, raw, to, line) -> str:
        raw, to = deep(raw), deep(to)
        inner = to.inner if isinstance(to, OptT) else to
        if isinstance(inner, IfaceT) and not isinstance(raw, (IfaceT, OptT)):
            code = f"(({self.c(inner)}){{(void *)({code}), {self.vtable(inner, raw)}}})"
            raw = inner
        if isinstance(raw, OptT) and not isinstance(to, OptT):
            return f"unwrap_{self.k(raw)}({code}, {line})"
        if isinstance(to, OptT) and not isinstance(raw, OptT):
            self.k(to)
            return code if is_ref(to.inner) else f"(({ctype(to)}){{true, {code}}})"
        return code

    def call_fn(self, f: str, args) -> str:
        return f"{f}.fn({f}.env{''.join(', ' + a for a in args)})"

    def eval_args(self, nodes) -> list[str]:
        """Аргументы вычисляются слева направо, как в Python."""
        codes = []
        for n in nodes:
            code, pre = self.capture(lambda n=n: self.ex(n))
            if pre and codes:
                codes = [self.spill(c, self.ty(nd)) for c, nd in zip(codes, nodes)]
            self.replay(pre)
            codes.append(code)
        if sum(1 for n in nodes if has_call(n)) >= 2:
            codes = [self.spill(c, self.ty(n)) for c, n in zip(codes, nodes)]
        return codes

    def e_Num(self, e):
        text = e.text.replace("_", "")
        if prune(e.ty) is FLOAT:
            if "." not in text and "e" not in text.lower():
                text += ".0"
            return text
        if int(text) >= 2 ** 63:
            self.err("integer literal is too large for int (64-bit)", e)
        return f"{text}LL" if int(text) > 2 ** 31 - 1 else text

    def lit(self, raw: str, quote: str) -> bytes:
        return ast.literal_eval(quote + raw + quote).encode("utf-8")

    def e_Str(self, e):
        if all(isinstance(p, str) for p in e.parts):
            data = self.lit("".join(e.parts), e.quote)
            return f"SIP_LIT({c_bytes(data)})"
        sb = self.tmp("sip_sb", "sb")
        self.emit(f"{sb} = sip_sb_new();")
        self.str_parts(e, f"&{sb}")
        return f"sip_sb_done(&{sb})"

    def str_parts(self, e: Str, sb: str):
        for part in e.parts:
            if isinstance(part, str):
                data = self.lit(part, e.quote)
                if data:
                    self.emit(f"sip_sb_put({sb}, {c_bytes(data)}, {len(data)});")
                continue
            code = self.ex(part.expr)
            t = self.ty(part.expr)
            if part.spec is None:
                self.emit(fmt_call(t, sb, code))
            else:
                fmt, kind = self.spec(part.spec, t, part.expr)
                if kind == "float" and t is INT:
                    code = f"(double)({code})"
                self.emit(f"sip_fmt_{kind}({sb}, {c_bytes(fmt.encode())}, {code});")

    def spec(self, spec: str, t, node):
        m = re.fullmatch(r"([<>])?([+ ])?(0)?(\d+)?(\.\d+)?([dfFeEgGxXos%])?", spec)
        if not m:
            self.err(f"unsupported format spec ':{spec}'", node)
        align, sign, zero, width, prec, typ = m.groups()
        flags = ("-" if align == "<" or (align is None and t is STR) else "") + (sign or "") + (zero or "")
        width = width or ""
        if t is STR:
            if typ not in (None, "s") or prec:
                self.err(f"format ':{spec}' does not apply to str", node)
            return f"%{flags}{width}.*s", "str"
        if typ in ("f", "F", "e", "E", "g", "G") or (t is FLOAT and typ is None) or prec:
            if typ == "%":
                self.err("format '%' is not supported", node)
            return f"%{flags}{width}{prec or ''}{typ or 'g'}", "float"
        if typ in (None, "d", "x", "X", "o"):
            return f"%{flags}{width}ll{typ or 'd'}", "int"
        self.err(f"unsupported format spec ':{spec}'", node)

    def e_Const(self, e):
        if e.value == "None":
            self.k(e.ty)
            return nil_code(e.ty)
        return "true" if e.value == "True" else "false"

    def e_Name(self, e):
        if hasattr(e, "var"):
            return e.var.cname
        if hasattr(e, "fnref"):
            return self.fn_value(e.fnref, deep(e.ty))
        if hasattr(e, "const"):
            return e.const
        st, vname = e.variant
        return f"{self.k(st)}_new_{vname}()"

    def fn_value(self, fi, ft) -> str:
        """Обычная функция как значение: обёртка с пустым окружением."""
        fk = self.k(ft)
        name = f"fnv_{fi.cname}"
        if name not in self.wrappers:
            self.wrappers.add(name)
            ps = [f"{self.c(t)} p{i}" for i, t in enumerate(ft.params)]
            call = f"{fi.cname}({', '.join(f'p{i}' for i in range(len(ps)))})"
            body = f"{call};" if deep(ft.ret) is UNIT else f"return {call};"
            sig = f"static {self.c(ft.ret)} {name}({', '.join(['void *env'] + ps)})"
            self.protos.append(sig + ";")
            self.fn_code.append(f"{sig} {{ (void)env; {body} }}\n")
        return f"(({fk}){{{name}, NULL}})"

    def e_Lambda(self, e):
        ft = deep(e.ty)
        fk = self.k(ft)
        lid = f"{e.lid}{self.isuf}"
        name = f"lam_{lid}"
        caps = list(e.captures.values())
        if caps:
            fields = " ".join(f"{self.c(v.ty)} {v.cname};" for v in caps)
            self.statics.append(f"struct env_{lid} {{ {fields} }};")
        # тело лямбды — отдельная функция C со своим состоянием генератора
        saved = (self.lines, self.decls, self.depth, self.ctl)
        self.lines, self.decls, self.depth, self.ctl = [], [], 1, []
        if caps:
            self.decls.append(f"struct env_{lid} *env = envp;")
            for v in caps:
                self.decls.append(f"{self.c(v.ty)} {v.cname} = env->{v.cname};")
        vol = "volatile " if getattr(e, "has_try", False) else ""
        for v in e.extra + getattr(e, "locals", []):
            self.decls.append(f"{vol}{self.c(v.ty)} {v.cname} = {{0}};")
        if e.block is not None:
            self.lam_rets.append(deep(ft.ret))
            try:
                self.block(e.block)
            finally:
                self.lam_rets.pop()
            if deep(ft.ret) is not UNIT:
                self.emit(f'sip_raise(SIP_E_Error, SIP_LIT("the lambda ended without returning a value"), {e.line});')
        else:
            code = self.ex(e.body)
            if deep(ft.ret) is UNIT:
                if code:
                    self.emit(code + ";")
            else:
                self.emit(f"return {code};")
        body = self.finish()
        self.lines, self.decls, self.depth, self.ctl = saved
        params = ["void *envp"] + [f"{self.c(v.ty)} {v.cname}" for v in e.pvars]
        sig = f"static {self.c(ft.ret)} {name}({', '.join(params)})"
        self.protos.append(sig + ";")
        self.fn_code.append(sig + " {\n" + body + "}\n")
        if not caps:
            return f"(({fk}){{{name}, NULL}})"
        env = self.tmp(f"struct env_{lid} *", "env")
        self.emit(f"{env} = sip_alloc(sizeof *{env});")
        for v in caps:
            self.emit(f"{env}->{v.cname} = {v.cname};")
        return f"(({fk}){{{name}, {env}}})"

    def e_SelfAttr(self, e):
        return f"self->f_{e.name}"

    def e_Attr(self, e):
        return f"({self.ex(e.obj)})->f_{e.name}"

    def e_Index(self, e):
        kind = e.index_kind
        ot = self.ty(e.obj)
        if kind == "tuple":
            return f"({self.ex(e.obj)}).f{e.tuple_index}"
        if kind in ("slice_list", "slice_str"):
            sl = e.index
            parts = [e.obj] + [x for x in (sl.lo, sl.hi) if x is not None]
            codes = self.eval_args(parts)
            obj = codes[0]
            rest = iter(codes[1:])
            lo = next(rest) if sl.lo is not None else "0"
            hi = next(rest) if sl.hi is not None else "0"
            flags = f"{'true' if sl.lo is not None else 'false'}, {'true' if sl.hi is not None else 'false'}"
            fn = f"{self.k(ot)}_slice" if kind == "slice_list" else "sip_str_slice"
            return f"{fn}({obj}, {lo}, {hi}, {flags})"
        obj, idx = self.eval_args([e.obj, e.index])
        if kind == "list":
            return f"{self.k(ot)}_get({obj}, {idx}, {e.line})"
        if kind == "dict":
            return f"{self.k(ot)}_get({obj}, {idx}, {e.line})"
        return f"sip_str_at({obj}, {idx}, {e.line})"

    def e_Call(self, e):
        kind = e.ckind
        if kind == "fn":
            return f"{self.call_name(e)}({', '.join(self.eval_args(e.bound))})"
        if kind == "method":
            codes = self.eval_args([e.func.obj] + e.bound)
            return f"{self.call_name(e)}({', '.join(codes)})"
        if kind == "imethod":
            rt = deep(self.ty(e.func.obj))
            codes = self.eval_args([e.func.obj] + e.bound)
            if isinstance(rt, IfaceT):  # через таблицу методов
                r = self.spill(codes[0], rt)
                return f"{r}.vt->m_{e.mname}({', '.join([r + '.o'] + codes[1:])})"
            return f"{self.method_name(rt.methods[e.mname], rt)}({', '.join(codes)})"
        if kind == "ctor":
            return f"{self.k(e.record)}_new({', '.join(self.eval_args(e.bound))})"
        if kind == "variant":
            st, vname = e.variant
            return f"{self.k(st)}_new_{vname}({', '.join(self.eval_args(e.bound))})"
        if kind == "closure":
            codes = self.eval_args([e.func] + e.bound)
            f = self.spill(codes[0], self.ty(e.func))
            return self.call_fn(f, codes[1:])
        if kind == "builtin":
            return getattr(self, "b_" + e.bname.replace(".", "_"))(e)
        if kind == "bmethod":
            rt = deep(self.ty(e.recv))
            prefix = "ms" if rt is STR else "ml" if isinstance(rt, ListT) else "mz" if isinstance(rt, SetT) else "md"
            return getattr(self, f"{prefix}_{e.mname}")(e, rt)
        raise AssertionError(kind)

    def binop_code(self, op, lt, rt, res, lc, rc, line) -> str:
        lt, rt, res = deep(lt), deep(rt), deep(res)
        both_int = lt is INT and rt is INT
        if op in ("+", "-", "*") and lt in (INT, FLOAT) and rt in (INT, FLOAT):
            return f"({lc} {op} {rc})"
        if op == "/":
            if both_int:
                return f"sip_floordiv({lc}, {rc}, {line})"
            return f"sip_fdiv({lc}, {rc}, {line})"
        if op == "//":
            return f"sip_floordiv({lc}, {rc}, {line})" if both_int else f"sip_ffloordiv({lc}, {rc}, {line})"
        if op == "%":
            return f"sip_mod({lc}, {rc}, {line})" if both_int else f"sip_fmod({lc}, {rc}, {line})"
        if op == "**":
            return f"sip_ipow({lc}, {rc}, {line})" if both_int else f"pow({lc}, {rc})"
        if op == "+" and lt is STR:
            return f"sip_str_concat({lc}, {rc})"
        if op == "*" and lt is STR:
            return f"sip_str_repeat({lc}, {rc})"
        if op == "+" and isinstance(lt, ListT):
            return f"{self.k(res)}_concat({lc}, {rc})"
        if op == "*" and isinstance(lt, ListT):
            return f"{self.k(lt)}_repeat({lc}, {rc})"
        if op == "|" and isinstance(lt, DictT):
            return f"{self.k(res)}_merge({lc}, {rc})"
        if isinstance(lt, SetT):
            fn = {"|": "union", "&": "inter", "-": "diff", "^": "xor"}[op]
            return f"{self.k(lt)}_{fn}({lc}, {rc})"
        if op in ("|", "&", "^"):
            return f"({lc} {op} {rc})"
        raise AssertionError(op)

    def e_BinOp(self, e):
        if e.op in ("and", "or"):
            return self.logic(e)
        lc, rc = self.eval_args([e.left, e.right])
        return self.binop_code(e.op, self.ty(e.left), self.ty(e.right), e.ty, lc, rc, e.line)

    def logic(self, e):
        res = deep(e.ty)
        if getattr(e, "logic_bool", False):
            lc = self.cond(e.left)
            rc, pre = self.capture(lambda: self.cond(e.right))
            if not pre:
                return f"({lc} {'&&' if e.op == 'and' else '||'} {rc})"
            t = self.tmp("bool")
            self.emit(f"{t} = {lc};")
            self.emit(f"if ({'' if e.op == 'and' else '!'}{t}) {{")
            self.depth += 1
            self.replay(pre)
            self.emit(f"{t} = {rc};")
            self.depth -= 1
            self.emit("}")
            return t
        if getattr(e, "opt_or", False):
            lt = self.ty(e.left)
            left = self.spill(self.ex(e.left), lt)
            rc, pre = self.capture(lambda: self.ex(e.right))
            t = self.tmp(self.c(res))
            self.emit(f"if ({self.truthy(left, lt)}) {{")
            self.emit(f"    {t} = {opt_val(lt, left)};")
            self.emit("} else {")
            self.depth += 1
            self.replay(pre)
            self.emit(f"{t} = {rc};")
            self.depth -= 1
            self.emit("}")
            return t
        lc = self.ex(e.left)
        rc, pre = self.capture(lambda: self.ex(e.right))
        lt, rt = deep(self.ty(e.left)), deep(self.ty(e.right))
        if res is BOOL and lt is BOOL and rt is BOOL and not pre:
            return f"({lc} {'&&' if e.op == 'and' else '||'} {rc})"
        t = self.tmp(self.c(res))
        self.emit(f"{t} = {lc};")
        test = self.truthy(t, res)
        self.emit(f"if ({'' if e.op == 'and' else '!'}{test}) {{")
        self.depth += 1
        self.replay(pre)
        self.emit(f"{t} = {rc};")
        self.depth -= 1
        self.emit("}")
        return t

    def cmp_code(self, op, lt, rt, lc, rc) -> str:
        lt, rt = deep(lt), deep(rt)
        if op in ("in", "not in"):
            neg = "!" if op == "not in" else ""
            if isinstance(rt, SetT):
                return f"{neg}{self.k(DictT(rt.elem, BOOL))}_contains({rc}, {lc})"
            if isinstance(rt, (ListT, DictT)):
                return f"{neg}{self.k(rt)}_contains({rc}, {lc})"
            if rt is STR:
                return f"{neg}sip_str_contains({rc}, {lc})"
            r = self.spill(rc, RANGE)
            x = self.spill(lc, INT)
            return f"{neg}({x} >= {r}.lo && {x} <= {r}.hi)"
        if lt in (INT, FLOAT, BOOL) and rt in (INT, FLOAT, BOOL):
            return f"({lc} {op} {rc})"
        if isinstance(lt, SetT) and op in ("<=", "<", ">=", ">"):
            a, b = (lc, rc) if op in ("<=", "<") else (rc, lc)
            a, b = self.spill(a, lt), self.spill(b, lt)
            sub = f"{self.k(lt)}_subset({a}, {b})"
            return sub if op in ("<=", ">=") else f"({sub} && {a}->n < {b}->n)"
        if op == "==":
            return eq_expr(lt, lc, rc)
        if op == "!=":
            return "!" + eq_expr(lt, lc, rc)
        return f"({cmp_fn(lt)}({lc}, {rc}) {op} 0)"

    def e_Compare(self, e):
        nodes = [e.left] + [r for _, r in e.ops]
        codes = self.eval_args(nodes)
        if len(e.ops) > 1:
            codes = [codes[0]] + [self.spill(c, self.ty(n)) for c, n in zip(codes[1:], nodes[1:])]
        parts = []
        nilcmp = getattr(e, "nilcmp", [False] * len(e.ops))
        for i, (op, _) in enumerate(e.ops):
            if nilcmp[i]:
                j = i if not (isinstance(nodes[i], Const) and nodes[i].value == "None") else i + 1
                ot = self.ty(nodes[j])
                test = (f"({codes[j]} == NULL)" if is_ref(ot.inner) else f"(!({codes[j]}).has)") \
                    if isinstance(ot, OptT) else "false"
                parts.append(test if op in ("==", "is") else f"(!{test})")
                continue
            parts.append(self.cmp_code(op, self.ty(nodes[i]), self.ty(nodes[i + 1]), codes[i], codes[i + 1]))
        return parts[0] if len(parts) == 1 else "(" + " && ".join(parts) + ")"

    def e_Unary(self, e):
        code = self.ex(e.operand)
        if e.op == "not":
            return f"(!{self.truthy(code, self.ty(e.operand))})"
        return f"({e.op}{code})"

    def e_IfExpr(self, e):
        c = self.cond(e.cond)
        conv = getattr(e, "stringify", False)

        def branch(n):
            code = self.ex(n)
            return self.to_str(code, self.ty(n)) if conv else code
        a, pa = self.capture(lambda: branch(e.then))
        b, pb = self.capture(lambda: branch(e.other))
        if not pa and not pb:
            return f"({c} ? {a} : {b})"
        t = self.tmp(self.c(e.ty))
        self.emit(f"if ({c}) {{")
        self.depth += 1
        self.replay(pa)
        self.emit(f"{t} = {a};")
        self.depth -= 1
        self.emit("} else {")
        self.depth += 1
        self.replay(pb)
        self.emit(f"{t} = {b};")
        self.depth -= 1
        self.emit("}")
        return t

    def e_Range(self, e):
        lo, hi = self.eval_args([e.lo, e.hi])
        return f"((sip_range){{{lo}, {hi}}})"

    def e_ListLit(self, e):
        k = self.k(e.ty)
        lst = self.tmp(k, "l")
        self.emit(f"{lst} = {k}_new({len(e.items)});")
        for item in e.items:
            self.emit(f"{k}_push({lst}, {self.ex(item)});")
        return lst

    def e_TupleLit(self, e):
        codes = self.eval_args(e.items)
        return f"(({self.c(e.ty)}){{{', '.join(codes)}}})"

    def e_SetLit(self, e):
        st = deep(e.ty)
        k = self.k(DictT(st.elem, BOOL))
        self.k(st)
        d = self.tmp(k, "set")
        self.emit(f"{d} = {k}_new();")
        for item in e.items:
            self.emit(f"{k}_set({d}, {self.ex(item)}, true);")
        return d

    def e_DictLit(self, e):
        k = self.k(e.ty)
        d = self.tmp(k, "d")
        self.emit(f"{d} = {k}_new();")
        for kn, vn in e.pairs:
            kc, vc = self.eval_args([kn, vn])
            self.emit(f"{k}_set({d}, {kc}, {vc});")
        return d

    def comp_loops(self, clauses, i, inner):
        c = clauses[i]

        def body(elem, et):
            self.bind(c.target, elem, et)
            for cond in c.conds:
                code, pre = self.capture(lambda cond=cond: self.cond(cond))
                self.replay(pre)
                self.emit(f"if (!{code}) continue;")
            if i + 1 < len(clauses):
                self.comp_loops(clauses, i + 1, inner)
            else:
                inner()
        self.loop(c.iter_kind, c.iter, body)

    def e_Comp(self, e):
        k = self.k(e.ty)
        res = self.tmp(self.c(e.ty), "c")
        if e.kind == "set":
            dk = self.k(DictT(deep(e.ty).elem, BOOL))
            self.emit(f"{res} = {dk}_new();")
            self.comp_loops(e.clauses, 0, lambda: self.emit(f"{dk}_set({res}, {self.ex(e.elt)}, true);"))
        elif e.kind == "dict":
            self.emit(f"{res} = {k}_new();")
            self.comp_loops(e.clauses, 0, lambda: self.emit(
                f"{k}_set({res}, {', '.join(self.eval_args([e.key, e.elt]))});"))
        else:
            self.emit(f"{res} = {k}_new(0);")
            self.comp_loops(e.clauses, 0, lambda: self.emit(f"{k}_push({res}, {self.ex(e.elt)});"))
        return res

    # ---------- свёртки: sum, avg, min, max, any, all ----------

    def each(self, node, inner):
        """Перебор элементов списка, range или генератора без промежуточного списка."""
        if isinstance(node, Comp) and node.kind in ("gen", "list"):
            self.comp_loops(node.clauses, 0, lambda: inner(self.ex(node.elt), self.ty(node.elt)))
            return
        t = self.ty(node)
        kind = "range" if t is RANGE else "set" if isinstance(t, SetT) else "list"
        self.loop(kind, node, inner)

    def reduce(self, kind, node, res, line):
        res = deep(res)
        end = self.fresh("red_end")
        if kind == "sum":
            acc = self.tmp(self.c(res), "acc")
            self.emit(f"{acc} = 0;")
            self.each(node, lambda c, t: self.emit(f"{acc} += {c};"))
            return acc
        if kind == "avg":
            acc = self.tmp("double", "acc")
            n = self.tmp("int64_t", "n")
            self.emit(f"{acc} = 0.0; {n} = 0;")
            self.each(node, lambda c, t: self.emit(f"{acc} += {c}; {n}++;"))
            self.emit(f'if (SIP_UNLIKELY({n} == 0)) sip_raise(SIP_E_ValueError, SIP_LIT("avg() of an empty sequence"), {line});')
            return f"({acc} / (double){n})"
        if kind in ("min", "max"):
            acc = self.tmp(self.c(res), "acc")
            has = self.tmp("bool", "has")
            self.emit(f"{has} = false;")
            op = "<" if kind == "min" else ">"

            def step(c, t):
                v = self.spill(c, t)
                better = self.cmp_code(op, t, res, v, acc)
                self.emit(f"if (!{has} || {better}) {{ {acc} = {v}; {has} = true; }}")
            self.each(node, step)
            self.emit(f'if (SIP_UNLIKELY(!{has})) sip_raise(SIP_E_ValueError, SIP_LIT("{kind}() of an empty sequence"), {line});')
            return acc
        if kind in ("any", "all"):
            acc = self.tmp("bool", "acc")
            want = kind == "any"
            self.emit(f"{acc} = {'false' if want else 'true'};")

            def step(c, t):
                test = self.truthy(c, t)
                self.emit(f"if ({'' if want else '!'}{test}) {{ {acc} = {'true' if want else 'false'}; goto {end}; }}")
            self.each(node, step)
            self.emit(f"{end}:;")
            return acc
        raise AssertionError(kind)

    # ---------- встроенные функции ----------

    def b_print(self, e):
        sb = "&sip_out_line"
        for i, a in enumerate(e.args):
            if i:
                self.emit(f"sip_sb_putc({sb}, ' ');")
            if isinstance(a, Str) and any(isinstance(p, Interp) for p in a.parts):
                self.str_parts(a, sb)
            else:
                self.emit(fmt_call(self.ty(a), sb, self.ex(a)))
        self.emit("sip_print_line();")
        return ""

    def b_len(self, e):
        (a,) = e.args
        t = self.ty(a)
        code = self.ex(a)
        if t is STR:
            return f"({code}).n"
        if isinstance(t, TupleT):
            return str(len(t.items))
        if t is RANGE:
            r = self.spill(code, t)
            return f"({r}.hi >= {r}.lo ? {r}.hi - {r}.lo + 1 : 0)"
        return f"({code})->n"

    def b_str(self, e):
        (a,) = e.args
        return self.to_str(self.ex(a), self.ty(a))

    def b_int(self, e):
        (a,) = e.args
        t = self.ty(a)
        code = self.ex(a)
        if t is STR:
            return f"sip_parse_int({code}, {e.line})"
        return code if t is INT else f"((int64_t)({code}))"

    def b_float(self, e):
        (a,) = e.args
        t = self.ty(a)
        code = self.ex(a)
        if t is STR:
            return f"sip_parse_float({code}, {e.line})"
        return f"((double)({code}))"

    def b_bool(self, e):
        return self.cond(e.args[0])

    def b_abs(self, e):
        (a,) = e.args
        code = self.ex(a)
        return f"llabs({code})" if self.ty(a) is INT else f"fabs({code})"

    def minmax(self, e):
        if e.minmax_seq and getattr(e, "minmax_key", None) is not None:
            return self.minmax_key(e)
        if e.minmax_seq:
            return self.reduce(e.bname, e.args[0], e.ty, e.line)
        res = deep(e.ty)
        codes = [self.spill(c, self.ty(n)) for c, n in zip(self.eval_args(e.args), e.args)]
        acc = self.tmp(self.c(res), "acc")
        self.emit(f"{acc} = {codes[0]};")
        op = "<" if e.bname == "min" else ">"
        for c, n in zip(codes[1:], e.args[1:]):
            self.emit(f"if ({self.cmp_code(op, self.ty(n), res, c, acc)}) {acc} = {c};")
        return acc

    b_min = b_max = minmax

    def minmax_key(self, e):
        res = deep(e.ty)
        f = None
        acc = self.tmp(self.c(res), "acc")
        ft = self.ty(e.minmax_key)
        kt = deep(ft.ret)
        best = self.tmp(self.c(kt), "bk")
        has = self.tmp("bool", "has")
        self.emit(f"{has} = false;")
        f = self.spill(self.ex(e.minmax_key), ft)
        op = "<" if e.bname == "min" else ">"

        def step(c, t):
            v = self.spill(c, t)
            kv = self.spill(self.call_fn(f, [v]), kt)
            better = self.cmp_code(op, kt, kt, kv, best)
            self.emit(f"if (!{has} || {better}) {{ {acc} = {v}; {best} = {kv}; {has} = true; }}")
        self.each(e.args[0], step)
        self.emit(f'if (SIP_UNLIKELY(!{has})) sip_raise(SIP_E_ValueError, SIP_LIT("{e.bname}() of an empty sequence"), {e.line});')
        return acc

    def b_sum(self, e):
        return self.reduce("sum", e.args[0], e.ty, e.line)

    def b_avg(self, e):
        return self.reduce("avg", e.args[0], e.ty, e.line)

    def b_any(self, e):
        return self.reduce("any", e.args[0], e.ty, e.line)

    def b_all(self, e):
        return self.reduce("all", e.args[0], e.ty, e.line)

    def kwarg(self, e, name, default):
        for k, v in e.kwargs:
            if k == name:
                return self.ex(v)
        return default

    def b_sorted(self, e):
        (a,) = e.args
        lt = deep(e.ty)
        k = self.k(lt)
        r = self.tmp(k, "s")
        code, _ = self.as_list(a)
        self.emit(f"{r} = {k}_copy({code});")
        self.sort_list(e, r, lt)
        return r

    def sort_list(self, e, lst: str, lt):
        """Сортировка списка на месте; с key: ключи считаются один раз, порядок равных сохраняется."""
        k = self.k(lt)
        rev = self.spill(self.kwarg(e, "reverse", "false"), BOOL)
        if getattr(e, "sort_key", None) is None:
            self.emit(f"{k}_sort({lst}, {rev});")
            return
        f = self.spill(self.ex(e.sort_key), self.ty(e.sort_key))
        kt = deep(e.sort_key_ty)
        pt = TupleT([kt, INT])
        pk = self.k(ListT(pt))
        pairs = self.tmp(pk, "kp")
        i = self.tmp("int64_t", "i")
        tmp = self.tmp(f"{self.c(lt.elem)} *", "buf")
        # (ключ, ±номер): при reverse номера отрицательны, и равные остаются в исходном порядке
        self.emit(f"{pairs} = {pk}_new({lst}->n);")
        self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {pk}_push({pairs}, (({self.c(pt)}){{"
                  f"{self.call_fn(f, [f'{lst}->d[{i}]'])}, {rev} ? -{i} : {i}}}));")
        self.emit(f"{pk}_sort({pairs}, {rev});")
        self.emit(f"{tmp} = malloc((size_t)({lst}->n ? {lst}->n : 1) * sizeof *{tmp});")
        self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {tmp}[{i}] = {lst}->d[{rev} ? -{pairs}->d[{i}].f1 : {pairs}->d[{i}].f1];")
        self.emit(f"if ({lst}->n) memcpy({lst}->d, {tmp}, (size_t){lst}->n * sizeof *{tmp});")
        self.emit(f"free({tmp});")

    def as_list(self, node):
        """Список из списка, range, строки или словаря (ключи)."""
        t = self.ty(node)
        if isinstance(t, ListT):
            return self.ex(node), t
        lt = ListT(INT if t is RANGE else STR if t is STR else t.elem if isinstance(t, SetT) else t.key)
        k = self.k(lt)
        if isinstance(t, SetT):
            lt = ListT(t.elem)
            return f"{self.k(DictT(t.elem, BOOL))}_keys({self.ex(node)})", lt
        if isinstance(t, DictT):
            return f"{self.k(t)}_keys({self.ex(node)})", lt
        r = self.tmp(k, "l")
        self.emit(f"{r} = {k}_new(0);")
        self.loop("range" if t is RANGE else "str", node, lambda c, et: self.emit(f"{k}_push({r}, {c});"))
        return r, lt

    def b_list(self, e):
        (a,) = e.args
        t = self.ty(a)
        code, lt = self.as_list(a)
        if isinstance(t, ListT):
            return f"{self.k(lt)}_copy({code})"
        return code

    def b_count(self, e):
        code, _ = self.as_list(e.args[0])
        return f"{self.k(e.ty)}_count({code})"

    def b_read(self, e):
        return f"sip_read({self.ex(e.args[0])}, {e.line})"

    def b_write(self, e):
        a, b = self.eval_args(e.args)
        return f"sip_write({a}, {b}, {e.line})"

    def b_input(self, e):
        return f"sip_input({self.ex(e.args[0]) if e.args else 'SIP_LIT(\"\")'})"

    def b_round(self, e):
        if len(e.args) == 2:
            x, n = self.eval_args(e.args)
            return f"sip_round_to((double)({x}), {n})"
        return f"sip_round((double)({self.ex(e.args[0])}))"

    def b_zip(self, e):
        (ac, at), (bc, bt) = self.as_list(e.args[0]), self.as_list(e.args[1])
        a, b = self.spill(ac, at), self.spill(bc, bt)
        lt = deep(e.ty)
        k = self.k(lt)
        r = self.tmp(k, "z")
        i = self.tmp("int64_t", "i")
        tt = self.c(lt.elem)
        self.emit(f"{r} = {k}_new({a}->n < {b}->n ? {a}->n : {b}->n);")
        self.emit(f"for ({i} = 0; {i} < {a}->n && {i} < {b}->n; {i}++) "
                  f"{k}_push({r}, (({tt}){{{a}->d[{i}], {b}->d[{i}]}}));")
        return r

    def b_enumerate(self, e):
        ac, at = self.as_list(e.args[0])
        a = self.spill(ac, at)
        lt = deep(e.ty)
        k = self.k(lt)
        r = self.tmp(k, "en")
        i = self.tmp("int64_t", "i")
        self.emit(f"{r} = {k}_new({a}->n);")
        self.emit(f"for ({i} = 0; {i} < {a}->n; {i}++) {k}_push({r}, (({self.c(lt.elem)}){{{i}, {a}->d[{i}]}}));")
        return r

    def b_math_sqrt(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "sqrt" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "sip_sqrt({0}, {L})".format(*a, L=e.line)
    def b_math_log2(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "log2" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "log2({0})".format(*a, L=e.line)
    def b_math_log10(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "log10" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "log10({0})".format(*a, L=e.line)
    def b_math_exp(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "exp" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "exp({0})".format(*a, L=e.line)
    def b_math_sin(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "sin" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "sin({0})".format(*a, L=e.line)
    def b_math_cos(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "cos" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "cos({0})".format(*a, L=e.line)
    def b_math_tan(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "tan" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "tan({0})".format(*a, L=e.line)
    def b_math_asin(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "asin" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "asin({0})".format(*a, L=e.line)
    def b_math_acos(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "acos" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "acos({0})".format(*a, L=e.line)
    def b_math_atan(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "atan" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "atan({0})".format(*a, L=e.line)
    def b_math_floor(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "floor" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "((int64_t)floor({0}))".format(*a, L=e.line)
    def b_math_ceil(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "ceil" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "((int64_t)ceil({0}))".format(*a, L=e.line)
    def b_math_trunc(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "trunc" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "((int64_t)trunc({0}))".format(*a, L=e.line)
    def b_math_atan2(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "atan2" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "atan2({0}, {1})".format(*a, L=e.line)
    def b_math_hypot(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "hypot" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "hypot({0}, {1})".format(*a, L=e.line)
    def b_math_pow(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "pow" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "pow({0}, {1})".format(*a, L=e.line)
    def b_math_isnan(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "isnan" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "isnan({0})".format(*a, L=e.line)
    def b_math_isinf(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "isinf" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "isinf({0})".format(*a, L=e.line)
    def b_math_gcd(self, e):
        a = [f"(double)({c})" if self.ty(x) is INT and "gcd" not in "gcd" else c
             for c, x in zip(self.eval_args(e.args), e.args)]
        return "sip_gcd({0}, {1})".format(*a, L=e.line)

    def b_math_log(self, e):
        a = [f"(double)({c})" for c in self.eval_args(e.args)]
        if len(a) == 1:
            return f"sip_log({a[0]}, {e.line})"
        return f"(sip_log({a[0]}, {e.line}) / sip_log({a[1]}, {e.line}))"

    def b_random_random(self, e):
        return "sip_rand_float()"

    def b_random_randint(self, e):
        a, b = self.eval_args(e.args)
        return f"sip_rand_int({a}, {b}, {e.line})"

    def b_random_uniform(self, e):
        a, b = [self.spill(f"(double)({c})", FLOAT) for c in self.eval_args(e.args)]
        return f"({a} + ({b} - {a}) * sip_rand_float())"

    def b_random_seed(self, e):
        return f"sip_rand_seed((uint64_t)({self.ex(e.args[0])}))"

    def b_random_choice(self, e):
        lt = self.ty(e.args[0])
        lst = self.spill(self.ex(e.args[0]), lt)
        return (f"{self.k(lt)}_get({lst}, {lst}->n ? sip_rand_int(0, {lst}->n - 1, {e.line}) : "
                f"(sip_raise(SIP_E_IndexError, SIP_LIT(\"cannot choose from an empty list\"), {e.line}), 0), {e.line})")

    def b_random_shuffle(self, e):
        lt = self.ty(e.args[0])
        lst = self.spill(self.ex(e.args[0]), lt)
        i, j = self.tmp("int64_t", "i"), self.tmp("int64_t", "j")
        tmp = self.tmp(self.c(lt.elem), "x")
        self.emit(f"for ({i} = {lst}->n - 1; {i} > 0; {i}--) {{ {j} = sip_rand_int(0, {i}, 0); "
                  f"{tmp} = {lst}->d[{i}]; {lst}->d[{i}] = {lst}->d[{j}]; {lst}->d[{j}] = {tmp}; }}")
        return "((void)0)"

    def b_time_time(self, e):
        return "sip_time_now()"

    def b_time_perf_counter(self, e):
        return "sip_perf_counter()"

    def b_time_sleep(self, e):
        return f"sip_sleep((double)({self.ex(e.args[0])}))"

    def json_fn(self, kind, t, e):
        try:
            return getattr(self.reg, kind)(t)
        except JsonTypeError as ex:
            self.err(f"{e.bname}(): {ex}", e)

    def b_json_parse(self, e):
        t = deep(e.ty)
        fn = self.json_fn("jparse", t, e)
        return f"{fn}({self.ex(e.args[0])}, {e.line})"

    def b_json_read(self, e):
        t = deep(e.ty)
        fn = self.json_fn("jparse", t, e)
        return f"{fn}(sip_read({self.ex(e.args[0])}, {e.line}), {e.line})"

    def json_indent(self, e, default):
        for k, v in e.kwargs:
            if k == "indent":
                return self.ex(v)
        return default

    def b_json_stringify(self, e):
        fn = self.json_fn("jdump", self.ty(e.args[0]), e)
        v = self.spill(self.ex(e.args[0]), self.ty(e.args[0]))
        return f"{fn}({v}, {self.json_indent(e, '-1')})"

    def b_json_write(self, e):
        path = self.spill(self.ex(e.args[0]), STR)
        fn = self.json_fn("jdump", self.ty(e.args[1]), e)
        v = self.spill(self.ex(e.args[1]), self.ty(e.args[1]))
        return f"sip_write({path}, {fn}({v}, {self.json_indent(e, '2')}), {e.line})"

    def http_call(self, e, method: str) -> str:
        from .checker import RESPONSE
        self.uses_http = True
        kw = dict(e.kwargs)
        url = self.spill(self.ex(e.args[0]), STR)
        h = self.tmp("struct curl_slist *", "h")
        self.emit(f"{h} = NULL;")
        hd = None
        if "headers" in kw:
            dt = DictT(STR, STR)
            hd = self.spill(self.ex(kw["headers"]), dt)
            i = self.tmp("int64_t", "i")
            self.emit(f"for ({i} = 0; {i} < {hd}->n; {i}++) {h} = sip_http_header({h}, {hd}->e[{i}].k, {hd}->e[{i}].v);")
        body = "NULL"
        if "json" in kw:
            v = kw["json"]
            fn = self.json_fn("jdump", self.ty(v), e)
            b = self.tmp("sip_str", "body")
            self.emit(f"{b} = {fn}({self.ex(v)}, -1);")
            has = f"{self.k(DictT(STR, STR))}_contains({hd}, SIP_LIT(\"Content-Type\"))" if hd else "false"
            self.emit(f"if (!{has}) {h} = sip_http_header({h}, SIP_LIT(\"Content-Type\"), "
                      f"SIP_LIT(\"application/json\"));")
            body = f"&{b}"
        elif "body" in kw:
            b = self.tmp("sip_str", "body")
            self.emit(f"{b} = {self.ex(kw['body'])};")
            body = f"&{b}"
        elif method == "POST":
            b = self.tmp("sip_str", "body")
            self.emit(f'{b} = SIP_LIT("");')
            body = f"&{b}"
        timeout = f"(double)({self.ex(kw['timeout'])})" if "timeout" in kw else "30.0"
        wrap = self.reg.http_wrap(RESPONSE)
        return f'{wrap}(sip_http_do("{method}", {url}, {body}, {h}, {timeout}, {e.line}))'

    def b_http_get(self, e):
        return self.http_call(e, "GET")

    def b_http_post(self, e):
        return self.http_call(e, "POST")

    def b_http_response_json(self, e):
        fn = self.json_fn("jparse", deep(e.ty), e)
        return f"{fn}(({self.ex(e.args[0])})->f_text, {e.line})"

    def csv_delim(self, e):
        for k, v in e.kwargs:
            if k == "delimiter":
                return self.ex(v)
        return 'SIP_LIT(",")'

    def b_csv_parse(self, e):
        fn = self.json_fn("csvread", deep(e.ty), e)
        text = self.spill(self.ex(e.args[0]), STR)
        return f"{fn}({text}, {self.csv_delim(e)}, {e.line})"

    def b_csv_read(self, e):
        fn = self.json_fn("csvread", deep(e.ty), e)
        text = self.spill(f"sip_read({self.ex(e.args[0])}, {e.line})", STR)
        return f"{fn}({text}, {self.csv_delim(e)}, {e.line})"

    def b_csv_write(self, e):
        path = self.spill(self.ex(e.args[0]), STR)
        fn = self.json_fn("csvdump", self.ty(e.args[1]), e)
        rows = self.spill(self.ex(e.args[1]), self.ty(e.args[1]))
        return f"sip_write({path}, {fn}({rows}, {self.csv_delim(e)}, {e.line}), {e.line})"

    def const_code(self, node, target: str) -> str:
        """Оператор C: target = значение литерала (поле по умолчанию) в отдельном блоке."""
        saved = self.lines, self.decls, self.depth
        self.lines, self.decls, self.depth = [], [], 0
        try:
            code = self.ex(node)
            body = self.decls + [t for _, t in self.lines] + [f"{target} = {code};"]
        finally:
            self.lines, self.decls, self.depth = saved
        return "{ " + " ".join(body) + " }"

    def b_exit(self, e):
        code = self.ex(e.args[0]) if e.args else "0"
        self.emit("fflush(stdout);")
        return f"exit((int)({code}))"

    # ---------- методы str ----------

    def recv_args(self, e):
        return self.eval_args([e.recv] + list(e.args))

    def ms_lower(self, e, t):
        return f"sip_str_map({self.recv_args(e)[0]}, 0)"

    def ms_upper(self, e, t):
        return f"sip_str_map({self.recv_args(e)[0]}, 1)"

    def ms_strip(self, e, t):
        return f"sip_str_strip({self.recv_args(e)[0]}, 1, 1)"

    def ms_lstrip(self, e, t):
        return f"sip_str_strip({self.recv_args(e)[0]}, 1, 0)"

    def ms_rstrip(self, e, t):
        return f"sip_str_strip({self.recv_args(e)[0]}, 0, 1)"

    def ms_isdigit(self, e, t):
        return f"sip_str_all({self.recv_args(e)[0]}, 0)"

    def ms_isalpha(self, e, t):
        return f"sip_str_all({self.recv_args(e)[0]}, 1)"

    def ms_isspace(self, e, t):
        return f"sip_str_all({self.recv_args(e)[0]}, 2)"

    def ms_startswith(self, e, t):
        return "sip_str_startswith({}, {})".format(*self.recv_args(e))

    def ms_endswith(self, e, t):
        return "sip_str_endswith({}, {})".format(*self.recv_args(e))

    def ms_find(self, e, t):
        return "sip_str_find({}, {})".format(*self.recv_args(e))

    def ms_count(self, e, t):
        return "sip_str_count({}, {})".format(*self.recv_args(e))

    def ms_replace(self, e, t):
        return "sip_str_replace({}, {}, {})".format(*self.recv_args(e))

    def ms_join(self, e, t):
        sep, lst = self.recv_args(e)
        return f"{self.k(self.ty(e.args[0]))}_join({lst}, {sep})"

    def split_into(self, s, sep):
        """Разбиение строки на список: по пробельным символам или по разделителю."""
        k = self.k(ListT(STR))
        r = self.tmp(k, "sp")
        i, j = self.tmp("int64_t", "i"), self.tmp("int64_t", "j")
        self.emit(f"{r} = {k}_new(0);")
        if sep is None:
            self.emit(f"for ({i} = 0; {i} < {s}.n;) {{")
            self.emit(f"    while ({i} < {s}.n && sip_isspace({s}.p[{i}])) {i}++;")
            self.emit(f"    if ({i} >= {s}.n) break;")
            self.emit(f"    {j} = {i};")
            self.emit(f"    while ({j} < {s}.n && !sip_isspace({s}.p[{j}])) {j}++;")
            self.emit(f"    {k}_push({r}, ((sip_str){{{s}.p + {i}, {j} - {i}}}));")
            self.emit(f"    {i} = {j};")
            self.emit("}")
        else:
            self.emit(f'if (SIP_UNLIKELY({sep}.n == 0)) sip_raise(SIP_E_ValueError, SIP_LIT("empty separator"), 0);')
            self.emit(f"for ({i} = 0, {j} = 0; {j} + {sep}.n <= {s}.n;) {{")
            self.emit(f"    if (memcmp({s}.p + {j}, {sep}.p, (size_t){sep}.n) == 0) {{")
            self.emit(f"        {k}_push({r}, ((sip_str){{{s}.p + {i}, {j} - {i}}}));")
            self.emit(f"        {j} += {sep}.n; {i} = {j};")
            self.emit(f"    }} else {j}++;")
            self.emit("}")
            self.emit(f"{k}_push({r}, ((sip_str){{{s}.p + {i}, {s}.n - {i}}}));")
        return r

    def ms_split(self, e, t):
        codes = self.recv_args(e)
        s = self.spill(codes[0], STR)
        sep = self.spill(codes[1], STR) if len(codes) > 1 else None
        return self.split_into(s, sep)

    def ms_splitlines(self, e, t):
        s = self.spill(self.recv_args(e)[0], STR)
        r = self.split_into(s, "SIP_LIT(\"\\n\")")
        k = self.k(ListT(STR))
        self.emit(f"if ({r}->n && {r}->d[{r}->n - 1].n == 0) {r}->n--;")
        _ = k
        return r

    # ---------- методы списков ----------

    def ml_append(self, e, t):
        lst, x = self.recv_args(e)
        return f"{self.k(t)}_push({lst}, {x})"

    def ml_pop(self, e, t):
        codes = self.recv_args(e)
        if len(codes) == 1:
            return f"{self.k(t)}_pop({codes[0]}, 0, false, {e.line})"
        return f"{self.k(t)}_pop({codes[0]}, {codes[1]}, true, {e.line})"

    def ml_insert(self, e, t):
        return "{}_insert({}, {}, {})".format(self.k(t), *self.recv_args(e))

    def ml_extend(self, e, t):
        return "{}_extend({}, {})".format(self.k(t), *self.recv_args(e))

    def ml_clear(self, e, t):
        return f"(({self.recv_args(e)[0]})->n = 0)"

    def ml_reverse(self, e, t):
        return f"{self.k(t)}_reverse({self.recv_args(e)[0]})"

    def ml_copy(self, e, t):
        return f"{self.k(t)}_copy({self.recv_args(e)[0]})"

    def ml_index(self, e, t):
        lst, x = self.recv_args(e)
        return f"{self.k(t)}_index({lst}, {x}, {e.line})"

    def ml_count(self, e, t):
        codes = self.recv_args(e)
        if len(codes) == 2:
            return f"{self.k(t)}_count({codes[0]}, {codes[1]})"
        return f"{self.k(e.ty)}_count({codes[0]})"

    def ml_sort(self, e, t):
        lst = self.spill(self.recv_args(e)[0], t)
        self.sort_list(e, lst, t)
        return "((void)0)"

    def ml_sort_by(self, e, t):
        k = self.k(t)
        r = self.tmp(k, "s")
        self.emit(f"{r} = {k}_copy({self.ex(e.recv)});")
        self.sort_list(e, r, t)
        return r

    def recv_fn(self, e, t):
        lst, f = self.eval_args([e.recv, e.args[0]])
        return self.spill(lst, t), self.spill(f, self.ty(e.args[0]))

    def ml_map(self, e, t):
        lst, f = self.recv_fn(e, t)
        rk = self.k(e.ty)
        r = self.tmp(rk, "m")
        i = self.tmp("int64_t", "i")
        self.emit(f"{r} = {rk}_new({lst}->n);")
        self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {rk}_push({r}, {self.call_fn(f, [f'{lst}->d[{i}]'])});")
        return r

    def ml_filter(self, e, t):
        lst, f = self.recv_fn(e, t)
        k = self.k(t)
        r = self.tmp(k, "f")
        i = self.tmp("int64_t", "i")
        ft = self.ty(e.args[0])
        self.emit(f"{r} = {k}_new(0);")
        self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {{")
        self.depth += 1
        test = self.truthy(self.call_fn(f, [f"{lst}->d[{i}]"]), ft.ret)
        self.emit(f"if ({test}) {k}_push({r}, {lst}->d[{i}]);")
        self.depth -= 1
        self.emit("}")
        return r

    def ml_group_by(self, e, t):
        lst, f = self.recv_fn(e, t)
        dt = deep(e.ty)
        dk, lk = self.k(dt), self.k(t)
        r = self.tmp(dk, "g")
        i = self.tmp("int64_t", "i")
        p = self.tmp(f"{lk} *", "p")
        self.emit(f"{r} = {dk}_new();")
        self.emit(f"for ({i} = 0; {i} < {lst}->n; {i}++) {{")
        self.emit(f"    {p} = {dk}_slot({r}, {self.call_fn(f, [f'{lst}->d[{i}]'])}, NULL);")
        self.emit(f"    if (!*{p}) *{p} = {lk}_new(0);")
        self.emit(f"    {lk}_push(*{p}, {lst}->d[{i}]);")
        self.emit("}")
        return r

    def ml_first(self, e, t):
        lst = self.spill(self.recv_args(e)[0], t)
        ot = deep(e.ty)
        return f"({lst}->n ? {self.convert(f'{lst}->d[0]', t.elem, ot, e.line)} : {nil_code(ot)})"

    def ml_join(self, e, t):
        codes = self.recv_args(e)
        sep = codes[1] if len(codes) > 1 else 'SIP_LIT("")'
        return f"{self.k(t)}_join({codes[0]}, {sep})"

    def ml_sum(self, e, t):
        return self.reduce("sum", e.recv, e.ty, e.line)

    def ml_avg(self, e, t):
        return self.reduce("avg", e.recv, e.ty, e.line)

    def ml_top(self, e, t):
        codes = self.recv_args(e)
        dk = self.k(DictT(t.elem, INT))
        n, has = (codes[1], "true") if len(codes) > 1 else ("0", "false")
        return f"{dk}_top({dk}_count({codes[0]}), {n}, {has})"

    # ---------- методы словарей ----------

    def md_pop(self, e, t):
        codes = self.recv_args(e)
        if len(codes) == 2:
            return f"{self.k(t)}_pop({codes[0]}, {codes[1]}, {e.line})"
        d, kv = self.spill(codes[0], t), self.spill(codes[1], t.key)
        r = self.tmp(self.c(t.val), "v")
        self.emit(f"{r} = {codes[2]};")
        self.emit(f"if ({self.k(t)}_contains({d}, {kv})) {r} = {self.k(t)}_pop({d}, {kv}, {e.line});")
        return r

    def md_update(self, e, t):
        a, b = self.recv_args(e)
        a, b = self.spill(a, t), self.spill(b, t)
        i = self.tmp("int64_t", "i")
        self.emit(f"for ({i} = 0; {i} < {b}->n; {i}++) {self.k(t)}_set({a}, {b}->e[{i}].k, {b}->e[{i}].v);")
        return "((void)0)"

    def md_clear(self, e, t):
        d = self.spill(self.recv_args(e)[0], t)
        return f"({d}->n = 0, {self.k(t)}_rehash({d}, {d}->icap ? {d}->icap : 8))"

    # ---------- методы множеств ----------

    def mz(self, t):
        return self.k(DictT(t.elem, BOOL))

    def mz_add(self, e, t):
        s, x = self.recv_args(e)
        return f"{self.mz(t)}_set({s}, {x}, true)"

    def mz_remove(self, e, t):
        s, x = self.recv_args(e)
        return f"{self.k(t)}_remove({s}, {x}, {e.line})"

    def mz_discard(self, e, t):
        s, x = self.recv_args(e)
        return f"(void){self.mz(t)}_discard({s}, {x})"

    def mz_clear(self, e, t):
        d = self.spill(self.recv_args(e)[0], t)
        return f"({d}->n = 0, {self.mz(t)}_rehash({d}, {d}->icap ? {d}->icap : 8))"

    def mz_copy(self, e, t):
        return f"{self.mz(t)}_copy({self.recv_args(e)[0]})"

    def mz_update(self, e, t):
        return "{}_update({}, {})".format(self.k(t), *self.recv_args(e))

    def mz_union(self, e, t):
        return "{}_union({}, {})".format(self.k(t), *self.recv_args(e))

    def mz_intersection(self, e, t):
        return "{}_inter({}, {})".format(self.k(t), *self.recv_args(e))

    def mz_difference(self, e, t):
        return "{}_diff({}, {})".format(self.k(t), *self.recv_args(e))

    def mz_issubset(self, e, t):
        return "{}_subset({}, {})".format(self.k(t), *self.recv_args(e))

    def b_set(self, e):
        st = deep(e.ty)
        dk = self.mz(st)
        self.k(st)
        r = self.tmp(dk, "set")
        self.emit(f"{r} = {dk}_new();")
        if e.args:
            a = e.args[0]
            t = self.ty(a)
            kind = "range" if t is RANGE else "str" if t is STR else "set" if isinstance(t, SetT) else \
                "dict_keys" if isinstance(t, DictT) else "list"
            self.loop(kind, a, lambda c, et: self.emit(f"{dk}_set({r}, {c}, true);"))
        return r

    def md_get(self, e, t):
        codes = self.recv_args(e)
        if len(codes) == 3:
            return f"{self.k(t)}_get_or({codes[0]}, {codes[1]}, {codes[2]})"
        d = self.spill(codes[0], t)
        kv = self.spill(codes[1], t.key)
        j = self.tmp("int64_t", "j")
        ot = deep(e.ty)
        self.emit(f"{j} = {self.k(t)}_find({d}, {kv}, {hash_fn(t.key)}({kv}));")
        return f"({j} >= 0 ? {self.convert(f'{d}->e[{j}].v', t.val, ot, e.line)} : {nil_code(ot)})"

    def md_keys(self, e, t):
        return f"{self.k(t)}_keys({self.recv_args(e)[0]})"

    def md_values(self, e, t):
        return f"{self.k(t)}_values({self.recv_args(e)[0]})"

    def md_items(self, e, t):
        return f"{self.k(t)}_items({self.recv_args(e)[0]})"

    def md_copy(self, e, t):
        return f"{self.k(t)}_copy({self.recv_args(e)[0]})"

    def md_top(self, e, t):
        codes = self.recv_args(e)
        n, has = (codes[1], "true") if len(codes) > 1 else ("0", "false")
        return f"{self.k(t)}_top({codes[0]}, {n}, {has})"


def generate_c(prog: Program, file: str, srcmap) -> str:
    return CGen(prog, file, srcmap).generate()


__all__ = ["generate_c", "ERROR_KINDS", "RecordT", "key"]
