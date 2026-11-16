# Собственный бэкенд: проверенная программа -> машинный код arm64 -> Mach-O (без C, clang и ld).
#
# Первый срез: int и bool, функции до 8 аргументов, рекурсия, if/while/for по range, break/continue,
# return, print. Арифметика проверяется так же, как в C-бэкенде: переполнение — OverflowError, деление
# и остаток — с округлением вниз и ошибкой при нуле; текст ошибки (файл:строка, вид, строка исходника)
# совпадает с C. Остальное — ошибка «native backend: ... not supported yet».
#
# Регистры: x19..x28 — переменные (сохраняются вызываемой функцией), x9..x15 — промежуточные значения
# выражения (перед вызовом живые сохраняются в кадре), x16/x17 — рабочие, x0..x7 — аргументы и результат.
# Кадр: [sp + 0] сохранённые x19..x28, затем переменные, которым не хватило регистров, затем 7 ячеек для
# промежуточных значений.

import arm64
import macho
import cgen
import checker
import modules
from arm64 import Asm, SP, ZR, FP, EQ, NE, LT, LE, GT, GE, VS
from parser import N
from checker import Ty, Fn, Var, INT, BOOL, STR, UNIT
from creg import deep
from modules import SipErr, isn, nm

T0 = 9  # первый регистр промежуточных значений
TN = 15  # последний
VREG = [19, 20, 21, 22, 23, 24, 25, 26, 27, 28]
OUTBUF = 65536
NOANN = checker.Ann()

fn inv(c int) int = c ^ 1

fn last_line(fi Fn) int
    body = fi.node.kids[3].kids
    if body then body[len(body) - 1].line else fi.node.line

fn bytes_of(s str) [int] = [ord(s[i]) for i in 0..len(s) - 1]

fn cond_of(op str) int
    if op == "==" then return EQ
    if op == "!=" then return NE
    if op == "<" then return LT
    if op == "<=" then return LE
    if op == ">" then return GT
    GE

# где живёт переменная: регистр (reg >= 0) или ячейка кадра [sp + off]
type Home(reg int, off int)

