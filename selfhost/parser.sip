# Парсер Sip на самом Sip: перенос siplang/parser.py.
# Дерево — общий узел N: вид (имя класса из siplang/nodes.py), строка и дети
# в порядке полей этого класса. Листья: str (текст в s), None, bool, list, tuple.
# sip run selfhost/parser.sip FILE.sip печатает дерево (формат — в dump).

import lexer

type N(kind str, line int, s str, kids [N], ty int = 0)

type ParseError(msg str, line int, col int)

fn mk(kind str, line int, kids [N]) N = N(kind, line, "", kids)

fn S(text str) N = N("str", 0, text, [])

fn NONE() N = N("None", 0, "", [])

fn B(b bool) N = N("bool", 0, if b then "True" else "False", [])

fn L(items [N]) N = N("list", 0, "", items)

fn T(items [N]) N = N("tuple", 0, "", items)

fn is_none(n N) bool = n.kind == "None"

AUG_OPS = ["+=", "-=", "*=", "/=", "%="]
CMP_OPS = ["==", "!=", "<", ">", "<=", ">="]
PRINT_NOT_COMMAND = ["(", "=", ",", "+=", "-=", "*=", "/=", "%="]
HINTS = {
    "def": "use 'fn' to define a function",
    "class": "use 'type Name(field type, ...)' to define a record",
    "lambda": "use 'fn(x) = expr' for an anonymous function",
    "except": "use 'catch Kind e' instead of 'except'",
    "raise": "use 'fail value' to raise an error",
}
C_INTS = {"i8": "int8_t", "i16": "int16_t", "i32": "int32_t", "i64": "int64_t", "u8": "uint8_t",
          "u16": "uint16_t", "u32": "uint32_t", "u64": "uint64_t", "usize": "size_t"}
C_FLOATS = {"f32": "float", "f64": "double"}

fn describe(tok lexer.Token) str
    k = tok.kind
    if k == "NEWLINE" then return "end of line"
    if k == "INDENT" then return "indented block"
    if k == "DEDENT" then return "end of block"
    if k == "EOF" then return "end of file"
    if k == "NUMBER" then return "number {tok.value}"
    if k == "STRING" then return "string"
    if k == "NAME" then return "name '{tok.value}'"
    "'{k}'"

fn is_word(tok lexer.Token) bool = tok.kind == "NAME" or tok.kind in lexer.KEYWORDS

fn is_upper_start(s str) bool = s != "" and s[0] >= "A" and s[0] <= "Z"

# отделяет формат `{x:.2f}`: двоеточие вне скобок и строк
fn split_spec(inner str) [str]
    depth = 0
    i = 0
    while i < len(inner)
        c = inner[i]
        if c == "\"" or c == "'"
            k = i + 1
            while k < len(inner) and inner[k] != c
                k += if inner[k] == "\\" then 2 else 1
            i = k
        elif c == "(" or c == "[" or c == "{{"
            depth += 1
        elif c == ")" or c == "]" or c == "}}"
            depth -= 1
        elif c == ":" and depth == 0
            return [inner[:i], inner[i + 1:]]
        i += 1
    [inner]

