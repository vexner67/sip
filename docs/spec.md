# Sip: справочник языка

Sip выглядит как Python, но статически типизирован и компилируется в машинный код: компилятор выводит типы, генерирует C и собирает его через `clang -O3`. Вывод программ совпадает с Python: те же правила деления, форматирования чисел, порядка ключей в словарях.

Короткая версия для ИИ-модели лежит в [prompt.md](prompt.md). Её кладут в контекст, чтобы модель писала на Sip.

## Функции

```
fn add(a int, b int) int = a + b          # тело в одно выражение

fn describe(x int) str                    # блочное тело
    kind = if x > 0 then "positive" else "non-positive"
    "{x} is {kind}"                       # последнее выражение — результат
```

- Типы пишутся после имени без двоеточия. Тип параметра обязателен, если нет значения по умолчанию: `fn f(n = 10)` даёт `n int`.
- Значение по умолчанию должно быть литералом.
- Тип результата ставится после `)`. Если его нет, он выводится из тела. `return` нужен только для раннего выхода.
- `@cache` запоминает результаты функции.
- Функции можно вызывать до их объявления.

## Типы

| Sip | что это | в C |
|---|---|---|
| `int` | 64-битное целое; выход за пределы бросает `OverflowError` | `int64_t` |
| `float` | число двойной точности | `double` |
| `bool` | `true`, `false` | `bool` |
| `str` | неизменяемая строка UTF-8; `len` и индексы считают байты | указатель и длина |
| `[int]` | список | динамический массив |
| `{str: float}` | словарь с порядком вставки | хэш-таблица |
| `(str, int)` | кортеж | структура по значению |
| `int?` | значение или `nil` | `{has, v}`; для списков, словарей и записей — `NULL` |
| `fn(int) str` | функция-значение | замыкание: код и окружение |

Типы переменных выводятся. Пустой коллекции нужен тип: `xs: [int] = []`. Одна переменная имеет один тип на всю функцию.

`int` автоматически превращается во `float`, где ожидается `float`: `fn half(x float)` можно вызвать как `half(3)`.

## nil и необязательные значения

`T?` — значение типа `T` или `nil`:

```
fn find(xs [int], x int) int?
    for i in 0..len(xs) - 1
        if xs[i] == x then return i
    nil

type Node(v int, next Node? = nil)

i = find(xs, 7)
if i == nil then print "нет"            # также: i is nil, i != nil, i is not nil
print name or "anon"                    # nil (или пустое значение) заменяется вторым
d.get("key")                            # int?: nil, если ключа нет
xs.first()                              # первый элемент или nil
```

- `T` подставляется туда, где ждут `T?`, сам: `x: int? = 5`.
- `T?` там, где нужен `T` (`i + 1`, `node.next.v`), проверяется при выполнении. Если там `nil`, будет ошибка `NilError: value is nil` со строкой исходника.
- `x = nil` без типа: тип уточнит следующее присваивание (`x = 5` делает `x` типом `int?`).
- В `match` есть образец `nil`: `nil -> "none"`.
- `print` и строки показывают `nil` как `None`, как Python.

## Лямбды и функции-значения

```
xs.map(fn(x) = x * 2)
xs.filter(fn(x) = x > 0)
users.sort_by(fn(u) = u.age, reverse: true)
sorted(words, key: fn(w) = len(w))
max(words, key: fn(w) = len(w))
xs.group_by(fn(x) = x % 2)              # {1: [...], 0: [...]}

fn apply(f fn(int) int, x int) int = f(x)
fn adder(n int) fn(int) int = fn(x) = x + n
inc = fn(x int) = x + 1                 # без контекста тип параметра пишется явно
print apply(adder(3), 4), xs.map(sq)    # обычная функция тоже значение
```

- Тип параметров берётся из контекста (`map`, параметр `fn(...)`, тип результата функции) или пишется явно.
- Если после `fn(...)` строка кончается, тело лямбды — блок на следующих строках, со своими переменными и `return`. Так можно писать и внутри скобок:

```
ys = xs.map(fn(x)
    y = x * 2
    if y > 10 then return 0
    y + 1
)
sorted(words, key: fn(w)
    n = len(w)
    (-n, w)
)
```

- Лямбда видит переменные вокруг. Локальные переменные копируются в момент создания лямбды, глобальные читаются в момент вызова.
- Встроенные функции значениями не бывают: вместо `xs.map(str)` пишется `xs.map(fn(x) = str(x))`.
- Компилятор встраивает вызов лямбды: `xs.map(fn(x) = x * 2)` работает так же быстро, как `[x * 2 for x in xs]`.

