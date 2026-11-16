# Sip

Язык программирования, который бережёт токены ИИ и работает со скоростью C. По виду это Python без лишнего шума (**на 39% меньше токенов** на типичных задачах), а по сути статически типизированный компилируемый язык: Sip генерирует C и собирает его через `clang -O3`.

```
type Shape = Circle(r float) | Rect(w float, h float)

fn area(s Shape) float = match s
    Circle(r) -> pi * r * r
    Rect(w, h) -> w * h

fn main(path str, n = 3)
    for word, k in read(path).lower().split().count().top(n)
        print "{word}: {k}"
```

## Скорость

| тест | Sip | C | Go | Python |
|---|---|---|---|---|
| fib(35) | 0.034 с | 0.028 с | 0.036 с | 0.629 с |
| решето до 20 млн | 0.057 с | 0.038 с | 0.061 с | 3.475 с |
| частоты 2 млн слов | 0.103 с | — | 0.140 с | 0.538 с |
| сортировка 3 млн float | 0.212 с | — | 0.256 с | 1.133 с |

Подробности и программы: [bench/speed](bench/speed/results.md).

Откуда скорость:

- Типы выводятся при компиляции, поэтому `int` — это регистр, а не объект. Дженерики мономорфизируются: `[int]` и `[str]`, `Box[int]` и `Box[str]`, `first[int]` и `first[str]` становятся разными структурами и функциями C.
- Интерфейсы, как в Go: тип подходит, если у него есть нужные методы. `fn f[T: Shape]` вызывает методы напрямую, а значение типа `Shape` — через таблицу методов.
- `sum(x * x for x in xs if ...)`, `min`, `max`, `any`, `all` компилируются в один цикл без промежуточного списка.
- Память освобождает сборщик мусора (консервативный mark-sweep). Он включается, когда куча превышает 64 МБ, поэтому короткие скрипты обычно не тратят на него время. `SIP_GC_STATS=1` печатает статистику сборок, `SIP_GC=off` выключает сборщик.
- Проверки остаются включёнными: выход за границы списка и переполнение `int` бросают `IndexError` и `OverflowError`, а не портят память. Ошибка выглядит как `prog.sip:3: IndexError: ...` со строкой исходника. Проверка переполнения — одна инструкция `jo` после сложения и почти ничего не стоит.
- Ошибки типизированы: `fail NotEnough(need, have)` бросает запись, `catch NotEnough e` ловит именно её, и `e.need` доступно как поле.

## Запуск

Нужны Python 3.12+ (сам компилятор) и clang или gcc.

```bash
python3 -m siplang run examples/greet.sip Ann --times 2
```

Или установить команду `sip`:

```bash
pip install -e .
```

| команда | что делает |
|---|---|
| `sip run FILE.sip [args]` | собирает (с кэшем в `~/.cache/sip`) и запускает; короче: `sip FILE.sip`. В папке пакета файл можно не указывать |
| `sip build FILE.sip [-o OUT] [--whole]` | собирает исполняемый файл: каждый модуль — своя единица C из кэша; `--whole` — одной единицей |
| `sip init NAME` | создаёт пакет: `NAME/sip.toml` и `NAME/main.sip` |
| `sip check FILE.sip...` | проверяет синтаксис и типы |
| `sip test [PATH...] [-k TEXT]` | запускает блоки `test "имя"`; печатает только упавшие |
| `sip fmt [PATH...] [--check]` | форматирует код (`--check` — только проверить) |
| `sip lsp` | языковой сервер для редактора: ошибки, типы, переход к определению, дополнение |
| `sip c FILE.sip [-o OUT.c]` | показывает сгенерированный C |

Первая сборка занимает около 0.3 с (это clang), повторный запуск из кэша около 20 мс.

## Библиотека

Модули `.sip` подключаются через `import`; имена на `_` видны только в своём модуле. Пакет — папка с `sip.toml`, зависимости в нём указываются папкой или git-репозиторием с ревизией. Каждый модуль компилируется отдельно и берётся из кэша, если не менялся. Встроенные модули `math`, `random`, `time`, `json`, `csv`, `http` есть всегда. Стандартная библиотека `os`, `path` и `re` написана на самом Sip. Функции C вызываются напрямую: `extern fn strlen(s str) usize`, `extern "sqlite3" fn ...`, `extern "glue.c" fn ...`. JSON и CSV читаются сразу в нужный тип, без промежуточных словарей:

```
type User(name str, age int, email str? = nil)

users: [User] = json.read("users.json")
async fn get(id int) User = http.get("https://api.example.com/users/{id}").json()

async fn main()
    for u in await all(get(i) for i in 1..10)    # 10 запросов одновременно
        print u.name
```

## Чего пока нет

Шага в срезах (`xs[::2]`), декораторов, кроме `@cache`, значений по умолчанию у полей вариантов, вложенных `async fn` и параметров типа у вложенных функций. Компилятор сообщает об этом явно: `... is not supported by the native compiler yet`.

## Устройство

| файл | роль |
|---|---|
| [siplang/lexer.py](siplang/lexer.py) | токены, отступы → INDENT/DEDENT |
| [siplang/parser.py](siplang/parser.py) | рекурсивный спуск → AST ([nodes.py](siplang/nodes.py)) |
| [siplang/types.py](siplang/types.py) | типы и их представление в C |
| [siplang/checker.py](siplang/checker.py) | вывод и проверка типов (унификация) |
| [siplang/cregistry.py](siplang/cregistry.py) | C-код для конкретных списков, словарей, кортежей, записей |
| [siplang/modules.py](siplang/modules.py) | `import`, пакеты (`sip.toml`, зависимости), приватные имена |
| [siplang/cgen.py](siplang/cgen.py) | AST с типами → C |
| [siplang/native/sip_rt.h](siplang/native/sip_rt.h) | рантайм: строки, аллокатор, ошибки (setjmp), форматирование чисел как в Python, JSON, CSV, HTTP (libcurl), задачи |
| [siplang/fmt.py](siplang/fmt.py) | `sip fmt`: форматирование по токенам, комментарии сохраняются |
| [siplang/lsp.py](siplang/lsp.py) | `sip lsp`: языковой сервер |
| [siplang/std/](siplang/std/) | стандартная библиотека на Sip: `os`, `path`, `re` |
| [siplang/compiler.py](siplang/compiler.py) | вызов clang, раздельная компиляция, кэш объектных файлов и бинарников |
| [siplang/cli.py](siplang/cli.py) | команда `sip` |
| [selfhost/](selfhost/) | компилятор на самом Sip: лексер, парсер, загрузчик модулей и проверка типов совпадают с Python; генерация C пока на Python |

## Документация

- [docs/spec.md](docs/spec.md) — справочник языка.
- [docs/prompt.md](docs/prompt.md) — сжатая спецификация для ИИ-модели, около 1500 токенов.
- [bench/](bench/) — замер токенов, по которому выбирали синтаксис ([DECISION.md](bench/DECISION.md)), и замер скорости ([speed](bench/speed/)).

## Тесты

```bash
python3 -m unittest discover -s tests
```

С санитайзерами:

```bash
SIP_TEST_CFLAGS="-O1 -fsanitize=address,undefined" python3 -m unittest discover -s tests
```