type Parser(toks [lexer.Token], i int)
    # ---------- вспомогательное ----------

    fn peek(k int = 0) lexer.Token
        j = .i + k
        if j > len(.toks) - 1 then j = len(.toks) - 1
        .toks[j]

    fn at(*kinds str) bool = .peek().kind in kinds

    fn advance() lexer.Token
        tok = .peek()
        if tok.kind != "EOF" then .i += 1
        tok

    fn accept(*kinds str) bool
        if .peek().kind in kinds
            .advance()
            return true
        false

    fn error(msg str)
        tok = .peek()
        fail ParseError(msg, tok.line, tok.col)

    fn error_at(msg str, tok lexer.Token)
        fail ParseError(msg, tok.line, tok.col)

    fn expect(kind str, what str = "") lexer.Token
        if .at(kind) then return .advance()
        w = if what == "" then "'{kind}'" else what
        .error("expected {w}, got {describe(.peek())}")
        .advance()

    fn end_line()
        if .at("NEWLINE")
            .advance()
        elif not .at("EOF", "DEDENT")
            .error("expected end of line, got {describe(.peek())}")
        pass

    # ---------- модуль и блоки ----------

    fn parse_module() N
        body: [N] = []
        while not .at("EOF")
            if .accept("NEWLINE") then continue
            if .at("INDENT") then .error("unexpected indent")
            if .at("NAME") and .peek().value == "test" and .peek(1).kind == "STRING"
                body.append(.parse_test())
                continue
            body.append(.parse_stmt())
        mk("Module", 1, [L(body)])

    fn parse_test() N
        tok = .advance()
        name = .advance().value
        .accept(":")
        mk("TestDef", tok.line, [S(name), L(.parse_block())])

    fn parse_block() [N]
        .expect("NEWLINE", "end of line")
        .expect("INDENT", "indented block")
        body: [N] = []
        while not .at("DEDENT", "EOF")
            if .accept("NEWLINE") then continue
            body.append(.parse_stmt())
        .accept("DEDENT")
        body

    # тело: блок на следующих строках или одна инструкция на этой; второе — inline
    fn parse_body(seps [str], required = false) ([N], bool)
        if seps
            ok = false
            for s in seps
                if not ok and .at(s)
                    .advance()
                    ok = true
            if not ok and required
                alts = " or ".join(["'" + s + "'" for s in seps])
                .error("expected {alts}, got {describe(.peek())}")
        if .at("NEWLINE") then return (.parse_block(), false)
        ([.parse_simple()], true)

    # ---------- инструкции ----------

    fn parse_stmt() N
        tok = .peek()
        k = tok.kind
        if k == "@" then return .parse_decorated()
        if k == "fn" or k == "async" then return .parse_fn([], false)
        if k == "NAME"
            nxt = .peek(1)
            if tok.value == "type" and nxt.kind == "NAME" then return .parse_type_def()
            if tok.value == "interface" and nxt.kind == "NAME" then return .parse_interface()
            if tok.value == "extern" and (nxt.kind == "fn" or nxt.kind == "STRING") then return .parse_extern()
            hint = HINTS.get(tok.value)
            if hint != nil and (nxt.kind == "NAME" or nxt.kind == ":" or nxt.kind == "(")
                .error("'{tok.value}' is not Sip: {hint}")
        if k == "if" then return .parse_if()
        if k == "for" then return .parse_for()
        if k == "while" then return .parse_while()
        if k == "try" then return .parse_try()
        if k == "match" then return .parse_match()
        if k == "with" then return .parse_with()
        if k == "import" then return .parse_import()
        if k == "from" then return .parse_from_import()
        stmt = .parse_simple()
        .end_line()
        stmt

    fn parse_simple() N
        tok = .peek()
        k = tok.kind
        if k == "return"
            .advance()
            value = if .at("NEWLINE", "EOF", "DEDENT", "else", "elif") then NONE() else .parse_exprlist()
            return mk("Return", tok.line, [value])
        if k == "break"
            .advance()
            return mk("Break", tok.line, [])
        if k == "continue"
            .advance()
            return mk("Continue", tok.line, [])
        if k == "pass"
            .advance()
            return mk("Pass", tok.line, [])
        if k == "fail"
            .advance()
            return mk("Fail", tok.line, [.parse_expr()])
        if k == "assert"
            .advance()
            cond = .parse_expr()
            msg = if .accept(",") then .parse_expr() else NONE()
            return mk("Assert", tok.line, [cond, msg])
        if k == "NAME" and tok.value == "print" and not (.peek(1).kind in PRINT_NOT_COMMAND)
            .advance()
            args: [N] = []
            if not .at("NEWLINE", "EOF", "DEDENT", "else", "elif")
                args.append(.parse_expr())
                while .accept(",")
                    args.append(.parse_expr())
            call = mk("Call", tok.line, [mk("Name", tok.line, [S("print")]), L(args), L([])])
            return mk("ExprStmt", tok.line, [call])
        if k == "NAME" and .peek(1).kind == ":"
            .advance()
            .advance()
            typ = .parse_type()
            .expect("=", "'=' after the type")
            return mk("AnnAssign", tok.line, [mk("Name", tok.line, [S(tok.value)]), typ, .parse_expr()])
        first = .parse_exprlist()
        if .at("=")
            targets = [first]
            while .accept("=")
                targets.append(.parse_exprlist())
            value = targets.pop()
            for t in targets
                .check_target(t)
            return mk("Assign", tok.line, [L(targets), value])
        if .peek().kind in AUG_OPS
            op = .advance().kind
            .check_target(first)
            return mk("AugAssign", tok.line, [first, S(op), .parse_expr()])
        mk("ExprStmt", tok.line, [first])

    fn check_target(t N)
        if t.kind == "TupleLit"
            for item in t.kids[0].kids
                .check_target(item)
        elif not (t.kind in ["Name", "Attr", "Index", "SelfAttr", "Starred"])
            fail ParseError("cannot assign to this expression", t.line, 0)
        pass

    fn parse_exprlist() N
        tok = .peek()
        first = .parse_expr()
        if not .at(",") then return first
        items = [first]
        while .accept(",")
            if .at("NEWLINE", "=", "EOF") then break
            items.append(.parse_expr())
        mk("TupleLit", tok.line, [L(items)])

    fn parse_if() N
        tok = .expect("if")
        cond = .parse_expr()
        body, inline = .parse_body(["then", ":"])
        branches = [T([cond, L(body)])]
        orelse = NONE()
        while true
            if inline and .at("NEWLINE") and (.peek(1).kind == "elif" or .peek(1).kind == "else")
                .advance()
            if .at("elif") or (.at("else") and .peek(1).kind == "if")
                if .advance().kind == "else" then .advance()
                c = .parse_expr()
                b, inl = .parse_body(["then", ":"])
                inline = inl
                branches.append(T([c, L(b)]))
            elif .at("else")
                .advance()
                ob, inl = .parse_body([":"])
                inline = inl
                orelse = L(ob)
                break
            else
                break
        if inline then .end_line()
        mk("If", tok.line, [L(branches), orelse])

    fn parse_target() N
        tok = .peek()
        items = [.target_atom()]
        while .accept(",")
            items.append(.target_atom())
        if len(items) == 1 then items[0] else mk("TupleLit", tok.line, [L(items)])

    fn target_atom() N
        if .accept("(")
            inner = .parse_target()
            .expect(")")
            return inner
        tok = .expect("NAME", "loop variable")
        mk("Name", tok.line, [S(tok.value)])

    fn parse_for() N
        tok = .expect("for")
        target = .parse_target()
        .expect("in")
        it = .parse_expr()
        body, inline = .parse_body([":"])
        if inline then .end_line()
        mk("For", tok.line, [target, it, L(body)])

    fn parse_while() N
        tok = .expect("while")
        cond = .parse_expr()
        body, inline = .parse_body([":"])
        if inline then .end_line()
        mk("While", tok.line, [cond, L(body)])

    fn parse_dotted() str
        name = .expect("NAME").value
        while .at(".") and is_word(.peek(1))
            .advance()
            name = name + "." + .advance().value
        name

    fn parse_try() N
        tok = .expect("try")
        body, inline = .parse_body([":"])
        if inline then .end_line()
        handlers: [N] = []
        while .at("catch")
            htok = .advance()
            kind = NONE()
            name = NONE()
            if .at("NAME") and (is_upper_start(.peek().value) or (.peek(1).kind == "." and is_word(.peek(2))))
                kind = S(.parse_dotted())  # ValueError, NotEnough, bank.NotEnough
            if .at("NAME")
                name = S(.advance().value)
            elif .accept("as")
                name = S(.expect("NAME").value)
            hbody, hinline = .parse_body(["->", ":"])
            if hinline then .end_line()
            handlers.append(mk("Handler", htok.line, [kind, name, L(hbody)]))
        if not handlers then .error("expected 'catch' after try")
        mk("Try", tok.line, [L(body), L(handlers)])

    fn parse_match() N
        tok = .expect("match")
        subject = .parse_expr()
        .accept(":")
        .expect("NEWLINE", "end of line")
        .expect("INDENT", "indented match arms")
        arms: [N] = []
        while not .at("DEDENT", "EOF")
            if .accept("NEWLINE") then continue
            atok = .peek()
            pattern = .parse_pattern()
            guard = if .accept("if") then .parse_or() else NONE()
            body, inline = .parse_body(["->", ":"], true)
            if inline then .end_line()
            arms.append(mk("Arm", atok.line, [pattern, guard, L(body)]))
        .accept("DEDENT")
        mk("Match", tok.line, [subject, L(arms)])

    fn parse_with() N
        tok = .expect("with")
        items: [N] = []
        while true
            e = .parse_expr()
            name = if .accept("as") then S(.expect("NAME").value) else NONE()
            items.append(T([e, name]))
            if not .accept(",") then break
        body, inline = .parse_body([":"])
        if inline then .end_line()
        mk("With", tok.line, [L(items), L(body)])

    fn parse_import() N
        tok = .expect("import")
        module = .parse_dotted()
        alias = if .accept("as") then S(.expect("NAME").value) else NONE()
        .end_line()
        mk("Import", tok.line, [S(module), alias])

    fn parse_from_import() N
        tok = .expect("from")
        module = .parse_dotted()
        .expect("import")
        names: [N] = []
        paren = .accept("(")
        while true
            name = .expect("NAME").value
            alias = if .accept("as") then S(.expect("NAME").value) else NONE()
            names.append(T([S(name), alias]))
            if not .accept(",") then break
        if paren then .expect(")")
        .end_line()
        mk("FromImport", tok.line, [S(module), L(names)])

    # ---------- функции и типы ----------

    fn parse_decorated() N
        decorators: [N] = []
        while .accept("@")
            decorators.append(.parse_expr())
            .end_line()
            while .accept("NEWLINE")
                pass
        if not .at("fn", "async") then .error("decorators can only be applied to functions")
        .parse_fn(decorators, false)

    fn parse_fn(decorators [N], is_method bool) N
        tok = .peek()
        is_async = .accept("async")
        .expect("fn")
        name = .expect("NAME", "function name").value
        tparams = .parse_tparams()
        .expect("(")
        params = .parse_params(")")
        .expect(")")
        if is_method and params and params[0].kids[0].s == "self" then params = params[1:]
        .accept("->")
        ret = NONE()
        if not .at("=", "NEWLINE", ":") then ret = .parse_type()
        body: [N] = []
        if .accept("=")
            if .at("match")
                body = [.parse_match()]
            elif .at("try")
                body = [.parse_try()]
            else
                etok = .peek()
                body = [mk("ExprStmt", etok.line, [.parse_expr()])]
                .end_line()
        else
            .accept(":")
            body = .parse_block()
        mk("FnDef", tok.line, [S(name), L(params), ret, L(body), B(is_async), L(decorators), B(is_method),
                               L(tparams)])

    # extern ["lib" | "file.c" | "sip"] fn name(x int, s str) i32 [= c_symbol]
    fn parse_extern() N
        tok = .advance()
        lib = if .at("STRING") then .advance().value else ""
        .expect("fn", "'fn' after extern")
        name = .expect("NAME", "function name").value
        if .at("[") then .error("an extern fn cannot have type parameters")
        .expect("(")
        params = .parse_params(")")
        .expect(")")
        ret = if .at("=", "NEWLINE") then NONE() else .parse_type()
        csym = name
        if .accept("=")
            csym = .expect("NAME", "the name of the C function (extern fn has no body)").value
        elif .at(":") or (.at("NEWLINE") and .peek(1).kind == "INDENT")
            .error("an extern fn has no body: it is implemented in C")
        .end_line()
        ctypes: [N] = []
        out: [N] = []
        for p in params
            if p.kids[3].s != "" or not is_none(p.kids[2])
                .error_at("extern fn parameters cannot have defaults or *", tok)
            c, t = ctype_of(p.kids[1])
            ctypes.append(c)
            out.append(mk("Param", p.line, [p.kids[0], t, p.kids[2], p.kids[3]]))
        cret = NONE()
        if not is_none(ret)
            cret, ret = ctype_of(ret)
        fn_ = mk("FnDef", tok.line, [S(name), L(out), ret, L([]), B(false), L([]), B(false), L([])])
        fn_.kids.append(mk("extern", tok.line, [S(lib), S(csym), L(ctypes), cret]))
        fn_

    fn parse_tparams() [N]
        out: [N] = []
        if not .accept("[") then return out
        while not .at("]")
            tok = .expect("NAME", "type parameter name")
            bound = if .accept(":") then .parse_type() else NONE()
            out.append(mk("TParamDef", tok.line, [S(tok.value), bound]))
            if not .accept(",") then break
        .expect("]")
        if not out then .error("empty type parameter list")
        out

    fn parse_interface() N
        tok = .advance()  # `interface`
        name = .expect("NAME", "interface name").value
        methods: [N] = []
        .accept(":")
        if .at("NEWLINE") and .peek(1).kind == "INDENT"
            .advance()
            .advance()
            while not .at("DEDENT", "EOF")
                if .accept("NEWLINE") then continue
                mtok = .expect("fn", "'fn' (an interface lists method signatures)")
                mname = .expect("NAME", "method name").value
                if .at("[") then .error("interface methods cannot have type parameters")
                .expect("(")
                params = .parse_params(")")
                .expect(")")
                if params and params[0].kids[0].s == "self" then params = params[1:]
                .accept("->")
                ret = if .at("NEWLINE") then NONE() else .parse_type()
                if .at("=", ":") then .error("interface methods have no body: write only the signature")
                .end_line()
                methods.append(mk("FnDef", mtok.line, [S(mname), L(params), ret, L([]), B(false), L([]), B(true),
                                                       L([])]))
            .accept("DEDENT")
        else
            .end_line()
        if not methods then .error_at("an interface needs at least one method: fn name(...) Type", tok)
        mk("Interface", tok.line, [S(name), L(methods)])

    fn parse_params(closing str) [N]
        params: [N] = []
        while not .at(closing)
            tok = .peek()
            star = ""
            if .at("*", "**") then star = .advance().kind
            name = .expect("NAME", "parameter name").value
            .accept(":")
            typ = NONE()
            if not .at(",", closing, "=") then typ = .parse_type()
            default = if .accept("=") then .parse_expr() else NONE()
            params.append(mk("Param", tok.line, [S(name), typ, default, S(star)]))
            if not .accept(",") then break
        params

    fn at_type_start() bool = .at("[", "{{", "(", "nil", "fn", "NAME")

    fn parse_type() N
        tok = .peek()
        t = NONE()
        if .accept("[")
            t = mk("TList", tok.line, [.parse_type()])
            .expect("]")
        elif .accept("{{")
            key = .parse_type()
            if .accept("}}")
                t = mk("TSet", tok.line, [key])
            else
                .expect(":")
                value = .parse_type()
                .expect("}}")
                t = mk("TDict", tok.line, [key, value])
        elif .accept("(")
            items: [N] = []
            while not .at(")")
                items.append(.parse_type())
                if not .accept(",") then break
            .expect(")")
            t = mk("TTuple", tok.line, [L(items)])
        elif .accept("nil")
            t = mk("TName", tok.line, [S("None"), L([])])
        elif .accept("fn")
            .expect("(")
            params: [N] = []
            while not .at(")")
                params.append(.parse_type())
                if not .accept(",") then break
            .expect(")")
            ret = if .at_type_start() then .parse_type() else NONE()
            t = mk("TFn", tok.line, [L(params), ret])
        elif .at("NAME")
            name = .parse_dotted()
            args: [N] = []
            if .accept("[")
                while not .at("]")
                    args.append(.parse_type())
                    if not .accept(",") then break
                .expect("]")
            t = mk("TName", tok.line, [S(name), L(args)])
        else
            .error_at("expected type, got {describe(tok)}", tok)
        while .accept("?")
            t = mk("TOptional", tok.line, [t])
        t

    fn parse_type_def() N
        tok = .advance()  # `type`
        name = .expect("NAME", "type name").value
        tparams = .parse_tparams()
        if .accept("=")
            variants: [N] = []
            .accept("|")
            while true
                vtok = .expect("NAME", "variant name")
                fields: [N] = []
                if .accept("(")
                    fields = .parse_params(")")
                    .expect(")")
                variants.append(mk("Variant", vtok.line, [S(vtok.value), L(fields)]))
                if not .accept("|") then break
            vfields, vmethods = .parse_type_body()
            if vfields then .error("a sum type cannot have fields: put them in the variants")
            return mk("SumType", tok.line, [S(name), L(variants), L(vmethods), L(tparams)])
        fields: [N] = []
        if .accept("(")
            fields = .parse_params(")")
            .expect(")")
        more, methods = .parse_type_body()
        fields.extend(more)
        mk("Record", tok.line, [S(name), L(fields), L(methods), L(tparams)])

    fn parse_type_body() ([N], [N])
        .accept(":")
        fields: [N] = []
        methods: [N] = []
        if not (.at("NEWLINE") and .peek(1).kind == "INDENT")
            .end_line()
            return (fields, methods)
        .advance()
        .advance()
        while not .at("DEDENT", "EOF")
            if .accept("NEWLINE") then continue
            if .at("@")
                decorators: [N] = []
                while .accept("@")
                    decorators.append(.parse_expr())
                    .end_line()
                methods.append(.parse_fn(decorators, true))
            elif .at("fn", "async")
                methods.append(.parse_fn([], true))
            elif .at("NAME")
                ftok = .advance()
                .accept(":")
                typ = if .at("=", "NEWLINE") then NONE() else .parse_type()
                default = if .accept("=") then .parse_expr() else NONE()
                fields.append(mk("Param", ftok.line, [S(ftok.value), typ, default, S("")]))
                .end_line()
            else
                .error("expected field or method, got {describe(.peek())}")
        .accept("DEDENT")
        (fields, methods)

    # ---------- выражения ----------

    fn parse_expr() N
        if .at("if") then return .parse_if_expr()
        if .at("fn") and .peek(1).kind == "(" then return .parse_lambda()
        .parse_or()

    fn parse_if_expr() N
        tok = .advance()  # if или elif
        cond = .parse_or()
        .expect("then", "'then' (an if-expression is written 'if c then a else b')")
        then_ = .parse_expr()
        other = NONE()
        if .at("elif")
            other = .parse_if_expr()
        else
            .expect("else", "'else' (an if-expression needs an else branch)")
            other = .parse_expr()
        mk("IfExpr", tok.line, [cond, then_, other])

    fn parse_lambda() N
        tok = .advance()  # fn
        .expect("(")
        names: [N] = []
        types: [N] = []
        while not .at(")")
            names.append(S(.expect("NAME", "parameter name").value))
            .accept(":")
            types.append(if .at(",", ")") then NONE() else .parse_type())
            if not .accept(",") then break
        .expect(")")
        if .at("NEWLINE") and .peek(1).kind == "INDENT"  # многострочная лямбда
            return mk("Lambda", tok.line, [L(names), NONE(), L(types), L(.parse_block())])
        .expect("=", "'=' before the body of fn(...), or the body on the next lines")
        mk("Lambda", tok.line, [L(names), .parse_expr(), L(types), NONE()])

    fn binop(tok lexer.Token, left N, right N) N = mk("BinOp", tok.line, [S(tok.kind), left, right])

    fn parse_or() N
        left = .parse_and()
        while .at("or")
            tok = .advance()
            left = .binop(tok, left, .parse_and())
        left

    fn parse_and() N
        left = .parse_not()
        while .at("and")
            tok = .advance()
            left = .binop(tok, left, .parse_not())
        left

    fn parse_not() N
        if .at("not")
            tok = .advance()
            return mk("Unary", tok.line, [S("not"), .parse_not()])
        .parse_cmp()

    fn parse_cmp() N
        tok = .peek()
        left = .parse_bitor()
        ops: [N] = []
        while true
            op = ""
            if .peek().kind in CMP_OPS
                op = .advance().kind
            elif .at("in")
                .advance()
                op = "in"
            elif .at("not") and .peek(1).kind == "in"
                .advance()
                .advance()
                op = "not in"
            elif .at("is")
                .advance()
                op = if .accept("not") then "is not" else "is"
            else
                break
            ops.append(T([S(op), .parse_bitor()]))
        if ops then mk("Compare", tok.line, [left, L(ops)]) else left

    fn parse_bitor() N
        left = .parse_bitxor()
        while .at("|")
            tok = .advance()
            left = .binop(tok, left, .parse_bitxor())
        left

    fn parse_bitxor() N
        left = .parse_bitand()
        while .at("^")
            tok = .advance()
            left = .binop(tok, left, .parse_bitand())
        left

    fn parse_bitand() N
        left = .parse_range()
        while .at("&")
            tok = .advance()
            left = .binop(tok, left, .parse_range())
        left

    fn parse_range() N
        lo = .parse_add()
        if .at("..")
            tok = .advance()
            return mk("Range", tok.line, [lo, .parse_add()])
        lo

    fn parse_add() N
        left = .parse_mul()
        while .at("+", "-")
            tok = .advance()
            left = .binop(tok, left, .parse_mul())
        left

    fn parse_mul() N
        left = .parse_unary()
        while .at("*", "/", "//", "%")
            tok = .advance()
            left = .binop(tok, left, .parse_unary())
        left

    fn parse_unary() N
        if .at("-", "+", "~")
            tok = .advance()
            return mk("Unary", tok.line, [S(tok.kind), .parse_unary()])
        .parse_power()

    fn parse_power() N
        base = .parse_await()
        if .at("**")
            tok = .advance()
            return mk("BinOp", tok.line, [S("**"), base, .parse_unary()])
        base

    fn parse_await() N
        if .at("await")
            tok = .advance()
            return mk("Await", tok.line, [.parse_postfix()])
        .parse_postfix()

    fn parse_postfix() N
        e = .parse_primary()
        while true
            tok = .peek()
            if tok.kind == "."
                .advance()
                name = .advance()
                if not is_word(name) then .error_at("expected attribute name, got {describe(name)}", name)
                e = mk("Attr", tok.line, [e, S(name.value)])
            elif tok.kind == "("
                e = .parse_call(e)
            elif tok.kind == "["
                e = .parse_index(e)
            else
                return e
        e

    fn parse_call(func N) N
        tok = .advance()  # (
        args: [N] = []
        kwargs: [N] = []
        while not .at(")")
            if .at("*", "**")
                star = .advance().kind
                args.append(mk("Starred", tok.line, [.parse_expr(), B(star == "**")]))
            elif is_word(.peek()) and (.peek(1).kind == ":" or .peek(1).kind == "=")
                name = .advance().value
                .advance()
                kwargs.append(T([S(name), .parse_expr()]))
            else
                a = .parse_expr()
                if .at("for") and not args and not kwargs then a = .parse_comp("gen", a, NONE())
                args.append(a)
            if not .accept(",") then break
        .expect(")", "')' or ','")
        mk("Call", tok.line, [func, L(args), L(kwargs)])

    fn part() N = if .at(":", "]") then NONE() else .parse_expr()

    fn parse_index(obj N) N
        tok = .advance()  # [
        lo = .part()
        index = lo
        if .at(":")
            .advance()
            hi = .part()
            step = if .accept(":") then .part() else NONE()
            index = mk("Slice", tok.line, [lo, hi, step])
        elif .at(",")
            items = [lo]
            while .accept(",")
                if .at("]") then break
                items.append(.parse_expr())
            index = mk("TupleLit", tok.line, [L(items)])
        .expect("]")
        mk("Index", tok.line, [obj, index])

    fn parse_primary() N
        tok = .peek()
        k = tok.kind
        if k == "NUMBER"
            .advance()
            return mk("Num", tok.line, [S(tok.value)])
        if k == "STRING" then return .parse_string()
        if k == "NAME"
            if tok.value == "lambda" then .error("'lambda' is not Sip: {HINTS['lambda']}")
            .advance()
            return mk("Name", tok.line, [S(tok.value)])
        if k == "nil" or k == "true" or k == "false"
            .advance()
            v = if k == "nil" then "None" elif k == "true" then "True" else "False"
            return mk("Const", tok.line, [S(v)])
        if k == "."
            .advance()
            name = .advance()
            if not is_word(name) then .error_at("expected field name after '.'", name)
            return mk("SelfAttr", tok.line, [S(name.value)])
        if k == "(" then return .parse_paren()
        if k == "[" then return .parse_list()
        if k == "{{" then return .parse_brace()
        if k == "fn" and .peek(1).kind == "(" then return .parse_lambda()
        if k == "if" then return .parse_if_expr()
        .error_at("expected expression, got {describe(tok)}", tok)
        NONE()

    # элемент списка или множества: выражение или `*spread`
    fn parse_item() N
        if .at("*")
            tok = .advance()
            return mk("Starred", tok.line, [.parse_expr(), B(false)])
        .parse_expr()

    fn parse_paren() N
        tok = .advance()  # (
        if .accept(")") then return mk("TupleLit", tok.line, [L([])])
        first = .parse_item()
        if .at("for")
            comp = .parse_comp("gen", first, NONE())
            .expect(")")
            return comp
        if .at(",")
            items = [first]
            while .accept(",")
                if .at(")") then break
                items.append(.parse_item())
            .expect(")")
            return mk("TupleLit", tok.line, [L(items)])
        .expect(")")
        first

    fn parse_list() N
        tok = .advance()  # [
        if .accept("]") then return mk("ListLit", tok.line, [L([])])
        first = .parse_item()
        if .at("for")
            comp = .parse_comp("list", first, NONE())
            .expect("]")
            return comp
        items = [first]
        while .accept(",")
            if .at("]") then break
            items.append(.parse_item())
        .expect("]", "']' or ','")
        mk("ListLit", tok.line, [L(items)])

    # ключ словаря; голое имя `{host: 1}` означает строку "host" (второе значение — голое ли)
    fn parse_dict_key() (N, bool)
        tok = .peek()
        if is_word(tok) and .peek(1).kind == ":"
            .advance()
            return (S(tok.value), true)
        (.parse_expr(), false)

    fn parse_brace() N
        tok = .advance()  # {
        if .accept("}}") then return mk("DictLit", tok.line, [L([])])
        pairs: [N] = []
        if .at("**")
            .advance()
            pairs.append(T([NONE(), .parse_expr()]))
        else
            key, bare = .parse_dict_key()
            if not .at(":")
                # множество
                first = if bare then mk("Name", tok.line, [key]) else key
                if .at("for")
                    comp = .parse_comp("set", first, NONE())
                    .expect("}}")
                    return comp
                items = [first]
                while .accept(",")
                    if .at("}}") then break
                    items.append(.parse_item())
                .expect("}}")
                return mk("SetLit", tok.line, [L(items)])
            .advance()  # :
            value = .parse_expr()
            if .at("for")
                # в генераторе словаря голое имя — это переменная, а не строка
                comp = .parse_comp("dict", value, if bare then mk("Name", tok.line, [key]) else key)
                .expect("}}")
                return comp
            pairs.append(T([if bare then bare_str(key, tok.line) else key, value]))
        while .accept(",")
            if .at("}}") then break
            if .accept("**")
                pairs.append(T([NONE(), .parse_expr()]))
                continue
            key, bare = .parse_dict_key()
            .expect(":", "':' in dict literal")
            pairs.append(T([if bare then bare_str(key, tok.line) else key, .parse_expr()]))
        .expect("}}", "'}}' or ','")
        mk("DictLit", tok.line, [L(pairs)])

    fn parse_comp(kind str, elt N, key N) N
        line = .peek().line
        clauses: [N] = []
        while .at("for")
            ftok = .advance()
            target = .parse_target()
            .expect("in")
            it = .parse_or()
            conds: [N] = []
            while .at("if")
                .advance()
                conds.append(.parse_or())
            clauses.append(mk("CompFor", ftok.line, [target, it, L(conds)]))
        mk("Comp", line, [S(kind), elt, key, L(clauses)])

    fn parse_string() N
        tok = .advance()
        quote = tok.quote
        raw = tok.value
        parts: [N] = []
        buf = ""
        i = 0
        n = len(raw)
        while i < n
            c = raw[i]
            if c == "\\" and i + 1 < n
                buf = buf + raw[i:i + 2]
                i += 2
                continue
            if c == "{{"
                if raw[i + 1:i + 2] == "{{"
                    buf = buf + "{{"
                    i += 2
                    continue
                j = .match_brace(raw, i, tok)
                inner = raw[i + 1:j]
                if inner.strip() == "" then .error_at("empty {{}} in string: write {{{{}}}} for literal braces", tok)
                sp_parts = split_spec(inner)
                if buf != ""
                    parts.append(S(buf))
                    buf = ""
                sp = if len(sp_parts) > 1 then S(sp_parts[1]) else NONE()
                parts.append(mk("Interp", tok.line, [.sub_expr(sp_parts[0], tok), sp]))
                i = j + 1
                continue
            if c == "}}"
                if raw[i + 1:i + 2] == "}}"
                    buf = buf + "}}"
                    i += 2
                    continue
                .error_at("single '}}' in string: write '}}}}'", tok)
            buf = buf + c
            i += 1
        if buf != "" then parts.append(S(buf))
        mk("Str", tok.line, [L(parts), S(quote)])

    fn match_brace(raw str, i int, tok lexer.Token) int
        depth = 0
        j = i
        while j < len(raw)
            c = raw[j]
            if c == "\"" or c == "'"
                k = j + 1
                while k < len(raw) and raw[k] != c
                    k += if raw[k] == "\\" then 2 else 1
                j = k
            elif c == "{{"
                depth += 1
            elif c == "}}"
                depth -= 1
                if depth == 0 then return j
            j += 1
        .error_at("unclosed '{{' in string", tok)
        0

    fn sub_expr(text str, tok lexer.Token) N
        toks: [lexer.Token] = []
        try
            toks = lexer.tokenize("(" + text + ")")
        catch lexer.LexError e
            fail ParseError("in string: {e.msg}", tok.line, tok.col)
        for t in toks
            t.line = tok.line
            t.col = tok.col
        sub = Parser(toks, 0)
        expr = sub.parse_expr()
        if not sub.at("NEWLINE", "EOF") then sub.error("bad expression inside {{}} in string")
        expr

    # ---------- образцы ----------

    fn parse_pattern() N
        tok = .peek()
        p = .parse_pattern_atom()
        if .at("|")
            alts = [p]
            while .accept("|")
                alts.append(.parse_pattern_atom())
            p = mk("POr", tok.line, [L(alts)])
        p

    fn parse_pattern_atom() N
        tok = .peek()
        k = tok.kind
        if k == "NAME"
            if tok.value == "True" or tok.value == "False" or tok.value == "None"
                .advance()
                return mk("PLit", tok.line, [mk("Const", tok.line, [S(tok.value)])])
            name = .parse_dotted()
            if .accept("(")
                args: [N] = []
                kwargs: [N] = []
                while not .at(")")
                    if .at("NAME") and (.peek(1).kind == "=" or .peek(1).kind == ":")
                        kname = .advance().value
                        .advance()
                        kwargs.append(T([S(kname), .parse_pattern()]))
                    else
                        args.append(.parse_pattern())
                    if not .accept(",") then break
                .expect(")")
                return mk("PClass", tok.line, [S(name), L(args), L(kwargs)])
            if name == "_" then return mk("PWild", tok.line, [])
            if name.find(".") >= 0 then return mk("PValue", tok.line, [S(name)])
            if is_upper_start(name) then return mk("PClass", tok.line, [S(name), L([]), L([])])  # вариант без полей
            return mk("PCapture", tok.line, [S(name)])
        if k == "NUMBER" or k == "STRING" or k == "nil" or k == "true" or k == "false"
            expr = .parse_primary()
            if expr.kind == "Str"
                for p in expr.kids[0].kids
                    if p.kind == "Interp" then .error_at("string pattern cannot contain {{interpolation}}", tok)
            return mk("PLit", tok.line, [expr])
        if k == "-"
            .advance()
            num = .expect("NUMBER", "number")
            return mk("PLit", tok.line, [mk("Unary", tok.line, [S("-"), mk("Num", tok.line, [S(num.value)])])])
        if k == "*"
            .advance()
            return mk("PStar", tok.line, [S(.expect("NAME").value)])
        if k == "(" or k == "["
            close = if k == "(" then ")" else "]"
            .advance()
            items: [N] = []
            trailing = false
            while not .at(close)
                items.append(.parse_pattern())
                trailing = .accept(",")
                if not trailing then break
            .expect(close)
            if k == "("
                if len(items) == 1 and not trailing then return items[0]
                return mk("PTuple", tok.line, [L(items)])
            return mk("PList", tok.line, [L(items)])
        .error_at("expected pattern, got {describe(tok)}", tok)
        NONE()

