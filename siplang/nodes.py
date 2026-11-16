"""Узлы синтаксического дерева Sip."""

from dataclasses import dataclass, field


@dataclass
class Node:
    line: int = field(default=0, kw_only=True, compare=False)


# ---------- типы ----------

@dataclass
class TName(Node):
    name: str
    args: list = field(default_factory=list)


@dataclass
class TList(Node):
    item: Node


@dataclass
class TDict(Node):
    key: Node
    value: Node


@dataclass
class TSet(Node):
    item: Node


@dataclass
class TTuple(Node):
    items: list


@dataclass
class TOptional(Node):
    inner: Node


@dataclass
class TFn(Node):
    """Тип функции: `fn(int, str) bool`."""
    params: list
    ret: Node | None


# ---------- выражения ----------

@dataclass
class Name(Node):
    id: str


@dataclass
class SelfAttr(Node):
    """`.name` внутри метода, то есть self.name."""
    name: str


@dataclass
class Num(Node):
    text: str


@dataclass
class Interp(Node):
    expr: Node
    spec: str | None


@dataclass
class Str(Node):
    parts: list  # str (литерал) или Interp
    quote: str = '"'


@dataclass
class Const(Node):
    value: str  # "None", "True", "False"


@dataclass
class Attr(Node):
    obj: Node
    name: str


@dataclass
class Index(Node):
    obj: Node
    index: Node


@dataclass
class Slice(Node):
    lo: Node | None
    hi: Node | None
    step: Node | None


@dataclass
class Starred(Node):
    value: Node
    double: bool = False


@dataclass
class Call(Node):
    func: Node
    args: list
    kwargs: list  # [(имя, выражение)]


@dataclass
class BinOp(Node):
    op: str
    left: Node
    right: Node


@dataclass
class Compare(Node):
    left: Node
    ops: list  # [(оператор, выражение)]


@dataclass
class Unary(Node):
    op: str
    operand: Node


@dataclass
class IfExpr(Node):
    cond: Node
    then: Node
    other: Node


@dataclass
class Range(Node):
    """Включительный диапазон `lo..hi`."""
    lo: Node
    hi: Node


@dataclass
class ListLit(Node):
    items: list


@dataclass
class TupleLit(Node):
    items: list


@dataclass
class DictLit(Node):
    pairs: list  # [(ключ | None для **spread, значение)]


@dataclass
class SetLit(Node):
    items: list


@dataclass
class CompFor(Node):
    target: Node
    iter: Node
    conds: list


@dataclass
class Comp(Node):
    kind: str  # list, gen, dict, set
    elt: Node
    key: Node | None
    clauses: list


@dataclass
class Lambda(Node):
    params: list  # имена
    body: Node
    types: list = field(default_factory=list)  # тип или None для каждого параметра
    block: list | None = None  # тело из нескольких строк (тогда body = None)


@dataclass
class Await(Node):
    value: Node


# ---------- образцы для match ----------

@dataclass
class PWild(Node):
    pass


@dataclass
class PCapture(Node):
    name: str


@dataclass
class PLit(Node):
    expr: Node


@dataclass
class PValue(Node):
    dotted: str


@dataclass
class PClass(Node):
    name: str
    args: list
    kwargs: list


@dataclass
class PTuple(Node):
    items: list


@dataclass
class PList(Node):
    items: list


@dataclass
class PStar(Node):
    name: str


@dataclass
class POr(Node):
    alts: list


# ---------- инструкции ----------

@dataclass
class ExprStmt(Node):
    expr: Node


@dataclass
class Assign(Node):
    targets: list
    value: Node


@dataclass
class AnnAssign(Node):
    """`x: [int] = []` — присваивание с явным типом."""
    target: Node
    type: Node
    value: Node


@dataclass
class AugAssign(Node):
    target: Node
    op: str
    value: Node


@dataclass
class If(Node):
    branches: list  # [(условие, тело)]
    orelse: list | None


@dataclass
class For(Node):
    target: Node
    iter: Node
    body: list


@dataclass
class While(Node):
    cond: Node
    body: list


@dataclass
class Return(Node):
    value: Node | None


@dataclass
class Break(Node):
    pass


@dataclass
class Continue(Node):
    pass


@dataclass
class Pass(Node):
    pass


@dataclass
class Fail(Node):
    value: Node


@dataclass
class Assert(Node):
    cond: Node
    msg: Node | None


@dataclass
class Handler(Node):
    kind: str | None
    name: str | None
    body: list


@dataclass
class Try(Node):
    body: list
    handlers: list


@dataclass
class Arm(Node):
    pattern: Node
    guard: Node | None
    body: list


@dataclass
class Match(Node):
    subject: Node
    arms: list


@dataclass
class With(Node):
    items: list  # [(выражение, имя | None)]
    body: list


@dataclass
class Import(Node):
    module: str
    alias: str | None


@dataclass
class FromImport(Node):
    module: str
    names: list  # [(имя, псевдоним | None)]


@dataclass
class Param(Node):
    name: str
    type: Node | None
    default: Node | None
    star: str = ""


@dataclass
class FnDef(Node):
    name: str
    params: list
    ret: Node | None
    body: list
    is_async: bool = False
    decorators: list = field(default_factory=list)
    is_method: bool = False
    tparams: list = field(default_factory=list)  # [TParamDef]: fn first[T](xs [T]) T


@dataclass
class Record(Node):
    name: str
    fields: list  # [Param]
    methods: list
    tparams: list = field(default_factory=list)


@dataclass
class Variant(Node):
    name: str
    fields: list


@dataclass
class SumType(Node):
    name: str
    variants: list
    methods: list
    tparams: list = field(default_factory=list)


@dataclass
class TParamDef(Node):
    """Параметр типа: T или T: Shape (T должен реализовать интерфейс Shape)."""
    name: str
    bound: Node | None = None


@dataclass
class Interface(Node):
    """interface Shape: методы без тел; тип подходит, если у него есть такие методы."""
    name: str
    methods: list  # [FnDef] с пустым телом


@dataclass
class Module(Node):
    body: list