Внутри функции можно объявить обычную функцию блоком, она тоже замыкание:

```
fn count_paths(n int) int
    seen: {int: int} = {}
    fn go(i int) int                       # видит n и seen, может вызывать себя
        if i >= n then return 1
        if i in seen then return seen[i]
        seen[i] = go(i + 1) + go(i + 2)
        seen[i]
    go(0)
```

Присвоить внешней переменной вложенная функция или лямбда не может (`n += 1` — ошибка), но менять список, словарь или запись по ссылке может.

Лишние аргументы собирает `*args` (в список), а лишние именованные — `**kwargs` (в словарь). Тип пишется для одного элемента:

```
fn total(*xs int) int = sum(xs)
fn tag(name str, **attrs str) str = "<{name} {attrs}>"
total(1, 2, 3), total(*nums), tag("a", href: "/")
```

Параметры после `*args` передаются только по имени: `fn fmt(*parts str, sep = " ")`.


## Управление

```
if x > 10
    print "big"
elif x > 3
    print "medium"
else
    print "small"

if done then return result                 # тело в одну строку
y = if a then 1 elif b then 2 else 3       # if-выражение (else обязателен)
print if i % 3 == 0 then "Fizz" else i     # ветки str и другого типа дают str
```

- `1..10` — **включительный** диапазон, от 1 до 10. `x in 1..10` проверяет попадание.
- `for k, v in d` по словарю перебирает пары ключ-значение; `for k in d` — ключи.
- `for c in s` по строке перебирает байты.
- `while`, `break`, `continue`, `pass` — как в Python.

## Значения и операторы

- `true`, `false`. Питоновские `True`, `False` тоже работают.
- `/` для двух целых делит нацело с округлением вниз: `7 / 2 == 3`, `-7 / 2 == -4`. `%` следует правилам Python. Деление на ноль бросает `ZeroDivisionError`.
- Целые не переполняются молча. Если результат `+ - * ** // -x abs sum` не помещается в 64 бита, бросается `OverflowError: integer overflow`. То же бывает, когда `int(x)`, `round`, `math.floor` получают слишком большое число с плавающей точкой или когда `int("...")` получает слишком длинную строку цифр. `int(nan)` бросает `ValueError`. У `float` поведение IEEE: `1e308 * 10 == inf`.
- `{host: "x", port: "80"}` — ключ без кавычек становится строкой. В генераторе `{k: v for k in xs}` ключ — переменная.
- `a | b` объединяет словари, `a + b` склеивает списки и строки, `[0] * n` повторяет.
- Строки интерполируются: `"Hi {name}, {x:.2f}, {n:>5}, {k:03d}"`. Внутри `{}` можно писать любое выражение. `{{` и `}}` дают буквальные скобки.
- `print a, b` можно писать без скобок.
- Именованные аргументы: `f(x, reverse: true)` или `f(x, reverse=true)`.
- `==` сравнивает списки, словари, кортежи и записи по содержимому. `<` работает для чисел, строк, кортежей и списков.

## Множества

```
seen = {1, 2, 3}                           # тип {int}; пустое — set() или s: {str} = set()
seen.add(4)
print 2 in seen, len(seen)
a | b, a & b, a - b, a ^ b                 # объединение, пересечение, разность, симметрическая
a <= b                                     # подмножество
uniq = {w.lower() for w in words}
```

Методы: `add remove discard clear copy update union intersection difference issubset`. Множество перебирается в порядке добавления (в Python порядок не определён). У словарей для удаления есть `d.pop(k)` и `d.clear()`, для слияния — `d.update(other)`.

## Записи

```
type User(name str, age int = 0)
    fn is_adult() bool = .age >= 18        # .age — это self.age
    fn greet() str = "Hello, {.name}!"

u = User("Ann", 30)
print u                                    # User(name='Ann', age=30)
```

Записи передаются по ссылке: функция, которая меняет поле, меняет его у вызывающего. Поля можно описать и блоком:

```
type Bag
    items [int] = []                      # у каждого Bag() свой список
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

- Вариант без полей — это значение: `Empty` (можно и `Empty()`).
- Типы могут быть рекурсивными: `type Tree = Leaf | Node(l Tree, v int, r Tree)`.
- Образцы: литералы, `_`, имя (связывает значение), кортежи `(0, _)`, списки `[first, *rest]`, альтернативы `"a" | "b"`, записи `User(name, _)`.

## Дженерики

Параметры типа пишутся в квадратных скобках после имени функции или типа. При вызове они выводятся из аргументов:

```
fn first[T](xs [T]) T = xs[0]
fn pair[A, B](a A, b B) (B, A) = (b, a)

