"""Парсер Sip: рекурсивный спуск по токенам из lexer.py.

Парсер терпим к привычкам из Python: двоеточие в конце заголовка блока,
`x: int` в параметрах, `-> int` перед типом результата, `True`/`None`, явный `self`.
Если модель напишет «как в Python», код всё равно соберётся,
и не придётся тратить токены на повторную попытку.
"""

from .errors import SipError
from .lexer import KEYWORDS, Token, tokenize
from .nodes import *  # noqa: F403

AUG_OPS = ("+=", "-=", "*=", "/=", "%=")
CMP_OPS = ("==", "!=", "<", ">", "<=", ">=")
# Токены, после которых `print` считается вызовом-командой: `print "hi", x`
# `print [1, 2]` и `print .name` — тоже команды: индексировать или читать поле у print бессмысленно.
PRINT_NOT_COMMAND = {"(", "=", ",", *AUG_OPS}

HINTS = {
    "def": "use 'fn' to define a function",
    "class": "use 'type Name(field type, ...)' to define a record",
    "lambda": "use 'fn(x) = expr' for an anonymous function",
    "except": "use 'catch Kind e' instead of 'except'",
    "raise": "use 'fail value' to raise an error",
}


def describe(tok: Token) -> str:
    return {
        "NEWLINE": "end of line",
        "INDENT": "indented block",
        "DEDENT": "end of block",
        "EOF": "end of file",
        "NUMBER": f"number {tok.value}",
        "STRING": "string",
    }.get(tok.kind, f"name '{tok.value}'" if tok.kind == "NAME" else f"'{tok.kind}'")


def is_word(tok: Token) -> bool:
    """Имя или ключевое слово (после точки и в именованных аргументах годятся оба)."""
    return tok.kind == "NAME" or tok.kind in KEYWORDS


