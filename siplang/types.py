"""Система типов нативного компилятора Sip.

Все типы известны на этапе компиляции. Внутри функций типы выводятся
унификацией (TVar), поэтому писать их нужно только в сигнатурах и полях.
"""

from __future__ import annotations

from dataclasses import dataclass, field


class Type:
    def __repr__(self) -> str:
        return show(self)


@dataclass(eq=False, repr=False)
class Prim(Type):
    name: str


INT = Prim("int")
FLOAT = Prim("float")
BOOL = Prim("bool")
STR = Prim("str")
UNIT = Prim("unit")
RANGE = Prim("range")
NUMERIC = (INT, FLOAT)


@dataclass(eq=False, repr=False)
class ListT(Type):
    elem: Type


@dataclass(eq=False, repr=False)
class DictT(Type):
    key: Type
    val: Type


@dataclass(eq=False, repr=False)
class TupleT(Type):
    items: list


@dataclass(eq=False, repr=False)
class RecordT(Type):
    name: str
    fields: dict = field(default_factory=dict)    # имя -> тип, в порядке объявления
    defaults: dict = field(default_factory=dict)  # имя -> узел выражения
    methods: dict = field(default_factory=dict)   # имя -> FnInfo


@dataclass(eq=False, repr=False)
class SumT(Type):
    name: str
    variants: dict = field(default_factory=dict)  # имя варианта -> [(поле, тип)]
    methods: dict = field(default_factory=dict)

    def index(self, variant: str) -> int:
        return list(self.variants).index(variant)


@dataclass(eq=False, repr=False)
class OptT(Type):
    """`T?`: значение или nil. Для ссылочных типов nil — это NULL."""
    inner: Type


@dataclass(eq=False, repr=False)
class FnT(Type):
    """Функция как значение: замыкание {указатель на код, окружение}."""
    params: list
    ret: Type


def opt(t: Type) -> Type:
    """T -> T?, без вложенных T??."""
    return t if isinstance(prune(t), OptT) else OptT(t)


def is_ref(t: Type) -> bool:
    """Тип хранится как указатель, и nil для него — NULL."""
    return isinstance(prune(t), (ListT, DictT, RecordT, SumT))


_tv_counter = [0]


@dataclass(eq=False, repr=False)
class TVar(Type):
    id: int = field(default_factory=lambda: _next_tv())
    ref: Type | None = None


def _next_tv() -> int:
    _tv_counter[0] += 1
    return _tv_counter[0]


def prune(t: Type) -> Type:
    while isinstance(t, TVar) and t.ref is not None:
        t = t.ref
    return t


def deep(t: Type) -> Type:
    """Полностью раскрывает связанные переменные типа."""
    t = prune(t)
    if isinstance(t, ListT):
        return ListT(deep(t.elem))
    if isinstance(t, DictT):
        return DictT(deep(t.key), deep(t.val))
    if isinstance(t, TupleT):
        return TupleT([deep(i) for i in t.items])
    if isinstance(t, OptT):
        return OptT(deep(t.inner))
    if isinstance(t, FnT):
        return FnT([deep(p) for p in t.params], deep(t.ret))
    return t


def is_resolved(t: Type) -> bool:
    t = prune(t)
    if isinstance(t, TVar):
        return False
    if isinstance(t, ListT):
        return is_resolved(t.elem)
    if isinstance(t, DictT):
        return is_resolved(t.key) and is_resolved(t.val)
    if isinstance(t, TupleT):
        return all(is_resolved(i) for i in t.items)
    if isinstance(t, OptT):
        return is_resolved(t.inner)
    if isinstance(t, FnT):
        return all(is_resolved(p) for p in t.params) and is_resolved(t.ret)
    return True


def show(t: Type) -> str:
    t = prune(t)
    if isinstance(t, Prim):
        return t.name
    if isinstance(t, ListT):
        return f"[{show(t.elem)}]"
    if isinstance(t, DictT):
        return f"{{{show(t.key)}: {show(t.val)}}}"
    if isinstance(t, TupleT):
        return "(" + ", ".join(show(i) for i in t.items) + ")"
    if isinstance(t, (RecordT, SumT)):
        return t.name
    if isinstance(t, OptT):
        return show(t.inner) + "?"
    if isinstance(t, FnT):
        ret = "" if prune(t.ret) is UNIT else " " + show(t.ret)
        return "fn(" + ", ".join(show(p) for p in t.params) + ")" + ret
    if isinstance(t, TVar):
        return "?"
    return type(t).__name__


def key(t: Type) -> str:
    """Имя типа в C. Одинаковые типы дают одинаковые имена."""
    t = prune(t)
    if isinstance(t, Prim):
        return t.name
    if isinstance(t, ListT):
        return f"L_{key(t.elem)}"
    if isinstance(t, DictT):
        return f"D_{key(t.key)}__{key(t.val)}"
    if isinstance(t, TupleT):
        return f"T{len(t.items)}_" + "_".join(key(i) for i in t.items)
    if isinstance(t, RecordT):
        return f"R_{t.name}"
    if isinstance(t, SumT):
        return f"S_{t.name}"
    if isinstance(t, OptT):
        return f"O_{key(t.inner)}"
    if isinstance(t, FnT):
        return f"F{len(t.params)}_" + "_".join(key(p) for p in t.params) + f"__{key(t.ret)}"
    raise TypeError(f"unresolved type {show(t)}")


def ctype(t: Type) -> str:
    t = prune(t)
    if t is INT:
        return "int64_t"
    if t is FLOAT:
        return "double"
    if t is BOOL:
        return "bool"
    if t is STR:
        return "sip_str"
    if t is UNIT:
        return "void"
    if t is RANGE:
        return "sip_range"
    if isinstance(t, OptT) and is_ref(t.inner):
        return ctype(t.inner)
    return key(t)


def same(a: Type, b: Type) -> bool:
    a, b = prune(a), prune(b)
    if a is b:
        return True
    if type(a) is not type(b):
        return False
    if isinstance(a, ListT):
        return same(a.elem, b.elem)
    if isinstance(a, DictT):
        return same(a.key, b.key) and same(a.val, b.val)
    if isinstance(a, TupleT):
        return len(a.items) == len(b.items) and all(same(x, y) for x, y in zip(a.items, b.items))
    if isinstance(a, OptT):
        return same(a.inner, b.inner)
    if isinstance(a, FnT):
        return (len(a.params) == len(b.params) and all(same(x, y) for x, y in zip(a.params, b.params))
                and same(a.ret, b.ret))
    return False


def hashable(t: Type) -> bool:
    t = prune(t)
    if t in (INT, FLOAT, BOOL, STR):
        return True
    if isinstance(t, TupleT):
        return all(hashable(i) for i in t.items)
    return False


def comparable(t: Type) -> bool:
    """Можно ли сравнивать на < и сортировать."""
    t = prune(t)
    if t in (INT, FLOAT, BOOL, STR):
        return True
    if isinstance(t, TupleT):
        return all(comparable(i) for i in t.items)
    if isinstance(t, ListT):
        return comparable(t.elem)
    return False


def truthy_ok(t: Type) -> bool:
    t = prune(t)
    return t in (INT, FLOAT, BOOL, STR, RANGE) or isinstance(t, (ListT, DictT, OptT))