type Box[T](v T)
    fn get() T = .v
    fn map[U](f fn(T) U) Box[U] = Box(f(.v))   # у метода могут быть свои параметры

type Tree[T] = Leaf | Node(l Tree[T], v T, r Tree[T])

print first(["a", "b"]), Box(41).map(fn(x) = x + 1).get()
t: Tree[int] = Leaf                         # в аннотации параметры указываются: Tree[int]
st = Stack[int]()                           # или явно при вызове, если вывести не из чего
```

- Тело обобщённой функции проверяется один раз. Со значениями `T` можно делать то, что умеет любой тип: присваивать, сравнивать на `==`, печатать, класть в списки.
- Остальные операции (`<`, `sorted`, `min`, `+`, `-`, `sum`, ключ словаря) тоже разрешены. Компилятор запоминает их и проверяет в месте вызова: `biggest([P(1)])` даёт ошибку `T = P does not support comparison with <, which the function uses`.
- Обе стороны `+`, `<` и т. п. должны быть одним параметром типа: `x + 1` для `x T` — ошибка.
- Для каждого набора типов генерируется отдельный код C, как в C++ и Rust. Поэтому `first([1])` так же быстр, как функция для `[int]`, а обобщённый код, который никто не вызвал, не попадает в программу.
- Обобщённую функцию нельзя передать как значение, оберните её: `xs.map(fn(x) = first(x))`. Вложенные функции не могут иметь своих параметров типа.

## Интерфейсы

Интерфейс перечисляет методы. Тип подходит, если у него есть такие методы с такими же типами; объявлять это не нужно.

```
interface Shape
    fn area() float
    fn name() str

type Circle(r float)
    fn area() float = pi * .r * .r
    fn name() str = "circle"

type Rect(w float, h float)
    fn area() float = .w * .h
    fn name() str = "rect"

fn total[T: Shape](xs [T]) float = sum(x.area() for x in xs)   # ограничение: T — это Shape

shapes: [Shape] = [Circle(1.0), Rect(2.0, 3.0)]   # разные типы в одном списке
for s in shapes
    print s.name(), s.area()
print total([Circle(1.0)]), total(shapes)
```

- `T: Shape` — статический вызов: для `total([Circle(...)])` генерируется код, который вызывает `Circle.area` напрямую.
- Значение типа `Shape` — это объект и таблица его методов. Вызов `s.area()` идёт через таблицу, как у интерфейсов Go. Запись превращается в `Shape` там, где ждут `Shape`: в аннотации, аргументе, `return`, `append`, литерале списка или словаря с известным типом.
- Интерфейс реализуют записи и типы-суммы, в том числе обобщённые (`Wrap[int]`). `==` у значений интерфейса сравнивает, тот же ли это объект; `print` печатает сам объект.
- Значение интерфейса может быть `nil`: `s: Shape? = nil`.

## Ошибки

```
fn parse_port(s str) int
    try int(s)
    catch ValueError -> 80

try
    risky()
catch NotFound
    print "no file"
catch e                                   # ловит всё, e — текст ошибки
    print "error: {e}"
```

- `fail "сообщение"` бросает `Error`, а `fail ValueError("сообщение")` бросает ошибку встроенного вида. `assert x > 0, "msg"` бросает `AssertionError`.
- Виды: `NotFound` (файла нет), `IOError`, `ParseError` (плохое число; ловится и как `ValueError`), `ValueError`, `IndexError`, `KeyError`, `ZeroDivisionError`, `OverflowError` (целое не помещается в 64 бита), `AssertionError`, `NilError` (`nil` там, где нужно значение), `HttpError` (ответ 4xx/5xx). `catch Exception` ловит всё.

### Типизированные ошибки

Ошибкой может быть значение записи или типа-суммы. `catch Тип e` ловит только его, а в `e` оказывается само значение со всеми полями:

```
type NotEnough(need int, have int)
type BankError = Frozen(why str) | Closed

fn withdraw(bal int, x int) int
    if x > bal then fail NotEnough(x, bal)
    if bal == 0 then fail Closed
    return bal - x

try
    withdraw(10, 50)
catch NotEnough e
    print "не хватает {e.need - e.have}"
