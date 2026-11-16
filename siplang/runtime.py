"""Рантайм Sip: встроенные функции, доступные каждой программе.

Сгенерированный код делает `from siplang.runtime import *` (публичные имена
из __all__) и `import siplang.runtime as _sip` (служебные помощники).
"""

from __future__ import annotations

import asyncio
import builtins
import csv as _csv
import dataclasses
import functools
import inspect
import json as _json
import math
import os
import sys
import urllib.error
import urllib.request
from collections import Counter
from dataclasses import dataclass, field  # noqa: F401  (используются сгенерированным кодом)

__all__ = [
    "read", "write", "count", "avg", "http", "csv", "json", "cache", "pi",
    "NotFound", "ParseError", "HttpError", "Error", "Tally", "Row", "Response",
]

pi = math.pi
cache = functools.cache
NotFound = FileNotFoundError
ParseError = ValueError  # json.JSONDecodeError наследуется от ValueError


class Error(Exception):
    """Ошибка, которую бросает `fail "сообщение"`."""


class HttpError(Exception):
    def __init__(self, status: int, url: str, body: bytes = b""):
        super().__init__(f"HTTP {status} for {url}")
        self.status = status
        self.url = url
        self.body = body


# ---------- помощники для сгенерированного кода ----------

def fail(value):
    return value if isinstance(value, BaseException) else Error(str(value))


def div(a, b):
    """`/` в Sip: целые делятся нацело, остальное как обычно."""
    if isinstance(a, int) and isinstance(b, int):
        return a // b
    return a / b


def pairs(x):
    """`for k, v in d` перебирает пары, если d — словарь."""
    return x.items() if isinstance(x, dict) else x


async def gather(*items):
    """`await all(xs)`: ждёт все ожидания одновременно и возвращает список результатов."""
    if len(items) == 1 and not inspect.isawaitable(items[0]):
        items = tuple(items[0])
    return list(await asyncio.gather(*items))


def _arg_type(hint):
    return hint if hint in (int, float, str) else str


def _parse_bool(text: str) -> bool:
    if text.lower() in ("1", "true", "yes", "y", "on"):
        return True
    if text.lower() in ("0", "false", "no", "n", "off"):
        return False
    raise ValueError(f"not a boolean: {text}")


def run_main(fn, argv: list[str] | None = None):
    """Запускает `fn main(...)`: параметры становятся аргументами командной строки.

    Параметр без значения по умолчанию становится позиционным аргументом,
    со значением по умолчанию — флагом `--name`. Тип берётся из аннотации
    или из значения по умолчанию.
    """
    import argparse
    import typing

    sig = inspect.signature(fn)
    if not sig.parameters:
        result = fn()
    else:
        try:
            hints = typing.get_type_hints(fn)
        except Exception:
            hints = {}
        prog = os.path.basename(sys.argv[0]) if sys.argv and sys.argv[0] else "sip"
        parser = argparse.ArgumentParser(prog=prog)
        for name, p in sig.parameters.items():
            has_default = p.default is not inspect.Parameter.empty
            hint = hints.get(name)
            if hint is None and has_default and p.default is not None:
                hint = type(p.default)
            if typing.get_origin(hint) is list:
                args = typing.get_args(hint) or (str,)
                kw = dict(nargs="*" if has_default else "+", type=_arg_type(args[0]))
            elif hint is bool:
                kw = dict(action=argparse.BooleanOptionalAction) if has_default else dict(type=_parse_bool)
            else:
                kw = dict(type=_arg_type(hint))
            if has_default:
                parser.add_argument("--" + name.replace("_", "-"), dest=name, default=p.default, **kw)
            else:
                parser.add_argument(name, **kw)
        ns = parser.parse_args(sys.argv[1:] if argv is None else argv)
        result = fn(**vars(ns))
    if inspect.iscoroutine(result):
        asyncio.run(result)


# ---------- файлы ----------

def read(path, encoding: str = "utf-8") -> str:
    with open(path, encoding=encoding) as f:
        return f.read()


def write(path, text: str, encoding: str = "utf-8") -> None:
    with open(path, "w", encoding=encoding) as f:
        f.write(text)


# ---------- коллекции ----------

class Tally(Counter):
    """Счётчик с методом top(n): самые частые элементы."""

    def top(self, n: int | None = None):
        return self.most_common(n)


def count(xs) -> Tally:
    return Tally(xs)


def avg(xs):
    xs = list(xs)
    if not xs:
        raise ValueError("avg() of empty sequence")
    return builtins.sum(xs) / len(xs)


# Методы-расширения для встроенных типов. Для своих типов вызывается
# собственный метод объекта, если он есть.
_EXT_TYPES = {
    list, tuple, set, frozenset, dict, str, bytes, range, map, filter, zip, enumerate,
    type(x for x in ()), type({}.keys()), type({}.values()), type({}.items()), type(reversed([])),
}