fn bare_str(name N, line int) N = mk("Str", line, [L([name]), S("\"")])

fn ctype_of(t N) (N, N)
    if t.kind == "TName" and not t.kids[1].kids
        nm = t.kids[0].s
        c = C_INTS.get(nm)
        if c != nil then return (S(c), mk("TName", t.line, [S("int"), L([])]))
        f = C_FLOATS.get(nm)
        if f != nil then return (S(f), mk("TName", t.line, [S("float"), L([])]))
    (NONE(), t)

fn parse(src str) N
    p = Parser(lexer.tokenize(src), 0)
    p.parse_module()

# дерево одной строкой на узел, с отступами: Вид@строка, листья — s<длина>:текст, _, T/F
fn dump_into(n N, depth int, out [str])
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
            dump_into(c, depth + 1, out)
    else
        out.append(pad + "{k}@{n.line}")
        for c in n.kids
            dump_into(c, depth + 1, out)

fn dump(n N) str
    out: [str] = []
    dump_into(n, 0, out)
    "\n".join(out) + "\n"

fn main(path str)
    try
        write("/dev/stdout", dump(parse(read(path))))
    catch lexer.LexError e
        print "{path}:{e.line}" + (if e.col != 0 then ":{e.col}" else "") + ": {e.msg}"
        exit(1)
    catch ParseError e
        print "{path}:{e.line}" + (if e.col != 0 then ":{e.col}" else "") + ": {e.msg}"
        exit(1)