catch Frozen e                            # один вариант суммы; e имеет тип BankError
    print e
catch BankError e                         # любой вариант
    print "bank: {e}"
```

- Ошибку из модуля ловят по полному имени: `catch bank.NotEnough e`.
- `catch e` и `catch Exception e` ловят и типизированные ошибки; в `e` тогда текст значения: `NotEnough(need=50, have=10)`.
- Если ошибку не поймали, печатается само значение: `prog.sip:5: NotEnough(need=50, have=10)`.
- Ошибка проходит через `await` и `all(...)` без изменений.
- Обобщённые типы (`Box[T]`) ловить пока нельзя.
- Непойманная ошибка печатает одну строку и строку исходника, код выхода 1:

```
prog.sip:3: IndexError: list index out of range
    fn get(i int) int = xs[i]
```

## Модули

```
import geo                                 # geo.sip рядом с этим файлом
import lib.strs as S                       # lib/strs.sip
from geo import Point, area as square

print geo.area(geo.Point(1, 2)), S.shout("hi")
```

- Модуль — это файл `.sip`. `import a.b` ищет `a/b.sip` сначала рядом с файлом, который импортирует, потом в зависимостях пакета, потом от корня пакета (папки с `sip.toml`). Имя модуля в коде — последняя часть: `import models.user` даёт `user.User`.
- Код верхнего уровня модуля выполняется один раз, до кода программы. `fn main` модуля не вызывается.
- Одинаковые имена в разных модулях не мешают друг другу. Циклический импорт — ошибка компиляции.
- Ошибки в модуле показывают его файл и строку: `lib/strs.sip:2: IndexError: ...`.

### Приватность

Имя, которое начинается с `_`, видно только внутри своего модуля. Слово `pub` не нужно: всё остальное открыто.

```
type Account(owner str, _balance int = 0)    # _balance меняют только методы и функции этого модуля
    fn deposit(n int)
        ._check(n)
        ._balance += n
    fn balance() int = ._balance
    fn _check(n int)
        if n <= 0 then fail "bad amount"

fn _helper() int = 42                       # не импортируется
```

Снаружи модуля `acct.Account("ann")` создаёт запись, а приватные поля получают значения по умолчанию. Писать `a._balance`, вызывать `a._check(1)`, передавать приватное поле в конструктор, связывать его в `match` и импортировать `_helper` нельзя. Каждая такая попытка — ошибка компиляции: `field '_balance' of Account is private to its module`.

### Пакеты

Пакет — папка с `sip.toml`. `sip init NAME` создаёт `NAME/sip.toml` и `NAME/main.sip`. В папке пакета `sip run` и `sip build` без имени файла собирают `main.sip`.

```toml
[package]
name = "app"

[deps]
textkit = { path = "../textkit" }                                     # папка рядом
colors = { git = "https://github.com/user/colors.git", rev = "v1.2.0" }  # тег или коммит
```

- `import textkit` загружает `textkit.sip` из корня зависимости, а `import textkit.fmt.pad` загружает `fmt/pad.sip`. У зависимости может быть свой `sip.toml` со своими зависимостями.
- git-зависимость клонируется один раз в `~/.cache/sip/pkgs/` и переключается на `rev`. `rev` обязателен, поэтому сборка воспроизводима.
- Модули разных пакетов с одинаковыми именами не конфликтуют: имена получают префикс пакета.

### Раздельная компиляция

Каждый модуль — отдельная единица компиляции C. Объектные файлы лежат в кэше по хэшу своего текста и собираются параллельно. После правки одного модуля clang пересобирает только его, и ещё те модули, которые используют из него обобщённые функции (их экземпляры генерируются у вызывающего). `sip build` пишет, сколько единиц собрано заново:

```
$ sip build main.sip
5 unit(s): 1 compiled, 4 cached
```

- Номера строк и имена в коде C модуля не зависят от других модулей, поэтому правка одного файла не меняет единицы остальных.
- Функции главного файла остаются `static`, и clang встраивает их как раньше. Функции модулей видны снаружи, поэтому между модулями clang встраивает только то, что в заголовках: обобщённые функции и методы коллекций. `sip build --whole` собирает программу одной единицей: clang встраивает всё, но пересобирает всё.
- `sip run` помнит файлы программы (модули и `sip.toml`) и их хэши. Если ни один не изменился, бинарник запускается из кэша без проверки типов.

Встроенные модули доступны и без `import`:

| модуль | содержимое |
|---|---|
| `math` | `sqrt floor ceil trunc log log2 log10 exp sin cos tan asin acos atan atan2 hypot pow isnan isinf gcd`, `pi e tau inf nan` |
| `random` | `random() randint(a, b) uniform(a, b) choice(xs) shuffle(xs) seed(n)` |
| `time` | `time() perf_counter() sleep(s)` |
| `json`, `csv`, `http` | ниже |

`math.floor`, `ceil` и `trunc` дают `int`. `math.sqrt(-1)` бросает `ValueError: math domain error`.

## JSON

JSON читается сразу в нужный тип. Тип берётся из контекста: из объявления переменной, типа результата функции или параметра.

```
type User(name str, age int, tags [str] = [], email str? = nil)

