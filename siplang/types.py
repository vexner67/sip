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
PTR = Prim("ptr")  # указатель C (FFI): непрозрачный, nil — NULL
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


class TParam(Type):
    """Параметр типа T в fn f[T] или type Box[T].

    Тело обобщённой функции проверяется один раз: T — отдельный тип, который
    совпадает только сам с собой. Код C генерируется для каждого набора
    настоящих типов: на это время SUBST подставляет вместо T настоящий тип.
    needs — что тело делает со значениями T (<, +, ключ словаря); это проверяется
    в месте вызова.
    """

    def __init__(self, name: str, bound=None):
        self.name = name
        self.bound = bound   # IfaceT или None
        self.needs: dict = {}  # "ord" | "hash" | "num" | "add" -> True


SUBST: dict = {}  # TParam -> тип, пока генерируется экземпляр обобщённой функции


class Generic(Type):
    """Запись или тип-сумма; у обобщённых (Box[T]) есть params и args.

    Box[int] — отдельный объект с base = Box и args = [int]; его поля
    вычисляются подстановкой при первом обращении. У самого Box args = params.
    """

    _members = ""  # имя словаря, который зависит от параметров: fields или variants

    def __init__(self, name: str):
        self.name = name
        self.methods: dict = {}  # имя -> FnInfo
        self.params: list = []
        self.args: list = []
        self.base = self
        self._lazy = None
        setattr(self, "_" + self._members, {})

    def __getattr__(self, name):
        # атрибуты, которые добавили базовому типу после создания экземпляра (cdefaults и т. п.)
        base = self.__dict__.get("base")
        if base is None or base is self or name.startswith("__"):
            raise AttributeError(name)
        return getattr(base, name)

    def _get(self):
        if self._lazy is not None:
            m, self._lazy = self._lazy, None
            setattr(self, "_" + self._members, self._substituted(m))
        return getattr(self, "_" + self._members)


class RecordT(Generic):
    _members = "fields"

    def __init__(self, name: str, fields: dict | None = None):
        super().__init__(name)
        self.defaults: dict = {}  # имя -> узел выражения
        if fields:
            self._fields.update(fields)

    @property
    def fields(self) -> dict:  # имя -> тип, в порядке объявления
        return self._get()

    def _substituted(self, m):
        return {n: subst(t, m) for n, t in self.base._fields.items()}


class SumT(Generic):
    _members = "variants"

    @property
    def variants(self) -> dict:  # имя варианта -> [(поле, тип)]
        return self._get()

    def _substituted(self, m):
        return {v: [(n, subst(t, m)) for n, t in fs] for v, fs in self.base._variants.items()}

    def index(self, variant: str) -> int:
        return list(self.variants).index(variant)


def instantiate(base: Generic, args: list) -> Generic:
    """Box[args]: новый объект с теми же методами и подставленными полями."""
    if not base.params:
        return base
    inst = object.__new__(type(base))
    inst.__dict__.update(base.__dict__)
    inst.base = base
    inst.args = list(args)
    inst._lazy = dict(zip(base.params, inst.args))
    return inst


class IfaceT(Type):
    """interface Shape: значение любого типа, у которого есть нужные методы."""

    def __init__(self, name: str):
        self.name = name
        self.methods: dict = {}  # имя -> ([(имя параметра, тип)], тип результата)


@dataclass(eq=False, repr=False)
class SetT(Type):
    """Множество: внутри — упорядоченный словарь {T: bool}, поэтому порядок — порядок вставки."""
    elem: Type


@dataclass(eq=False, repr=False)
class OptT(Type):
    """`T?`: значение или nil. Для ссылочных типов nil — это NULL."""
    inner: Type


@dataclass(eq=False, repr=False)
class FnT(Type):
    """Функция как значение: замыкание {указатель на код, окружение}."""
    params: list
    ret: Type


@dataclass(eq=False, repr=False)
class TaskT(Type):
    """Результат вызова async fn: задача, которая выполнится при await."""
    ret: Type


def opt(t: Type) -> Type:
    """T -> T?, без вложенных T??."""
    return t if isinstance(prune(t), OptT) else OptT(t)


def subst(t: Type, m: dict) -> Type:
    """Тип, в котором параметры из m заменены их значениями."""
    while isinstance(t, TVar) and t.ref is not None:
        t = t.ref
    if isinstance(t, TParam) and t in m:  # раньше SUBST: поля Box[U] — это U, даже внутри экземпляра с T
        return m[t]
    t = prune(t)
    if isinstance(t, TParam):
        return t
    if isinstance(t, ListT):
        return ListT(subst(t.elem, m))
    if isinstance(t, DictT):
        return DictT(subst(t.key, m), subst(t.val, m))
    if isinstance(t, TupleT):
        return TupleT([subst(i, m) for i in t.items])
    if isinstance(t, OptT):
        return OptT(subst(t.inner, m))
    if isinstance(t, SetT):
        return SetT(subst(t.elem, m))
    if isinstance(t, FnT):
        return FnT([subst(p, m) for p in t.params], subst(t.ret, m))
    if isinstance(t, TaskT):
        return TaskT(subst(t.ret, m))
    if isinstance(t, Generic) and t.args:
        return instantiate(t.base, [subst(a, m) for a in t.args])
    return t


