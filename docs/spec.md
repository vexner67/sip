# Sip: справочник языка

Sip транслируется в Python 3.12. Всё, что не описано здесь, работает как в Python: встроенные функции, генераторы списков, исключения, импорт модулей.

Короткая версия для ИИ-модели лежит в [prompt.md](prompt.md). Её кладут в контекст, чтобы модель писала на Sip.

## Функции

```
fn add(a int, b int) int = a + b          # тело в одно выражение

fn describe(x int) str                    # блочное тело
    kind = if x > 0 then "positive" else "non-positive"
    "{x} is {kind}"                       # последнее выражение — результат

double = fn(x) = x * 2                    # анонимная функция
```

- Типы пишутся после имени без двоеточия и необязательны. Без типа и со значением по умолчанию: `fn f(n = 10)`.
- Тип результата ставится после `)`. `return` нужен только для раннего выхода.
- `@cache` и любые декораторы Python ставятся перед `fn`.

## Типы в аннотациях

| Sip | Python |
|---|---|
| `int str float bool` | то же |
| `[int]` | `list[int]` |
| `{str: float}` | `dict[str, float]` |
| `(str, int)` | `tuple[str, int]` |
| `str?` | `str \| None` |

## Управление

```
if x > 10
    print "big"
elif x > 3
    print "medium"
else
    print "small"

if done then return result                 # тело в одну строку
for i in 1..10: print i
y = if a then 1 elif b then 2 else 3       # if-выражение (else обязателен)
```

- `1..10` — **включительный** диапазон, от 1 до 10.
- `for k, v in d` по словарю перебирает пары ключ-значение.
- `while`, `break`, `continue`, `pass`, `with x as y` — как в Python.

## Значения и операторы

- `nil`, `true`, `false`. Питоновские `None`, `True`, `False` тоже работают.
- `/` для двух целых делит нацело: `7 / 2 == 3`. Для дробей обычное деление.
- `{host: "x", port: 80}` — ключ без кавычек становится строкой. В генераторе `{k: v for k in xs}` ключ — переменная.
- `a | b` объединяет словари.
- Строки интерполируются: `"Hi {name}, {x:.2f}"`. Внутри `{}` можно писать любое выражение. `{{` и `}}` дают буквальные скобки.
- `print a, b` можно писать без скобок.
- Именованные аргументы: `f(x, timeout: 5)` или `f(x, timeout=5)`.

## Записи

```
type User(name str, age int = 0)
    fn is_adult() bool = .age >= 18        # .age — это self.age
    fn greet() str = "Hello, {.name}!"

u = User("Ann", 30)
```

Запись превращается в `dataclass`: есть конструктор, сравнение и `repr`. Поля можно описать и блоком:

```
type Bag
    items [int] = []                      # изменяемое значение по умолчанию безопасно
    fn add(x int)
        .items.append(x)
```

## Типы-суммы и match

```
type Shape = Circle(r float) | Rect(w float, h float) | Empty

fn area(s Shape) float = match s
    Circle(r) -> pi * r * r
    Rect(w, h) if w == h -> w * w
    Rect(w, h) -> w * h
    Empty -> 0.0
```

- Варианты наследуются от общего класса: `isinstance(x, Shape)` работает.
- Вариант без полей создаётся вызовом `Empty()`, а в образце пишется просто `Empty`.
- Образцы: литералы, `_`, кортежи `(0, _)`, списки `[first, *rest]`, альтернативы `A | B`.

## Ошибки

```
fn load(path str) dict
    try json.parse(read(path))
    catch NotFound -> {}
    catch ParseError e -> fail "bad config: {e}"

try
    risky()
catch e                                   # ловит всё
    print "error: {e}"
```

- `fail "сообщение"` бросает `Error`. `fail SomeError(...)` бросает указанное исключение.
- Встроенные виды ошибок: `NotFound` (файла нет), `ParseError` (плохой JSON или число), `HttpError` (ответ HTTP 4xx/5xx), а также любые исключения Python.

## Асинхронность

```
async fn fetch_all(urls [str]) [int] = [r.status for r in await all(http.get(u) for u in urls)]
```

`await all(...)` ждёт все задачи одновременно и возвращает список результатов. HTTP-запросы при этом идут параллельно.

## Программа и командная строка

Если в файле есть `fn main`, её параметры становятся аргументами командной строки:

```
fn main(name str, times = 1, loud = false)
```

```
sip run greet.sip Ann --times 3 --loud
```

Параметр без значения по умолчанию становится позиционным аргументом. Со значением — флагом. Тип `[str]` принимает несколько значений. `async fn main` тоже работает.

## Стандартная библиотека

| имя | что делает |
|---|---|
| `read(path)`, `write(path, text)` | читает и пишет текстовый файл |
| `count(xs)` | счётчик элементов, `.top(n)` — самые частые |
| `avg(xs)` | среднее |
| `json.parse(s)`, `json.stringify(x)`, `json.read(path)`, `json.write(path, x)` | JSON |
| `csv.read(path)`, `csv.write(path, rows)` | CSV, строки с доступом `row.column` |
| `http.get(url, timeout:, headers:)`, `http.post(url, json:)` | ответ с `.status`, `.ok`, `.text`, `.json()` |
| `pi`, `cache` | `math.pi`, `functools.cache` |

Методы для списков, строк и других коллекций:

| метод | пример |
|---|---|
| `count()` | `words.count().top(3)` |
| `group_by(key)` | `rows.group_by("dept")`, `xs.group_by(fn(x) = x % 2)` |
| `map(f)`, `filter(f)` | `xs.map(fn(x) = x * 2)` |
| `sort_by(f)` | `users.sort_by(fn(u) = u.age)` |
| `sum()`, `avg()`, `first()` | `prices.sum()` |
| `join(sep)` | `[1, 2].join(", ")`; питоновский `", ".join(xs)` тоже работает |

Если у вашего типа есть свой метод с таким же именем, вызывается он.

## Привычки из Python, которые не ломают код

Парсер принимает их молча, чтобы модель не тратила попытку на исправление:

- двоеточие в конце заголовка: `if x:`, `fn f():`;
- `x: int` в параметрах и `-> int` перед типом результата;
- явный `self` в методах;
- `True`, `False`, `None`, `else if`.

Для `def`, `class`, `lambda`, `except` и `raise` компилятор выдаёт короткую подсказку, как написать это на Sip.

## Ошибки компилятора и выполнения

Обе вида ошибок занимают одну строку с позицией в `.sip`-файле:

```
prog.sip:3:12: expected 'then' (an if-expression is written 'if c then a else b'), got number 1
prog.sip:3: IndexError: list index out of range
    fn get(i int) int = xs[i]
```

Полный Python-трейсбек показывается с `SIP_TRACE=1`.