type NGen(c checker.Checker, ld modules.Loader, file str, a Asm, homes {str: Home} = {},
          fi Fn? = nil, brk [str] = [], cont [str] = [], epi str = "", tslot int = 0, nhid int = 0,
          stubs {str: str} = {}, stub_list [(str, str, int)] = [], queue [Fn] = [], seen {str: bool} = {})

    fn no(what str, node N?)
        line = if node == nil then 0 else node.line
        fail SipErr("native backend: {what} not supported yet", .file, line, 0)

    fn an(n N) checker.Ann = if n.an == 0 then NOANN else .c.ans[n.an]

    fn ty(n N) Ty
        a = .an(n)
        if a.cty != nil
            ct: Ty = a.cty
            return deep(ct)
        deep(.c.tys[n.ty])

    fn scalar(t Ty) bool = t.id == INT.id or t.id == BOOL.id

    fn need(n N)
        t = .ty(n)
        if not .scalar(t) then .no("type {checker.show(t)}", n)

    fn cur() Fn
        f: Fn = .fi
        f

    # ---------- ошибки времени выполнения ----------

    # переход на заглушку, которая печатает ошибку как C-рантайм и завершает программу
    fn stub(kind str, msg str, line int) str
        key = "{kind}|{msg}|{line}"
        if key in .stubs then return .stubs[key]
        f, local = .ld.locate(line)
        text = "{f}:{local}: {kind}"
        if msg != "" then text = text + ": " + msg
        text = text + "\n"
        for i, fp in enumerate(.ld.files)
            if fp[1] == f
                src = .ld.srcs[i]
                if local > 0 and local <= len(src)
                    s = src[local - 1]
                    j = 0
                    while j < len(s) and s[j] == " "
                        j += 1
                    text = text + "    " + s[j:] + "\n"
        bs = bytes_of(text)
        label = .a.new_label("err")
        .stubs[key] = label
        .stub_list.append((label, .a.cstr(bs), len(bs)))
        label

    fn overflow(line int) str = .stub("OverflowError", "integer overflow", line)

    fn emit_stubs()
        for label, cl, n in .stub_list
            .a.here(label)
            .a.adr(0, cl)
            .a.mov_imm(1, n)
            .a.b("t:rt_die")
        .stub_list = []

    # ---------- переменные ----------

    fn var_of(n N) Var
        a = .an(n)
        if a.var == nil then .no("this name", n)
        v: Var = a.var
        v

    fn glabel(v Var) str = .a.bslot("g_" + v.cname, 8)

    # значение переменной в регистре: её собственный регистр или r
    fn load_var(v Var, r int) int
        if v.kind == "global"
            .a.ldr_label(r, .glabel(v))
            return r
        h = .homes[v.cname]
        if h.reg >= 0 then return h.reg
        .a.ldr(r, SP, h.off)
        r

    fn store_var(v Var, src int)
        if v.kind == "global"
            .a.str_label(src, .glabel(v), 16)
            return
        h = .homes[v.cname]
        if h.reg >= 0
            .a.mov(h.reg, src)
        else
            .a.str_(src, SP, h.off)

    # ---------- выражения ----------

    fn chk(r int, node N)
        if r > TN then .no("expression this deep", node)

    # значение e в регистре: если e — переменная в регистре, то её регистр, иначе r
    fn opnd(e N, r int) int
        if e.kind == "Name"
            a = .an(e)
            if a.var != nil
                v: Var = a.var
                .need(e)
                return .load_var(v, r)
        .gen(e, r)
        r

    # небольшая неотрицательная константа (для команд с непосредственным операндом)
    fn small(e N) int
        if e.kind == "Num" and .ty(e).id == INT.id
            text = nm(e).replace("_", "")
            if len(text) <= 4
                v = int(text)
                if v <= 4095 then return v
        -1

    fn gen(e N, r int)
        .chk(r, e)
        k = e.kind
        if k == "Num"
            if .ty(e).id != INT.id then .no("float", e)
            text = nm(e).replace("_", "")
            if len(text) > 19 or (len(text) == 19 and text >= "9223372036854775808")
                fail SipErr("integer literal is too large for int (64-bit)", .file, e.line, 0)
            .a.mov_imm(r, int(text))
        elif k == "Const"
            v = nm(e)
            if v == "True"
                .a.movz(r, 1, 0)
            elif v == "False"
                .a.movz(r, 0, 0)
            else
                .no("None", e)
        elif k == "Name"
            if .an(e).var == nil then .no("this name", e)
            got = .opnd(e, r)
            .a.mov(r, got)
        elif k == "BinOp"
            .binop(e, r)
        elif k == "Compare" or (k == "Unary" and e.kids[0].s == "not")
            .need(e)
            if k == "Compare" and len(e.kids[1].kids) == 1
                op = e.kids[1].kids[0]
                .compare(e.kids[0], op.kids[0].s, op.kids[1], r, e)
                .a.cset(r, cond_of(op.kids[0].s))
            else
                .bool_value(e, r)
        elif k == "Unary"
            .need(e)
            uop = e.kids[0].s
            x = .opnd(e.kids[1], r)
            if uop == "-"
                .a.negs(r, x)
                .a.bcond(VS, .overflow(e.line))
            elif uop == "~"
                .a.mvn(r, x)
            elif uop == "+"
                .a.mov(r, x)
            else
                .no("unary {uop}", e)
        elif k == "IfExpr"
            .need(e)
            lelse = .a.new_label("else")
            lend = .a.new_label("end")
            .cjump(e.kids[0], lelse, false, r)
            .gen(e.kids[1], r)
            .a.b(lend)
            .a.here(lelse)
            .gen(e.kids[2], r)
            .a.here(lend)
        elif k == "Call"
            .call(e, r)
        else
            .no(k, e)
        pass

    # bool как значение через переходы (and, or, not, цепочки сравнений)
    fn bool_value(e N, r int)
        lf = .a.new_label("f")
        lend = .a.new_label("end")
        .cjump(e, lf, false, r)
        .a.movz(r, 1, 0)
        .a.b(lend)
        .a.here(lf)
        .a.movz(r, 0, 0)
        .a.here(lend)

    fn binop(e N, r int)
        op = e.kids[0].s
        if op == "and" or op == "or"
            if .ty(e).id != BOOL.id then .no("'{op}' on non-bool values", e)
            .bool_value(e, r)
            return
        left = e.kids[1]
        right = e.kids[2]
        .need(left)
        .need(right)
        .need(e)
        .arith(op, left, right, r, e.line, e)

    # r = left op right
    fn arith(op str, left N, right N, r int, line int, e N)
        imm = .small(right)
        x = .opnd(left, r)
        if imm >= 0 and (op == "+" or op == "-")
            if op == "+" then .a.adds_imm(r, x, imm) else .a.subs_imm(r, x, imm)
            .a.bcond(VS, .overflow(line))
            return
        y = .opnd(right, r + 1)
        .op3(op, r, x, y, line, e)

    # r = x op y (регистры)
    fn op3(op str, r int, x int, y int, line int, e N)
        if op == "+"
            .a.adds(r, x, y)
            .a.bcond(VS, .overflow(line))
        elif op == "-"
            .a.subs(r, x, y)
            .a.bcond(VS, .overflow(line))
        elif op == "*"
            .a.smulh(16, x, y)
            .a.mul(r, x, y)
            .a.cmp_asr63(16, r)
            .a.bcond(NE, .overflow(line))
        elif op == "/" or op == "//"
            .floordiv(r, x, y, line)
        elif op == "%"
            .modulo(r, x, y, line)
        elif op == "&"
            .a.and_(r, x, y)
        elif op == "|"
            .a.orr(r, x, y)
        elif op == "^"
            .a.eor(r, x, y)
        else
            .no("operator {op}", e)
        pass

    # деление с округлением вниз, как sip_floordiv
    fn floordiv(r int, x int, y int, line int)
        .a.cbz(y, .stub("ZeroDivisionError", "division by zero", line))
        lnorm = .a.new_label("div")
        lend = .a.new_label("end")
        .a.cmn_imm(y, 1)
        .a.bcond(NE, lnorm)
        .a.negs(r, x)
        .a.bcond(VS, .overflow(line))
        .a.b(lend)
        .a.here(lnorm)
        .a.sdiv(16, x, y)
        .a.msub(17, 16, y, x)  # остаток
        .a.cbz(17, lend + "q")
        .a.eor(17, 17, y)
        .a.cmp_imm(17, 0)
        .a.bcond(GE, lend + "q")
        .a.sub_imm(16, 16, 1)
        .a.here(lend + "q")
        .a.mov(r, 16)
        .a.here(lend)

    # остаток со знаком делителя, как sip_mod
    fn modulo(r int, x int, y int, line int)
        .a.cbz(y, .stub("ZeroDivisionError", "modulo by zero", line))
        lnorm = .a.new_label("mod")
        lend = .a.new_label("end")
        .a.cmn_imm(y, 1)
        .a.bcond(NE, lnorm)
        .a.movz(r, 0, 0)
        .a.b(lend)
        .a.here(lnorm)
        .a.sdiv(16, x, y)
        .a.msub(17, 16, y, x)
        .a.cbz(17, lend + "r")
        .a.eor(16, 17, y)
        .a.cmp_imm(16, 0)
        .a.bcond(GE, lend + "r")
        .a.add(17, 17, y)
        .a.here(lend + "r")
        .a.mov(r, 17)
        .a.here(lend)

    fn has_call(n N) bool
        if n.kind == "Call" then return true
        for k in n.kids
            if .has_call(k) then return true
        false

    # флаги сравнения left и right (int или bool); r — свободный регистр
    fn compare(left N, op str, right N, r int, e N)
        lt = .ty(left)
        rt = .ty(right)
        if not .scalar(lt) or not .scalar(rt) or op == "in" or op == "not in" or op == "is" or op == "is not"
            .no("comparison '{op}' of {checker.show(lt)} and {checker.show(rt)}", e)
        x = .opnd(left, r)
        imm = .small(right)
        if imm >= 0
            .a.cmp_imm(x, imm)
            return
        y = .opnd(right, r + 1)
        .a.cmp(x, y)

    # переход на label, если e истинно (when) или ложно (not when)
    fn cjump(e N, label str, when bool, r int)
        k = e.kind
        if k == "Compare"
            ops = e.kids[1].kids
            if len(ops) == 1
                op = ops[0].kids[0].s
                .compare(e.kids[0], op, ops[0].kids[1], r, e)
                c = cond_of(op)
                .a.bcond(if when then c else inv(c), label)
                return
            # a < b < c: каждое звено по очереди, средние операнды вычисляются один раз
            skip = .a.new_label("skip")
            nodes = [e.kids[0]] + [o.kids[1] for o in ops]
            for n in nodes
                .need(n)
            .chk(r + 1, e)
            .gen(nodes[0], r)
            for i, o in enumerate(ops)
                op = o.kids[0].s
                .gen(nodes[i + 1], r + 1)
                .a.cmp(r, r + 1)
                c = cond_of(op)
                last = i == len(ops) - 1
                if when and last
                    .a.bcond(c, label)
                elif when
                    .a.bcond(inv(c), skip)
                else
                    .a.bcond(inv(c), label)
                if not last then .a.mov(r, r + 1)
            .a.here(skip)
            return
        if k == "Unary" and e.kids[0].s == "not"
            .cjump(e.kids[1], label, not when, r)
            return
        if k == "BinOp" and (e.kids[0].s == "and" or e.kids[0].s == "or")
            is_and = e.kids[0].s == "and"
            if is_and != when  # and и «ложно» или or и «истинно»: любой операнд решает
                .cjump(e.kids[1], label, when, r)
                .cjump(e.kids[2], label, when, r)
            else
                skip = .a.new_label("skip")
                .cjump(e.kids[1], skip, not when, r)
                .cjump(e.kids[2], label, when, r)
                .a.here(skip)
            return
        if k == "Const" and (nm(e) == "True" or nm(e) == "False")
            if (nm(e) == "True") == when then .a.b(label)
            return
        .need(e)
        x = .opnd(e, r)
        if when then .a.cbnz(x, label) else .a.cbz(x, label)

    # ---------- вызовы ----------

    fn call(e N, r int)
        a = .an(e)
        if a.ckind == "builtin"
            if a.name == "print"
                if r != T0 then .no("print inside an expression", e)
                .print(e)
                return
            if a.name == "abs" and len(e.kids[1].kids) == 1
                .need(e.kids[1].kids[0])
                .gen(e.kids[1].kids[0], r)
                .a.cmp_imm(r, 0)
                lpos = .a.new_label("pos")
                .a.bcond(GE, lpos)
                .a.negs(r, r)
                .a.bcond(VS, .overflow(e.line))
                .a.here(lpos)
                return
            .no("builtin {a.name}()", e)
        if a.ckind != "fn" then .no("this kind of call", e)
        fi: Fn = a.f
        if fi.std then .no("standard library function {fi.name}()", e)
        if fi.parent != nil or fi.owner != nil or fi.allparams or fi.is_async or fi.cache
            .no("calling {fi.name}()", e)
        args = a.bound
        if len(args) > 8 then .no("more than 8 arguments", e)
        rt = deep(fi.ret)
        if rt.id != UNIT.id and not .scalar(rt) then .no("return type {checker.show(rt)}", e)
        calls = false
        for arg in args
            .need(arg)
            if .has_call(arg) then calls = true
        if calls  # аргументы — в промежуточные регистры: вызов внутри аргумента испортит x0..x7
            .chk(r + len(args) - 1, e)
            for i, arg in enumerate(args)
                .gen(arg, r + i)
        else  # сразу в x0..x7
            for i, arg in enumerate(args)
                got = .opnd(arg, r)
                .a.mov(i, got)
        for i in T0..r - 1  # живые промежуточные значения
            .a.str_(i, SP, .tslot + 8 * (i - T0))
        if calls
            for i in 0..len(args) - 1
                .a.mov(i, r + i)
        .a.bl_("t:" + fi.cname)
        for i in T0..r - 1
            .a.ldr(i, SP, .tslot + 8 * (i - T0))
        if rt.id != UNIT.id then .a.mov(r, 0)
        .want(fi)

    fn want(fi Fn)
        if fi.cname not in .seen
            .seen[fi.cname] = true
            .queue.append(fi)

    fn put_lit(s str)
        if s == "" then return
        bs = bytes_of(s)
        .a.adr(0, .a.cstr(bs))
        .a.mov_imm(1, len(bs))
        .a.bl_("t:rt_put")

    fn put_val(x N)
        t = .ty(x)
        if x.kind == "Str"
            for p in x.kids[0].kids
                if p.kind != "Interp"
                    .put_lit(cgen.unescape(p.s))
                    continue
                if not isn(p.kids[1]) then .no("format spec", p)
                .put_val(p.kids[0])
            return
        if t.id == INT.id
            .gen(x, T0)
            .a.mov(0, T0)
            .a.bl_("t:rt_put_int")
        elif t.id == BOOL.id
            .gen(x, T0)
            .a.mov(0, T0)
            .a.bl_("t:rt_put_bool")
        else
            .no("printing {checker.show(t)}", x)
        pass

    fn print(e N)
        if e.kids[2].kids then .no("print with keyword arguments", e)
        for i, x in enumerate(e.kids[1].kids)
            if i > 0 then .put_lit(" ")
            .put_val(x)
        .put_lit("\n")

    # ---------- инструкции ----------

    fn block(stmts [N])
        for s in stmts
            .stmt(s)

    fn stmt(s N)
        k = s.kind
        if k == "ExprStmt"
            e = s.kids[0]
            if e.kind != "Call" then .no("expression statement", e)
            .call(e, T0)
        elif k == "Assign"
            targets = s.kids[0].kids
            if len(targets) == 1 and targets[0].kind == "TupleLit" and s.kids[1].kind == "TupleLit"
                .swap(targets[0].kids[0].kids, s.kids[1].kids[0].kids, s)
                return
            if len(targets) != 1 or targets[0].kind != "Name" then .no("this assignment", s)
            .need(s.kids[1])
            .need(targets[0])
            .gen(s.kids[1], T0)
            .store_var(.var_of(targets[0]), T0)
        elif k == "AnnAssign"
            if isn(s.kids[2]) then return
            if s.kids[0].kind != "Name" then .no("this assignment", s)
            .need(s.kids[2])
            .gen(s.kids[2], T0)
            .store_var(.var_of(s.kids[0]), T0)
        elif k == "AugAssign"
            a = .an(s)
            if a.n3 != nil
                aa: N = a.n3
                .stmt(aa)
                return
            b: N = a.n2
            t = s.kids[0]
            if t.kind != "Name" then .no("this assignment", s)
            .need(t)
            .need(s.kids[2])
            .arith(b.kids[0].s, t, s.kids[2], T0, s.line, s)
            .store_var(.var_of(t), T0)
        elif k == "If"
            lend = .a.new_label("fi")
            for br in s.kids[0].kids
                lnext = .a.new_label("elif")
                .cjump(br.kids[0], lnext, false, T0)
                .block(br.kids[1].kids)
                .a.b(lend)
                .a.here(lnext)
            if not isn(s.kids[1])
                .block(s.kids[1].kids)
            .a.here(lend)
        elif k == "While"
            lbody = .a.new_label("wb")
            lcond = .a.new_label("wc")
            lend = .a.new_label("we")
            .a.b(lcond)
            .a.here(lbody)
            .brk.append(lend)
            .cont.append(lcond)
            .block(s.kids[1].kids)
            .brk.pop()
            .cont.pop()
            .a.here(lcond)
            .cjump(s.kids[0], lbody, true, T0)
            .a.here(lend)
        elif k == "For"
            .for_range(s)
        elif k == "Return"
            v = s.kids[0]
            if not isn(v)
                if deep(.c.tys[v.ty]).id != UNIT.id
                    .need(v)
                    .gen(v, T0)
                    .a.mov(0, T0)
                elif v.kind == "Call"
                    .call(v, T0)
            .a.b(.epi)
        elif k == "Break"
            .a.b(.brk[len(.brk) - 1])
        elif k == "Continue"
            .a.b(.cont[len(.cont) - 1])
        elif k == "Pass"
            pass
        elif k == "FnDef"
            fi: Fn? = .an(s).f
            if fi != nil and not .cur().is_top then .no("nested function", s)
            pass
        else
            .no(k, s)
        pass

    # a, b = x, y: сначала все значения, потом присваивания
    fn swap(targets [N], values [N], s N)
        if len(targets) != len(values) then .no("this assignment", s)
        .chk(T0 + len(values) - 1, s)
        for i, v in enumerate(values)
            .need(v)
            if targets[i].kind != "Name" then .no("this assignment", s)
            .gen(v, T0 + i)
        for i, t in enumerate(targets)
            .store_var(.var_of(t), T0 + i)

    fn hidden() (Var, Var)
        .nhid += 1
        (Var("#k", INT, "local", "#k{.nhid}"), Var("#hi", INT, "local", "#hi{.nhid}"))

    # for x in lo..hi: hi вычисляется один раз, x получает копию счётчика
    fn for_range(s N)
        it = s.kids[1]
        if .an(s).kind != "range" or it.kind != "Range" then .no("for over this", it)
        if s.kids[0].kind != "Name" then .no("this loop target", s.kids[0])
        .need(it.kids[0])
        .need(it.kids[1])
        kv, hv = .hidden()
        target = .var_of(s.kids[0])
        .gen(it.kids[0], T0)
        .store_var(kv, T0)
        .gen(it.kids[1], T0)
        .store_var(hv, T0)
        lend = .a.new_label("fe")
        lnext = .a.new_label("fn")
        ltop = .a.new_label("ft")
        k = .load_var(kv, T0)
        h = .load_var(hv, T0 + 1)
        .a.cmp(k, h)
        .a.bcond(GT, lend)
        .a.here(ltop)
        k2 = .load_var(kv, T0)
        .store_var(target, k2)
        .brk.append(lend)
        .cont.append(lnext)
        .block(s.kids[2].kids)
        .brk.pop()
        .cont.pop()
        .a.here(lnext)
        k3 = .load_var(kv, T0)
        h3 = .load_var(hv, T0 + 1)
        .a.cmp(k3, h3)
        .a.bcond(GE, lend)
        .a.add_imm(T0, k3, 1)
        .store_var(kv, T0)
        .a.b(ltop)
        .a.here(lend)

    # ---------- функции ----------

    fn count_for_n(n N) int
        c = if n.kind == "For" then 1 else 0
        for k in n.kids
            c += .count_for_n(k)
        c

    fn gen_fn(fi Fn, label str, top bool)
        .fi = fi
        .homes = {}
        .nhid = 0
        names: [Var] = []
        for p in fi.params
            if not .scalar(deep(p.ty)) then .no("parameter type {checker.show(deep(p.ty))}", fi.node)
            names.append(fi.locals[p.name])
        for v in fi.locals.values()
            if v.kind == "local"
                if not .scalar(deep(v.ty)) then .no("variable type {checker.show(deep(v.ty))}", fi.node)
                names.append(v)
        for v in fi.extra
            names.append(v)
        nfor = 0
        for s in fi.body
            nfor += .count_for_n(s)
        for i in 1..nfor
            names.append(Var("#k", INT, "local", "#k{i}"))
            names.append(Var("#hi", INT, "local", "#hi{i}"))
        nreg = min(len(names), len(VREG))
        nsave = nreg
        slots = len(names) - nreg
        off = 8 * nsave
        for i, v in enumerate(names)
            if i < nreg
                .homes[v.cname] = Home(VREG[i], 0)
            else
                .homes[v.cname] = Home(-1, off)
                off += 8
        .tslot = off
        frame = (off + 8 * (TN - T0 + 1) + 15) // 16 * 16
        if frame > 4095 then .no("this many variables in {fi.name}()", fi.node)
        .epi = .a.new_label("ret")
        .a.here(label)
        .a.push_frame()
        .a.sub_imm(SP, SP, frame)
        for i in 0..nsave - 1
            .a.str_(VREG[i], SP, 8 * i)
        for i, p in enumerate(fi.params)
            .store_var(fi.locals[p.name], i)
        .block(fi.body)
        ret = deep(fi.ret)
        if ret.id != UNIT.id and not top
            .a.b(.stub("Error", "{fi.name}() ended without returning a value", last_line(fi)))
        .a.here(.epi)
        for i in 0..nsave - 1
            .a.ldr(VREG[i], SP, 8 * i)
        .a.add_imm(SP, FP, 0)
        .a.pop_frame()
        .a.ret()
        .emit_stubs()

    # ---------- рантайм на ассемблере ----------

    fn runtime()
        a = .a
        buf = a.bslot("outbuf", OUTBUF)
        pos = a.bslot("outpos", 8)
        a.dslot("write")
        a.dslot("exit")
        # rt_flush: write(1, outbuf, outpos); outpos = 0
        a.here("t:rt_flush")
        a.push_frame()
        a.addr(1, buf)
        a.ldr_label(2, pos)
        a.movz(0, 1, 0)
        a.ldr_label(16, "d:write")
        a.blr(16)
        a.str_label(ZR, pos, 16)
        a.pop_frame()
        a.ret()
        # rt_put(x0 = адрес, x1 = длина)
        a.here("t:rt_put")
        a.push_frame()
        a.addr(4, buf)
        a.ldr_label(3, pos)
        a.mov_imm(5, OUTBUF)
        a.here("t:rt_put_loop")
        a.cbz(1, "t:rt_put_done")
        a.cmp(3, 5)
        a.bcond(arm64.LO, "t:rt_put_room")
        a.str_label(3, pos, 16)
        a.sub_imm(SP, SP, 16)
        a.str_(0, SP, 0)
        a.str_(1, SP, 8)
        a.bl_("t:rt_flush")
        a.ldr(0, SP, 0)
        a.ldr(1, SP, 8)
        a.add_imm(SP, SP, 16)
        a.addr(4, buf)
        a.movz(3, 0, 0)
        a.mov_imm(5, OUTBUF)
        a.here("t:rt_put_room")
        a.ldrb(6, 0, 0)
        a.strb_r(6, 4, 3)
        a.add_imm(0, 0, 1)
        a.add_imm(3, 3, 1)
        a.sub_imm(1, 1, 1)
        a.b("t:rt_put_loop")
        a.here("t:rt_put_done")
        a.str_label(3, pos, 16)
        a.pop_frame()
        a.ret()
        # rt_put_int(x0): десятичная запись в 32 байта кадра
        a.here("t:rt_put_int")
        a.push_frame()
        a.sub_imm(SP, SP, 32)
        a.add_imm(4, SP, 32)  # конец буфера
        a.mov(5, 4)
        a.mov(2, 0)
        a.cmp_imm(0, 0)
        a.bcond(GE, "t:rt_pi_loop")
        a.negs(2, 0)  # для INT64_MIN даёт то же число: делим без знака
        a.here("t:rt_pi_loop")
        a.movz(6, 10, 0)
        a.udiv(7, 2, 6)
        a.msub(3, 7, 6, 2)
        a.add_imm(3, 3, 48)
        a.sub_imm(5, 5, 1)
        a.strb(3, 5, 0)
        a.mov(2, 7)
        a.cbnz(2, "t:rt_pi_loop")
        a.cmp_imm(0, 0)
        a.bcond(GE, "t:rt_pi_out")
        a.movz(3, 45, 0)
        a.sub_imm(5, 5, 1)
        a.strb(3, 5, 0)
        a.here("t:rt_pi_out")
        a.mov(0, 5)
        a.sub(1, 4, 5)
        a.bl_("t:rt_put")
        a.add_imm(SP, FP, 0)
        a.pop_frame()
        a.ret()
        # rt_put_bool(x0)
        a.here("t:rt_put_bool")
        a.cbz(0, "t:rt_pb_f")
        a.adr(0, a.cstr(bytes_of("True")))
        a.movz(1, 4, 0)
        a.b("t:rt_put")
        a.here("t:rt_pb_f")
        a.adr(0, a.cstr(bytes_of("False")))
        a.movz(1, 5, 0)
        a.b("t:rt_put")
        # rt_die(x0 = текст, x1 = длина): вывод, текст в stderr, exit(1)
        a.here("t:rt_die")
        a.mov(19, 0)
        a.mov(20, 1)
        a.bl_("t:rt_flush")
        a.movz(0, 2, 0)
        a.mov(1, 19)
        a.mov(2, 20)
        a.ldr_label(16, "d:write")
        a.blr(16)
        a.movz(0, 1, 0)
        a.ldr_label(16, "d:exit")
        a.blr(16)

    fn program(out str)
        root = .ld.files[0][1]
        if .c.mainfn != nil
            m: Fn = .c.mainfn
            if m.params then .no("fn main with arguments", m.node)
        if .c.has_tests then .no("test blocks", nil)
        for v in .c.globals.values()
            if v.mod == root and not .scalar(deep(v.ty)) then .no("global of type {checker.show(deep(v.ty))}", nil)
        # точка входа: верхний уровень корневого модуля, main, сброс вывода, exit(0)
        .a.here("t:_start")
        .a.push_frame()
        tops = [t for t in .c.tops if t.mod == root]
        for t in tops
            .a.bl_("t:" + t.cname)
        if .c.mainfn != nil
            m: Fn = .c.mainfn
            .a.bl_("t:" + m.cname)
            .want(m)
        .a.bl_("t:rt_flush")
        .a.movz(0, 0, 0)
        .a.ldr_label(16, "d:exit")
        .a.blr(16)
        .runtime()
        for t in tops
            .gen_fn(t, "t:" + t.cname, true)
        while .queue
            f = .queue.pop(0)
            .gen_fn(f, "t:" + f.cname, false)
        ident = cgen.stem(out)
        macho.emit_file(.a, "t:_start", ["write", "exit"], out, ident)

fn build(c checker.Checker, ld modules.Loader, file str, out str)
    NGen(c, ld, file, Asm()).program(out)