def is_ref(t: Type) -> bool:
    """Тип хранится как указатель, и nil для него — NULL."""
    t = prune(t)
    return t is PTR or isinstance(t, (ListT, DictT, RecordT, SumT, SetT))


def no_ptrs(t: Type) -> bool:
    """В значении типа нет указателей: его память сборщик мусора не сканирует."""
    t = prune(t)
    if isinstance(t, Prim):
        return t is not STR and t is not PTR  # ptr может указывать на память сборщика
    if isinstance(t, TupleT):
        return all(no_ptrs(x) for x in t.items)
    if isinstance(t, OptT):
        return not is_ref(t.inner) and no_ptrs(t.inner)
    return False


_tv_counter = [0]


@dataclass(eq=False, repr=False)
class TVar(Type):
    id: int = field(default_factory=lambda: _next_tv())
    ref: Type | None = None


def _next_tv() -> int:
    _tv_counter[0] += 1
    return _tv_counter[0]


def prune(t: Type) -> Type:
    while True:
        if isinstance(t, TVar):
            if t.ref is None:
                return t
            t = t.ref
        elif SUBST and isinstance(t, TParam) and t in SUBST:
            t = SUBST[t]
        else:
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
    if isinstance(t, SetT):
        return SetT(deep(t.elem))
    if isinstance(t, FnT):
        return FnT([deep(p) for p in t.params], deep(t.ret))
    if isinstance(t, TaskT):
        return TaskT(deep(t.ret))
    if isinstance(t, Generic) and t.args:
        return instantiate(t.base, [deep(a) for a in t.args])
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
    if isinstance(t, SetT):
        return is_resolved(t.elem)
    if isinstance(t, FnT):
        return all(is_resolved(p) for p in t.params) and is_resolved(t.ret)
    if isinstance(t, TaskT):
        return is_resolved(t.ret)
    if isinstance(t, Generic):
        return all(is_resolved(a) for a in t.args)
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
    if isinstance(t, Generic):
        dn = getattr(t, "display", t.name)
        return dn + ("[" + ", ".join(show(a) for a in t.args) + "]" if t.args else "")
    if isinstance(t, (TParam, IfaceT)):
        return getattr(t, "display", t.name)
    if isinstance(t, OptT):
        return show(t.inner) + "?"
    if isinstance(t, SetT):
        return "{" + show(t.elem) + "}"
    if isinstance(t, FnT):
        ret = "" if prune(t.ret) is UNIT else " " + show(t.ret)
        return "fn(" + ", ".join(show(p) for p in t.params) + ")" + ret
    if isinstance(t, TaskT):
        return f"Task[{show(t.ret)}]"
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
    if isinstance(t, Generic):
        args = "__" + "_".join(key(a) for a in t.args) if t.args else ""
        return ("R_" if isinstance(t, RecordT) else "S_") + t.name + args
    if isinstance(t, IfaceT):
        return f"I_{t.name}"
    if isinstance(t, OptT):
        return f"O_{key(t.inner)}"
    if isinstance(t, SetT):
        return f"Z_{key(t.elem)}"
    if isinstance(t, FnT):
        return f"F{len(t.params)}_" + "_".join(key(p) for p in t.params) + f"__{key(t.ret)}"
    if isinstance(t, TaskT):
        return f"K_{key(t.ret)}"
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
    if t is PTR:
        return "void *"
    if isinstance(t, OptT) and is_ref(t.inner):
        return ctype(t.inner)
    if isinstance(t, SetT):
        return key(DictT(t.elem, BOOL))
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
    if isinstance(a, SetT):
        return same(a.elem, b.elem)
    if isinstance(a, FnT):
        return (len(a.params) == len(b.params) and all(same(x, y) for x, y in zip(a.params, b.params))
                and same(a.ret, b.ret))
    if isinstance(a, TaskT):
        return same(a.ret, b.ret)
    if isinstance(a, Generic):
        return a.base is b.base and all(same(x, y) for x, y in zip(a.args, b.args))
    return False


def hashable(t: Type) -> bool:
    t = prune(t)
    if isinstance(t, TParam):
        t.needs["hash"] = True  # проверится в месте вызова
        return True
    if t in (INT, FLOAT, BOOL, STR):
        return True
    if isinstance(t, TupleT):
        return all(hashable(i) for i in t.items)
    return False


def comparable(t: Type) -> bool:
    """Можно ли сравнивать на < и сортировать."""
    t = prune(t)
    if isinstance(t, TParam):
        t.needs["ord"] = True
        return True
    if t in (INT, FLOAT, BOOL, STR):
        return True
    if isinstance(t, TupleT):
        return all(comparable(i) for i in t.items)
    if isinstance(t, ListT):
        return comparable(t.elem)
    return False


def truthy_ok(t: Type) -> bool:
    t = prune(t)
    return t in (INT, FLOAT, BOOL, STR, RANGE) or isinstance(t, (ListT, DictT, OptT, SetT))