class Parser:
    def __init__(self, tokens: list[Token], file: str = "<input>"):
        self.toks = tokens
        self.i = 0
        self.file = file

    # ---------- вспомогательное ----------

    def peek(self, k: int = 0) -> Token:
        return self.toks[min(self.i + k, len(self.toks) - 1)]

    def at(self, *kinds: str) -> bool:
        return self.peek().kind in kinds

    def advance(self) -> Token:
        tok = self.peek()
        if tok.kind != "EOF":
            self.i += 1
        return tok

    def accept(self, *kinds: str) -> Token | None:
        return self.advance() if self.at(*kinds) else None

    def error(self, msg: str, tok: Token | None = None):
        tok = tok or self.peek()
        raise SipError(msg, tok.line, tok.col, self.file)

    def expect(self, kind: str, what: str | None = None) -> Token:
        if self.at(kind):
            return self.advance()
        self.error(f"expected {what or repr(kind)}, got {describe(self.peek())}")

    def end_line(self):
        if self.at("NEWLINE"):
            self.advance()
        elif not self.at("EOF", "DEDENT"):
            self.error(f"expected end of line, got {describe(self.peek())}")

    def node(self, cls, *args, tok: Token | None = None, **kw):
        return cls(*args, line=(tok or self.peek()).line, **kw)

    # ---------- модуль и блоки ----------

    def parse_module(self) -> Module:
        body = []
        while not self.at("EOF"):
            if self.accept("NEWLINE"):
                continue
            if self.at("INDENT"):
                self.error("unexpected indent")
            body.append(self.parse_stmt())
        return Module(body, line=1)

    def parse_block(self) -> list:
        self.expect("NEWLINE", "end of line")
        self.expect("INDENT", "indented block")
        body = []
        while not self.at("DEDENT", "EOF"):
            if self.accept("NEWLINE"):
                continue
            body.append(self.parse_stmt())
        self.accept("DEDENT")
        return body

    def parse_body(self, *seps: str, required: bool = False) -> tuple[list, bool]:
        """Тело конструкции: блок на следующих строках или одна инструкция на этой.

        Возвращает (инструкции, inline). Для inline конец строки съедает вызывающий.
        """
        if seps:
            if not self.accept(*seps) and required:
                self.error(f"expected {' or '.join(repr(s) for s in seps)}, got {describe(self.peek())}")
        if self.at("NEWLINE"):
            return self.parse_block(), False
        return [self.parse_simple()], True

    # ---------- инструкции ----------

    def parse_stmt(self):
        tok = self.peek()
        k = tok.kind
        if k == "@":
            return self.parse_decorated()
        if k in ("fn", "async"):
            return self.parse_fn([])
        if k == "NAME":
            nxt = self.peek(1)
            if tok.value == "type" and nxt.kind == "NAME":
                return self.parse_type_def()
            if tok.value == "interface" and nxt.kind == "NAME":
                return self.parse_interface()
            if tok.value in HINTS and nxt.kind in ("NAME", ":", "("):
                self.error(f"'{tok.value}' is not Sip: {HINTS[tok.value]}")
        if k == "if":
            return self.parse_if()
        if k == "for":
            return self.parse_for()
        if k == "while":
            return self.parse_while()
        if k == "try":
            return self.parse_try()
        if k == "match":
            return self.parse_match()
        if k == "with":
            return self.parse_with()
        if k == "import":
            return self.parse_import()
        if k == "from":
            return self.parse_from_import()
        stmt = self.parse_simple()
        self.end_line()
        return stmt

    def parse_simple(self):
        """Однострочная инструкция без завершающего перевода строки."""
        tok = self.peek()
        k = tok.kind
        if k == "return":
            self.advance()
            value = None if self.at("NEWLINE", "EOF", "DEDENT", "else", "elif") else self.parse_exprlist()
            return self.node(Return, value, tok=tok)
        if k == "break":
            self.advance()
            return self.node(Break, tok=tok)
        if k == "continue":
            self.advance()
            return self.node(Continue, tok=tok)
        if k == "pass":
            self.advance()
            return self.node(Pass, tok=tok)
        if k == "fail":
            self.advance()
            return self.node(Fail, self.parse_expr(), tok=tok)
        if k == "assert":
            self.advance()
            cond = self.parse_expr()
            msg = self.parse_expr() if self.accept(",") else None
            return self.node(Assert, cond, msg, tok=tok)
        if k == "NAME" and tok.value == "print" and self.peek(1).kind not in PRINT_NOT_COMMAND:
            self.advance()
            args = []
            if not self.at("NEWLINE", "EOF", "DEDENT", "else", "elif"):
                args.append(self.parse_expr())
                while self.accept(","):
                    args.append(self.parse_expr())
            return self.node(ExprStmt, Call(Name("print", line=tok.line), args, [], line=tok.line), tok=tok)

        if k == "NAME" and self.peek(1).kind == ":":
            self.advance()
            self.advance()
            typ = self.parse_type()
            self.expect("=", "'=' after the type")
            return self.node(AnnAssign, Name(tok.value, line=tok.line), typ, self.parse_expr(), tok=tok)

        first = self.parse_exprlist()
        if self.at("="):
            targets = [first]
            while self.accept("="):
                targets.append(self.parse_exprlist())
            value = targets.pop()
            for t in targets:
                self.check_target(t)
            return self.node(Assign, targets, value, tok=tok)
        if self.at(*AUG_OPS):
            op = self.advance().kind
            self.check_target(first)
            return self.node(AugAssign, first, op, self.parse_expr(), tok=tok)
        return self.node(ExprStmt, first, tok=tok)

    def check_target(self, t):
        if isinstance(t, TupleLit):
            for item in t.items:
                self.check_target(item)
        elif not isinstance(t, (Name, Attr, Index, SelfAttr, Starred)):
            raise SipError("cannot assign to this expression", t.line, 0, self.file)

    def parse_exprlist(self):
        tok = self.peek()
        first = self.parse_expr()
        if not self.at(","):
            return first
        items = [first]
        while self.accept(","):
            if self.at("NEWLINE", "=", "EOF"):
                break
            items.append(self.parse_expr())
        return self.node(TupleLit, items, tok=tok)

    def parse_if(self):
        tok = self.expect("if")
        cond = self.parse_expr()
        body, inline = self.parse_body("then", ":")
        branches = [(cond, body)]
        orelse = None
        while True:
            if inline and self.at("NEWLINE") and self.peek(1).kind in ("elif", "else"):
                self.advance()
            if self.at("elif") or (self.at("else") and self.peek(1).kind == "if"):
                if self.advance().kind == "else":
                    self.advance()
                c = self.parse_expr()
                b, inline = self.parse_body("then", ":")
                branches.append((c, b))
            elif self.at("else"):
                self.advance()
                orelse, inline = self.parse_body(":")
                break
            else:
                break
        if inline:
            self.end_line()
        return self.node(If, branches, orelse, tok=tok)

    def parse_target(self):
        tok = self.peek()
        items = [self._target_atom()]
        while self.accept(","):
            items.append(self._target_atom())
        return items[0] if len(items) == 1 else self.node(TupleLit, items, tok=tok)

    def _target_atom(self):
        if self.accept("("):
            inner = self.parse_target()
            self.expect(")")
            return inner
        tok = self.expect("NAME", "loop variable")
        return Name(tok.value, line=tok.line)

    def parse_for(self):
        tok = self.expect("for")
        target = self.parse_target()
        self.expect("in")
        it = self.parse_expr()
        body, inline = self.parse_body(":")
        if inline:
            self.end_line()
        return self.node(For, target, it, body, tok=tok)

    def parse_while(self):
        tok = self.expect("while")
        cond = self.parse_expr()
        body, inline = self.parse_body(":")
        if inline:
            self.end_line()
        return self.node(While, cond, body, tok=tok)

    def parse_dotted(self) -> str:
        name = self.expect("NAME").value
        while self.at(".") and is_word(self.peek(1)):
            self.advance()
            name += "." + self.advance().value
        return name

    def parse_try(self):
        tok = self.expect("try")
        body, inline = self.parse_body(":")
        if inline:
            self.end_line()
        handlers = []
        while self.at("catch"):
            htok = self.advance()
            kind = name = None
            if self.at("NAME") and (self.peek().value[0].isupper()
                                    or (self.peek(1).kind == "." and is_word(self.peek(2)))):
                kind = self.parse_dotted()  # ValueError, NotEnough, bank.NotEnough
            if self.at("NAME"):
                name = self.advance().value
            elif self.accept("as"):
                name = self.expect("NAME").value
            hbody, inline = self.parse_body("->", ":")
            if inline:
                self.end_line()
            handlers.append(Handler(kind, name, hbody, line=htok.line))
        if not handlers:
            self.error("expected 'catch' after try")
        return self.node(Try, body, handlers, tok=tok)

    def parse_match(self):
        tok = self.expect("match")
        subject = self.parse_expr()
        self.accept(":")
        self.expect("NEWLINE", "end of line")
        self.expect("INDENT", "indented match arms")
        arms = []
        while not self.at("DEDENT", "EOF"):
            if self.accept("NEWLINE"):
                continue
            atok = self.peek()
            pattern = self.parse_pattern()
            guard = self.parse_or() if self.accept("if") else None
            body, inline = self.parse_body("->", ":", required=True)
            if inline:
                self.end_line()
            arms.append(Arm(pattern, guard, body, line=atok.line))
        self.accept("DEDENT")
        return self.node(Match, subject, arms, tok=tok)

    def parse_with(self):
        tok = self.expect("with")
        items = []
        while True:
            e = self.parse_expr()
            name = self.expect("NAME").value if self.accept("as") else None
            items.append((e, name))
            if not self.accept(","):
                break
        body, inline = self.parse_body(":")
        if inline:
            self.end_line()
        return self.node(With, items, body, tok=tok)

    def parse_import(self):
        tok = self.expect("import")
        module = self.parse_dotted()
        alias = self.expect("NAME").value if self.accept("as") else None
        self.end_line()
        return self.node(Import, module, alias, tok=tok)

    def parse_from_import(self):
        tok = self.expect("from")
        module = self.parse_dotted()
        self.expect("import")
        names = []
        paren = self.accept("(")
        while True:
            name = self.expect("NAME").value
            alias = self.expect("NAME").value if self.accept("as") else None
            names.append((name, alias))
            if not self.accept(","):
                break
        if paren:
            self.expect(")")
        self.end_line()
        return self.node(FromImport, module, names, tok=tok)

    # ---------- функции и типы ----------

    def parse_decorated(self):
        decorators = []
        while self.accept("@"):
            decorators.append(self.parse_expr())
            self.end_line()
            while self.accept("NEWLINE"):
                pass
        if not self.at("fn", "async"):
            self.error("decorators can only be applied to functions")
        return self.parse_fn(decorators)

    def parse_fn(self, decorators, is_method=False):
        tok = self.peek()
        is_async = bool(self.accept("async"))
        self.expect("fn")
        name = self.expect("NAME", "function name").value
        tparams = self.parse_tparams()
        self.expect("(")
        params = self.parse_params(")")
        self.expect(")")
        if is_method and params and params[0].name == "self":
            params = params[1:]
        self.accept("->")
        ret = None
        if not self.at("=", "NEWLINE", ":"):
            ret = self.parse_type()
        if self.accept("="):
            if self.at("match"):
                body = [self.parse_match()]
            elif self.at("try"):
                body = [self.parse_try()]
            else:
                etok = self.peek()
                body = [ExprStmt(self.parse_expr(), line=etok.line)]
                self.end_line()
        else:
            self.accept(":")
            body = self.parse_block()
        return FnDef(name, params, ret, body, is_async, decorators, is_method, tparams, line=tok.line)

    def parse_tparams(self) -> list:
        """[T, U: Shape] после имени функции или типа."""
        out = []
        if not self.accept("["):
            return out
        while not self.at("]"):
            tok = self.expect("NAME", "type parameter name")
            bound = None
            if self.accept(":"):
                bound = self.parse_type()
            out.append(TParamDef(tok.value, bound, line=tok.line))
            if not self.accept(","):
                break
        self.expect("]")
        if not out:
            self.error("empty type parameter list")
        return out

    def parse_interface(self):
        tok = self.advance()  # `interface`
        name = self.expect("NAME", "interface name").value
        methods = []
        self.accept(":")
        if self.at("NEWLINE") and self.peek(1).kind == "INDENT":
            self.advance()
            self.advance()
            while not self.at("DEDENT", "EOF"):
                if self.accept("NEWLINE"):
                    continue
                mtok = self.expect("fn", "'fn' (an interface lists method signatures)")
                mname = self.expect("NAME", "method name").value
                if self.at("["):
                    self.error("interface methods cannot have type parameters")
                self.expect("(")
                params = self.parse_params(")")
                self.expect(")")
                if params and params[0].name == "self":
                    params = params[1:]
                self.accept("->")
                ret = None if self.at("NEWLINE") else self.parse_type()
                if self.at("=", ":"):
                    self.error("interface methods have no body: write only the signature")
                self.end_line()
                methods.append(FnDef(mname, params, ret, [], is_method=True, line=mtok.line))
            self.accept("DEDENT")
        else:
            self.end_line()
        if not methods:
            self.error("an interface needs at least one method: fn name(...) Type", tok)
        return Interface(name, methods, line=tok.line)

    def parse_params(self, closing: str) -> list:
        params = []
        while not self.at(closing):
            tok = self.peek()
            star = ""
            if self.at("*", "**"):
                star = self.advance().kind
            name = self.expect("NAME", "parameter name").value
            self.accept(":")
            typ = None
            if not self.at(",", closing, "="):
                typ = self.parse_type()
            default = self.parse_expr() if self.accept("=") else None
            params.append(Param(name, typ, default, star, line=tok.line))
            if not self.accept(","):
                break
        return params

    def at_type_start(self) -> bool:
        return self.at("[", "{", "(", "nil", "fn", "NAME")

    def parse_type(self):
        tok = self.peek()
        if self.accept("["):
            t = TList(self.parse_type(), line=tok.line)
            self.expect("]")
        elif self.accept("{"):
            key = self.parse_type()
            if self.accept("}"):
                t = TSet(key, line=tok.line)
            else:
                self.expect(":")
                value = self.parse_type()
                self.expect("}")
                t = TDict(key, value, line=tok.line)
        elif self.accept("("):
            items = []
            while not self.at(")"):
                items.append(self.parse_type())
                if not self.accept(","):
                    break
            self.expect(")")
            t = TTuple(items, line=tok.line)
        elif self.accept("nil"):
            t = TName("None", line=tok.line)
        elif self.accept("fn"):
            self.expect("(")
            params = []
            while not self.at(")"):
                params.append(self.parse_type())
                if not self.accept(","):
                    break
            self.expect(")")
            ret = self.parse_type() if self.at_type_start() else None
            t = TFn(params, ret, line=tok.line)
        elif self.at("NAME"):
            name = self.parse_dotted()
            args = []
            if self.accept("["):
                while not self.at("]"):
                    args.append(self.parse_type())
                    if not self.accept(","):
                        break
                self.expect("]")
            t = TName(name, args, line=tok.line)
        else:
            self.error(f"expected type, got {describe(tok)}")
        while self.accept("?"):
            t = TOptional(t, line=tok.line)
        return t

    def parse_type_def(self):
        tok = self.advance()  # `type`
        name = self.expect("NAME", "type name").value
        tparams = self.parse_tparams()
        if self.accept("="):
            variants = []
            self.accept("|")
            while True:
                vtok = self.expect("NAME", "variant name")
                fields = []
                if self.accept("("):
                    fields = self.parse_params(")")
                    self.expect(")")
                variants.append(Variant(vtok.value, fields, line=vtok.line))
                if not self.accept("|"):
                    break
            fields, methods = self.parse_type_body()
            if fields:
                self.error("a sum type cannot have fields: put them in the variants")
            return SumType(name, variants, methods, tparams, line=tok.line)
        fields = []
        if self.accept("("):
            fields = self.parse_params(")")
            self.expect(")")
        more, methods = self.parse_type_body()
        return Record(name, fields + more, methods, tparams, line=tok.line)

    def parse_type_body(self) -> tuple[list, list]:
        self.accept(":")
        if not (self.at("NEWLINE") and self.peek(1).kind == "INDENT"):
            self.end_line()
            return [], []
        self.advance()
        self.advance()
        fields, methods = [], []
        while not self.at("DEDENT", "EOF"):
            if self.accept("NEWLINE"):
                continue
            if self.at("@"):
                decorators = []
                while self.accept("@"):
                    decorators.append(self.parse_expr())
                    self.end_line()
                methods.append(self.parse_fn(decorators, is_method=True))
            elif self.at("fn", "async"):
                methods.append(self.parse_fn([], is_method=True))
            elif self.at("NAME"):
                ftok = self.advance()
                self.accept(":")
                typ = None if self.at("=", "NEWLINE") else self.parse_type()
                default = self.parse_expr() if self.accept("=") else None
                fields.append(Param(ftok.value, typ, default, line=ftok.line))
                self.end_line()
            else:
                self.error(f"expected field or method, got {describe(self.peek())}")
        self.accept("DEDENT")
        return fields, methods

    # ---------- выражения ----------

    def parse_expr(self):
        if self.at("if"):
            return self.parse_if_expr()
        if self.at("fn") and self.peek(1).kind == "(":
            return self.parse_lambda()
        return self.parse_or()

    def parse_if_expr(self):
        tok = self.advance()  # if или elif
        cond = self.parse_or()
        self.expect("then", "'then' (an if-expression is written 'if c then a else b')")
        then = self.parse_expr()
        if self.at("elif"):
            other = self.parse_if_expr()
        else:
            self.expect("else", "'else' (an if-expression needs an else branch)")
            other = self.parse_expr()
        return IfExpr(cond, then, other, line=tok.line)

    def parse_lambda(self):
        tok = self.advance()  # fn
        self.expect("(")
        names, types = [], []
        while not self.at(")"):
            names.append(self.expect("NAME", "parameter name").value)
            self.accept(":")
            types.append(None if self.at(",", ")") else self.parse_type())
            if not self.accept(","):
                break
        self.expect(")")
        if self.at("NEWLINE") and self.peek(1).kind == "INDENT":  # многострочная лямбда
            return Lambda(names, None, types, self.parse_block(), line=tok.line)
        self.expect("=", "'=' before the body of fn(...), or the body on the next lines")
        return Lambda(names, self.parse_expr(), types, line=tok.line)

    def _binary(self, sub, ops):
        left = sub()
        while self.at(*ops):
            tok = self.advance()
            left = BinOp(tok.kind, left, sub(), line=tok.line)
        return left

    def parse_or(self):
        return self._binary(self.parse_and, ("or",))

    def parse_and(self):
        return self._binary(self.parse_not, ("and",))

    def parse_not(self):
        if self.at("not"):
            tok = self.advance()
            return Unary("not", self.parse_not(), line=tok.line)
        return self.parse_cmp()

    def parse_cmp(self):
        tok = self.peek()
        left = self.parse_bitor()
        ops = []
        while True:
            if self.at(*CMP_OPS):
                op = self.advance().kind
            elif self.at("in"):
                self.advance()
                op = "in"
            elif self.at("not") and self.peek(1).kind == "in":
                self.advance()
                self.advance()
                op = "not in"
            elif self.at("is"):
                self.advance()
                op = "is not" if self.accept("not") else "is"
            else:
                break
            ops.append((op, self.parse_bitor()))
        return Compare(left, ops, line=tok.line) if ops else left

    def parse_bitor(self):
        return self._binary(self.parse_bitxor, ("|",))

    def parse_bitxor(self):
        return self._binary(self.parse_bitand, ("^",))

    def parse_bitand(self):
        return self._binary(self.parse_range, ("&",))

    def parse_range(self):
        lo = self.parse_add()
        if self.at(".."):
            tok = self.advance()
            return Range(lo, self.parse_add(), line=tok.line)
        return lo

    def parse_add(self):
        return self._binary(self.parse_mul, ("+", "-"))

    def parse_mul(self):
        return self._binary(self.parse_unary, ("*", "/", "//", "%"))

    def parse_unary(self):
        if self.at("-", "+", "~"):
            tok = self.advance()
            return Unary(tok.kind, self.parse_unary(), line=tok.line)
        return self.parse_power()

    def parse_power(self):
        base = self.parse_await()
        if self.at("**"):
            tok = self.advance()
            return BinOp("**", base, self.parse_unary(), line=tok.line)
        return base

    def parse_await(self):
        if self.at("await"):
            tok = self.advance()
            return Await(self.parse_postfix(), line=tok.line)
        return self.parse_postfix()

    def parse_postfix(self):
        e = self.parse_primary()
        while True:
            tok = self.peek()
            if tok.kind == ".":
                self.advance()
                name = self.advance()
                if not is_word(name):
                    self.error(f"expected attribute name, got {describe(name)}", name)
                e = Attr(e, name.value, line=tok.line)
            elif tok.kind == "(":
                e = self.parse_call(e)
            elif tok.kind == "[":
                e = self.parse_index(e)
            else:
                return e

    def parse_call(self, func):
        tok = self.advance()  # (
        args, kwargs = [], []
        while not self.at(")"):
            if self.at("*", "**"):
                star = self.advance().kind
                args.append(Starred(self.parse_expr(), star == "**", line=tok.line))
            elif is_word(self.peek()) and self.peek(1).kind in (":", "="):
                name = self.advance().value
                self.advance()
                kwargs.append((name, self.parse_expr()))
            else:
                a = self.parse_expr()
                if self.at("for") and not args and not kwargs:
                    a = self.parse_comp("gen", a)
                args.append(a)
            if not self.accept(","):
                break
        self.expect(")", "')' or ','")
        return Call(func, args, kwargs, line=tok.line)

    def parse_index(self, obj):
        tok = self.advance()  # [

        def part():
            return None if self.at(":", "]") else self.parse_expr()

        lo = part()
        if self.at(":"):
            self.advance()
            hi = part()
            step = part() if self.accept(":") else None
            index = Slice(lo, hi, step, line=tok.line)
        elif self.at(","):
            items = [lo]
            while self.accept(","):
                if self.at("]"):
                    break
                items.append(self.parse_expr())
            index = TupleLit(items, line=tok.line)
        else:
            index = lo
        self.expect("]")
        return Index(obj, index, line=tok.line)

    def parse_primary(self):
        tok = self.peek()
        k = tok.kind
        if k == "NUMBER":
            self.advance()
            return Num(tok.value, line=tok.line)
        if k == "STRING":
            return self.parse_string()
        if k == "NAME":
            if tok.value in HINTS and tok.value == "lambda":
                self.error(f"'lambda' is not Sip: {HINTS['lambda']}")
            self.advance()
            return Name(tok.value, line=tok.line)
        if k in ("nil", "true", "false"):
            self.advance()
            return Const({"nil": "None", "true": "True", "false": "False"}[k], line=tok.line)
        if k == "NAME" and tok.value == "None":  # привычка из Python
            self.advance()
            return Const("None", line=tok.line)
        if k == ".":
            self.advance()
            name = self.advance()
            if not is_word(name):
                self.error("expected field name after '.'", name)
            return SelfAttr(name.value, line=tok.line)
        if k == "(":
            return self.parse_paren()
        if k == "[":
            return self.parse_list()
        if k == "{":
            return self.parse_brace()
        if k == "fn" and self.peek(1).kind == "(":
            return self.parse_lambda()
        if k == "if":
            return self.parse_if_expr()
        self.error(f"expected expression, got {describe(tok)}")

    def parse_item(self):
        """Элемент списка или множества: выражение или `*spread`."""
        if self.at("*"):
            tok = self.advance()
            return Starred(self.parse_expr(), line=tok.line)
        return self.parse_expr()

    def parse_paren(self):
        tok = self.advance()  # (
        if self.accept(")"):
            return TupleLit([], line=tok.line)
        first = self.parse_item()
        if self.at("for"):
            comp = self.parse_comp("gen", first)
            self.expect(")")
            return comp
        if self.at(","):
            items = [first]
            while self.accept(","):
                if self.at(")"):
                    break
                items.append(self.parse_item())
            self.expect(")")
            return TupleLit(items, line=tok.line)
        self.expect(")")
        return first

    def parse_list(self):
        tok = self.advance()  # [
        if self.accept("]"):
            return ListLit([], line=tok.line)
        first = self.parse_item()
        if self.at("for"):
            comp = self.parse_comp("list", first)
            self.expect("]")
            return comp
        items = [first]
        while self.accept(","):
            if self.at("]"):
                break
            items.append(self.parse_item())
        self.expect("]", "']' or ','")
        return ListLit(items, line=tok.line)

    def parse_dict_key(self):
        """Ключ словаря. Голое имя `{host: 1}` означает строку "host"."""
        tok = self.peek()
        if is_word(tok) and self.peek(1).kind == ":":
            self.advance()
            return tok.value, True
        return self.parse_expr(), False

    def parse_brace(self):
        tok = self.advance()  # {
        if self.accept("}"):
            return DictLit([], line=tok.line)

        def bare_str(name):
            return Str([name], '"', line=tok.line)

        pairs = []
        if self.at("**"):
            self.advance()
            pairs.append((None, self.parse_expr()))
        else:
            key, bare = self.parse_dict_key()
            if not self.at(":"):
                # множество
                first = Name(key, line=tok.line) if bare else key
                if self.at("for"):
                    comp = self.parse_comp("set", first)
                    self.expect("}")
                    return comp
                items = [first]
                while self.accept(","):
                    if self.at("}"):
                        break
                    items.append(self.parse_item())
                self.expect("}")
                return SetLit(items, line=tok.line)
            self.advance()  # :
            value = self.parse_expr()
            if self.at("for"):
                # в генераторе словаря голое имя — это переменная, а не строка
                comp = self.parse_comp("dict", value, key=Name(key, line=tok.line) if bare else key)
                self.expect("}")
                return comp
            pairs.append((bare_str(key) if bare else key, value))
        while self.accept(","):
            if self.at("}"):
                break
            if self.accept("**"):
                pairs.append((None, self.parse_expr()))
                continue
            key, bare = self.parse_dict_key()
            self.expect(":", "':' in dict literal")
            pairs.append((bare_str(key) if bare else key, self.parse_expr()))
        self.expect("}", "'}' or ','")
        return DictLit(pairs, line=tok.line)

    def parse_comp(self, kind, elt, key=None):
        line = self.peek().line
        clauses = []
        while self.at("for"):
            ftok = self.advance()
            target = self.parse_target()
            self.expect("in")
            it = self.parse_or()
            conds = []
            while self.at("if"):
                self.advance()
                conds.append(self.parse_or())
            clauses.append(CompFor(target, it, conds, line=ftok.line))
        return Comp(kind, elt, key, clauses, line=line)

    def parse_string(self):
        tok = self.advance()
        quote, raw = tok.value
        parts: list = []
        buf: list[str] = []
        i, n = 0, len(raw)

        def flush():
            if buf:
                parts.append("".join(buf))
                buf.clear()

        while i < n:
            c = raw[i]
            if c == "\\" and i + 1 < n:
                buf.append(raw[i:i + 2])
                i += 2
                continue
            if c == "{":
                if raw[i + 1:i + 2] == "{":
                    buf.append("{")
                    i += 2
                    continue
                j = self._match_brace(raw, i, tok)
                inner = raw[i + 1:j]
                if not inner.strip():
                    self.error("empty {} in string: write {{}} for literal braces", tok)
                text, spec = _split_spec(inner)
                flush()
                parts.append(Interp(self._sub_expr(text, tok), spec, line=tok.line))
                i = j + 1
                continue
            if c == "}":
                if raw[i + 1:i + 2] == "}":
                    buf.append("}")
                    i += 2
                    continue
                self.error("single '}' in string: write '}}'", tok)
            buf.append(c)
            i += 1
        flush()
        return Str(parts, quote, line=tok.line)

    def _match_brace(self, raw, i, tok):
        depth = 0
        j = i
        while j < len(raw):
            c = raw[j]
            if c in "\"'":
                k = j + 1
                while k < len(raw) and raw[k] != c:
                    k += 2 if raw[k] == "\\" else 1
                j = k
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return j
            j += 1
        self.error("unclosed '{' in string", tok)

    def _sub_expr(self, text, tok):
        try:
            toks = tokenize("(" + text + ")", self.file)
        except SipError as e:
            raise SipError(f"in string: {e.msg}", tok.line, tok.col, self.file) from None
        for t in toks:
            t.line = tok.line
            t.col = tok.col
        sub = Parser(toks, self.file)
        expr = sub.parse_expr()
        if not sub.at("NEWLINE", "EOF"):
            sub.error("bad expression inside {} in string")
        return expr

    # ---------- образцы ----------

    def parse_pattern(self):
        tok = self.peek()
        p = self.parse_pattern_atom()
        if self.at("|"):
            alts = [p]
            while self.accept("|"):
                alts.append(self.parse_pattern_atom())
            p = POr(alts, line=tok.line)
        return p

    def parse_pattern_atom(self):
        tok = self.peek()
        k = tok.kind
        if k == "NAME":
            if tok.value in ("True", "False", "None"):
                self.advance()
                return PLit(Const(tok.value, line=tok.line), line=tok.line)
            name = self.parse_dotted()
            if self.accept("("):
                args, kwargs = [], []
                while not self.at(")"):
                    if self.at("NAME") and self.peek(1).kind in ("=", ":"):
                        kname = self.advance().value
                        self.advance()
                        kwargs.append((kname, self.parse_pattern()))
                    else:
                        args.append(self.parse_pattern())
                    if not self.accept(","):
                        break
                self.expect(")")
                return PClass(name, args, kwargs, line=tok.line)
            if name == "_":
                return PWild(line=tok.line)
            if "." in name:
                return PValue(name, line=tok.line)
            if name[0].isupper():
                return PClass(name, [], [], line=tok.line)  # вариант без полей
            return PCapture(name, line=tok.line)
        if k in ("NUMBER", "STRING", "nil", "true", "false"):
            expr = self.parse_primary()
            if isinstance(expr, Str) and any(isinstance(p, Interp) for p in expr.parts):
                self.error("string pattern cannot contain {interpolation}", tok)
            return PLit(expr, line=tok.line)
        if k == "-":
            self.advance()
            num = self.expect("NUMBER", "number")
            return PLit(Unary("-", Num(num.value, line=tok.line), line=tok.line), line=tok.line)
        if k == "*":
            self.advance()
            return PStar(self.expect("NAME").value, line=tok.line)
        if k in ("(", "["):
            close = ")" if k == "(" else "]"
            self.advance()
            items = []
            trailing_comma = False
            while not self.at(close):
                items.append(self.parse_pattern())
                trailing_comma = bool(self.accept(","))
                if not trailing_comma:
                    break
            self.expect(close)
            if k == "(":
                if len(items) == 1 and not trailing_comma:
                    return items[0]
                return PTuple(items, line=tok.line)
            return PList(items, line=tok.line)
        self.error(f"expected pattern, got {describe(tok)}")


def _split_spec(inner: str) -> tuple[str, str | None]:
    """Отделяет формат `{x:.2f}`: ищет двоеточие вне скобок и строк."""
    depth = 0
    i = 0
    while i < len(inner):
        c = inner[i]
        if c in "\"'":
            k = i + 1
            while k < len(inner) and inner[k] != c:
                k += 2 if inner[k] == "\\" else 1
            i = k
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ":" and depth == 0:
            return inner[:i], inner[i + 1:]
        i += 1
    return inner, None


def parse(src: str, file: str = "<input>") -> Module:
    return Parser(tokenize(src, file), file).parse_module()