users: [User] = json.read("users.json")
fn load(path str) [User] = json.read(path)
conf: {str: int} = json.parse(text)

print json.stringify(users)                # одной строкой, как json.dumps
json.write("out.json", users)              # с отступом 2; indent: 4 — свой
```

- Запись — объект JSON. Лишние поля пропускаются. Если поля нет, берётся значение по умолчанию, для `T?` — `nil`, иначе это ошибка.
- Тип-сумма — объект с полем `"type"`: `{"type": "Circle", "r": 1.0}`.
- `T?` — `null`, кортеж и множество — массив, `{int: V}` — объект с ключами-числами.
- Плохие данные бросают `ParseError` с путём: `JSON $[0].age: expected int, got string (line 3, column 12)`.
- Без контекста `x = json.parse(s)` не скомпилируется: нужно написать тип.

## CSV

```
type Emp(name str, dept str, salary float, age int? = nil)

rows = csv.read("emp.csv")                 # [{str: str}]: строка — словарь по заголовку
emps: [Emp] = csv.read("emp.csv")          # колонки по именам полей, числа переводятся
cells: [[str]] = csv.parse(text, delimiter: ";")   # все строки, без заголовка
csv.write("out.csv", emps)                 # заголовок из полей; [[T]] и [(…)] — без заголовка
```

Пустая ячейка для `T?` — `nil`, для поля со значением по умолчанию — это значение. Кавычки и переводы строк внутри полей — как в модуле `csv` Python, строки записываются с `\r\n`. Ошибка выглядит так: `CSV line 2, column 'salary': invalid float: 'abc'`.

## HTTP

```
r = http.get(url, timeout: 5, headers: {"Authorization": "Bearer {token}"})
print r.status, r.ok, r.text, r.url, r.headers["content-type"]
user: User = r.json()
http.post(url, json: User("Ann", 30))      # тело — JSON с Content-Type: application/json
http.post(url, body: "raw text")
```

- Ответ имеет тип `Response`: `status int`, `ok bool`, `text str`, `url str` (после редиректов), `headers {str: str}` (имена в нижнем регистре).
- Ответ 4xx или 5xx бросает `HttpError: HTTP 404 for URL`, ошибка сети или таймаут — `IOError`.
- Таймаут по умолчанию 30 секунд. Работает через libcurl, она подключается, только если программа пользуется `http`.

## async

```
async fn status(url str) int = http.get(url).status

async fn main(urls str)
    codes = await all(status(u) for u in urls.split())    # запросы идут одновременно
    print codes
```

- Вызов `async fn` возвращает задачу `Task[T]` и ничего не выполняет. `await t` выполняет её и даёт `T`, повторный `await` отдаёт тот же результат.
- `await all(f(x) for x in xs)` выполняет элементы одновременно и возвращает список результатов в исходном порядке. Можно передать и список задач: `await all(tasks)`. Если `f` ничего не возвращает, результата нет.
- Первая ошибка (по порядку элементов) пробрасывается из `await all`, остальные задачи успевают завершиться.
- `await` пишется только внутри `async fn`. `async fn main` тоже можно.
- Задачи работают в потоках, но код Sip в каждый момент выполняет один поток, как в Python. Пока задача ждёт сеть или `time.sleep`, работают другие. Поэтому общие списки и словари менять из задач безопасно, а счёт на нескольких ядрах не ускоряется.

## with

```
type Timer(name str, t0 float = 0.0)
    fn enter() Timer
        .t0 = time.perf_counter()
        self
    fn exit()
        print "{.name}: {time.perf_counter() - .t0:.3f} s"

with Timer("load") as t
    data = read(path)