def _ext(impl):
    name = impl.__name__.removeprefix("m_")

    @functools.wraps(impl)
    def call(obj, *args, **kwargs):
        if type(obj) not in _EXT_TYPES:
            method = getattr(obj, name, None)
            if method is not None:
                return method(*args, **kwargs)
        return impl(obj, *args, **kwargs)

    return call


@_ext
def m_count(obj, *args, **kwargs):
    if args or kwargs:
        return obj.count(*args, **kwargs)  # list.count(x), str.count(sub)
    return Tally(obj)


@_ext
def m_top(obj, n=None):
    return Tally(obj).top(n)


@_ext
def m_group_by(obj, key):
    get = key if callable(key) else (lambda item: item[key])
    groups: dict = {}
    for item in obj:
        groups.setdefault(get(item), []).append(item)
    return groups


@_ext
def m_avg(obj):
    return avg(obj)


@_ext
def m_sum(obj, start=0):
    return builtins.sum(obj, start)


@_ext
def m_map(obj, fn):
    return [fn(x) for x in obj]


@_ext
def m_filter(obj, fn):
    return [x for x in obj if fn(x)]


@_ext
def m_sort_by(obj, key, reverse: bool = False):
    return sorted(obj, key=key, reverse=reverse)


@_ext
def m_first(obj, default=None):
    return next(iter(obj), default)


@_ext
def m_join(obj, sep=""):
    if isinstance(obj, str):
        return obj.join(sep)  # Python-стиль: ", ".join(items)
    return sep.join(str(x) for x in obj)


# ---------- CSV и JSON ----------

class Row(dict):
    """Строка CSV: доступ к колонкам и как row["name"], и как row.name."""

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(f"row has no column {name!r}") from None


class _Csv:
    def read(self, path, delimiter: str = ",", encoding: str = "utf-8") -> list[Row]:
        with open(path, newline="", encoding=encoding) as f:
            return [Row(r) for r in _csv.DictReader(f, delimiter=delimiter)]

    def write(self, path, rows, delimiter: str = ",", encoding: str = "utf-8") -> None:
        rows = list(rows)
        with open(path, "w", newline="", encoding=encoding) as f:
            if not rows:
                return
            w = _csv.DictWriter(f, fieldnames=list(rows[0]), delimiter=delimiter)
            w.writeheader()
            w.writerows(rows)


def _to_json(o):
    if dataclasses.is_dataclass(o) and not isinstance(o, type):
        return dataclasses.asdict(o)
    if isinstance(o, (set, frozenset, tuple)):
        return list(o)
    raise TypeError(f"cannot convert {type(o).__name__} to JSON")


class _Json:
    def parse(self, text):
        return _json.loads(text)

    def stringify(self, value, indent: int | None = None) -> str:
        return _json.dumps(value, indent=indent, ensure_ascii=False, default=_to_json)

    def read(self, path):
        return self.parse(read(path))

    def write(self, path, value, indent: int | None = 2) -> None:
        write(path, self.stringify(value, indent))


csv = _Csv()
json = _Json()


# ---------- HTTP ----------

class Response:
    def __init__(self, status: int, body: bytes, headers: dict, url: str):
        self.status = status
        self.body = body
        self.headers = headers
        self.url = url

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    @property
    def text(self) -> str:
        return self.body.decode("utf-8", errors="replace")

    def json(self):
        return _json.loads(self.body)

    def __repr__(self) -> str:
        return f"<Response {self.status} {self.url}>"


def _request(method, url, body, headers, timeout) -> Response:
    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return Response(r.status, r.read(), dict(r.headers), url)
    except urllib.error.HTTPError as e:
        raise HttpError(e.code, url, e.read()) from None


class Pending:
    """HTTP-запрос, который выполняется при первом обращении.

    Обычный код просто пользуется результатом: `http.get(u).json()`.
    `await` выполняет запрос в отдельном потоке, поэтому `await all(...)`
    скачивает страницы параллельно.
    """

    def __init__(self, *args):
        self._args = args
        self._response = None

    def _get(self) -> Response:
        if self._response is None:
            self._response = _request(*self._args)
        return self._response

    async def _aget(self) -> Response:
        if self._response is None:
            self._response = await asyncio.to_thread(_request, *self._args)
        return self._response

    def __await__(self):
        return self._aget().__await__()

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return getattr(self._get(), name)

    def __repr__(self) -> str:
        return repr(self._get())


class _Http:
    def get(self, url: str, timeout: float = 30, headers: dict | None = None) -> Pending:
        return Pending("GET", url, None, headers, timeout)

    def post(self, url: str, json=None, data=None, timeout: float = 30, headers: dict | None = None) -> Pending:
        headers = dict(headers or {})
        if json is not None:
            body = _json.dumps(json, default=_to_json).encode()
            headers.setdefault("Content-Type", "application/json")
        elif isinstance(data, str):
            body = data.encode()
        else:
            body = data
        return Pending("POST", url, body, headers, timeout)


http = _Http()