```

`with x as y` вызывает `x.enter()`, если такой метод есть, и кладёт результат в `y` (без `enter` в `y` попадает сам `x`). Когда блок кончается, вызывается `x.exit()`: и при обычном выходе, и при `return`, `break`, `continue` и ошибке (ошибка потом летит дальше). Можно перечислить несколько значений: `with a, b as c`.

## Программа и командная строка

Код верхнего уровня выполняется по порядку. Если в файле есть `fn main`, она вызывается после него, а её параметры становятся аргументами командной строки:

```
fn main(name str, times = 1, loud = false)
```

```
sip run greet.sip Ann --times 3 --loud
```

Параметр без значения по умолчанию — позиционный аргумент, со значением — флаг (`_` в имени становится `-`). `*files str` забирает все остальные позиционные аргументы. Для `bool` есть `--loud` и `--no-loud`. Флаг `email str? = nil` равен `nil`, если его не передали. Неверный аргумент даёт сообщение и код выхода 2.

## Встроенные функции

| имя | что делает |
|---|---|
| `print a, b` | печать через пробел |
| `len str int float bool abs round` | как в Python; `int("x")` бросает `ParseError` |
| `min max sum avg any all` | по списку, диапазону или генератору: `sum(x * x for x in xs)`; `min(a, b)`; `max(xs, key: f)` |
| `sorted(xs, key: f, reverse: true)`, `list(x)` | новый список |
| `count(xs)` | словарь `{элемент: сколько раз}` |
| `zip(a, b)`, `enumerate(xs)` | списки кортежей |
| `read(path)`, `write(path, text)`, `input(prompt)` | файлы и ввод |
| `exit(code)`, `pi` | выход, число π |

## Методы

| тип | методы |
|---|---|
| `str` | `lower upper strip lstrip rstrip split splitlines find count replace startswith endswith isdigit isalpha isspace join` |
| список | `append pop insert extend clear sort reverse copy index count join sum avg top map filter sort_by group_by first` |
| словарь | `get keys values items copy top pop update clear` |
| множество | `add remove discard clear copy update union intersection difference issubset` |

`xs.sort(key: f, reverse: true)` сортирует на месте, `xs.sort_by(f)` возвращает новый список. Сортировка устойчивая, ключ считается один раз на элемент.

`xs.count()` без аргумента — словарь частот, `.top(n)` — `n` самых частых пар `(ключ, число)`. `xs.count(x)` — сколько раз встречается `x`. `[1, 2].join(", ")` и питоновский `", ".join(xs)` оба работают.

## Привычки из Python, которые не ломают код

Парсер принимает их молча, чтобы модель не тратила попытку на исправление:

- двоеточие в конце заголовка: `if x:`, `fn f():`;
- `x: int` в параметрах и `-> int` перед типом результата;
- явный `self` в методах;
- `True`, `False`, `None`, `else if`.

Для `def`, `class`, `lambda`, `except` и `raise` компилятор выдаёт короткую подсказку, как написать это на Sip.

## Чего пока нет

Шаг в срезах (`xs[::2]`), декораторы, кроме `@cache`, значения по умолчанию у полей вариантов, вложенные `async fn`, параметры типа у вложенных функций, `with` для обобщённых типов, преобразование одного интерфейса в другой. Компилятор сообщает: `... is not supported by the native compiler yet`.

## Память

Память освобождает сборщик мусора, писать `free` не нужно.

- Сборщик консервативный (mark-sweep, как Boehm GC). Указателем считается любое слово в стеке, в глобальных переменных и в объектах, которое указывает внутрь выделенного объекта. Сгенерированный код не регистрирует корни, поэтому выделение памяти почти такое же быстрое, как сдвиг указателя.
- Маленькие объекты (до 16 КБ) лежат в блоках по 64 КБ, где все объекты одного размера. Большие выделяются отдельно.
- Строки и списки чисел не содержат указателей, и сборщик их не сканирует.
- Сборка запускается, когда куча вдвое больше того, что пережило прошлую сборку, но не меньше 64 МБ. Пока программа держит меньше, она работает так же, как без сборщика.
- В `async`-программах сборка идёт в потоке, который держит GIL. Стеки остальных потоков сканируются с того места, где они отпустили GIL.

Переменные окружения:

| переменная | что делает |
|---|---|
| `SIP_GC=off` | выключить сборщик, память не освобождается |
| `SIP_GC_STATS=1` | в конце напечатать в stderr число сборок, их время и пик кучи |
| `SIP_GC_MIN=N` | нижний порог в МБ (по умолчанию 64); `0` собирает мусор как можно чаще, для проверки |
