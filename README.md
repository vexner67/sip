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
| fib(35) | 0.027 с | 0.026 с | 0.033 с | 0.623 с |
| решето до 20 млн | 0.053 с | 0.042 с | 0.049 с | 3.328 с |
| частоты 2 млн слов | 0.110 с | — | 0.138 с | 0.567 с |
| сортировка 3 млн float | 0.201 с | — | 0.254 с | 1.142 с |

Подробности и программы: [bench/speed](bench/speed/results.md).

Откуда скорость:

- Типы выводятся при компиляции, поэтому `int` — это регистр, а не объект. Генерики мономорфизируются: `[int]` и `[str]` становятся разными структурами C.
- `sum(x * x for x in xs if ...)`, `min`, `max`, `any`, `all` компилируются в один цикл без промежуточного списка.
- Память выделяется bump-аллокатором и не освобождается: это подходит для утилит и скриптов, но не для долгоживущих серверов.
- Проверка границ остаётся включённой: ошибка выглядит как `prog.sip:3: IndexError: ...` со строкой исходника.

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
| `sip run FILE.sip [args]` | собирает (с кэшем в `~/.cache/sip`) и запускает; короче: `sip FILE.sip` |
| `sip build FILE.sip [-o OUT]` | собирает исполняемый файл |
| `sip check FILE.sip...` | проверяет синтаксис и типы |
| `sip c FILE.sip [-o OUT.c]` | показывает сгенерированный C |

Первая сборка занимает около 0.3 с (это clang), повторный запуск из кэша около 20 мс.

## Библиотека

Модули `.sip` подключаются через `import`, а встроенные модули `math`, `random`, `time`, `json`, `csv`, `http` есть всегда. JSON и CSV читаются сразу в нужный тип, без промежуточных словарей:

```
type User(name str, age int, email str? = nil)

users: [User] = json.read("users.json")
async fn get(id int) User = http.get("https://api.example.com/users/{id}").json()

async fn main()
    for u in await all(get(i) for i in 1..10)    # 10 запросов одновременно
        print u.name
```

## Чего пока нет

Шага в срезах (`xs[::2]`), декораторов, кроме `@cache`, значений по умолчанию у полей вариантов и вложенных `async fn`. Компилятор сообщает об этом явно: `... is not supported by the native compiler yet`.

## Устройство

| файл | роль |
|---|---|
| [siplang/lexer.py](siplang/lexer.py) | токены, отступы → INDENT/DEDENT |
| [siplang/parser.py](siplang/parser.py) | рекурсивный спуск → AST ([nodes.py](siplang/nodes.py)) |
| [siplang/types.py](siplang/types.py) | типы и их представление в C |
| [siplang/checker.py](siplang/checker.py) | вывод и проверка типов (унификация) |
| [siplang/cregistry.py](siplang/cregistry.py) | C-код для конкретных списков, словарей, кортежей, записей |
| [siplang/modules.py](siplang/modules.py) | `import`: сборка программы из нескольких файлов |
| [siplang/cgen.py](siplang/cgen.py) | AST с типами → C |
| [siplang/native/sip_rt.h](siplang/native/sip_rt.h) | рантайм: строки, аллокатор, ошибки (setjmp), форматирование чисел как в Python, JSON, CSV, HTTP (libcurl), задачи |
| [siplang/compiler.py](siplang/compiler.py) | вызов clang, кэш сборок |
| [siplang/cli.py](siplang/cli.py) | команда `sip` |

## Документация

- [docs/spec.md](docs/spec.md) — справочник языка.
- [docs/prompt.md](docs/prompt.md) — сжатая спецификация для ИИ-модели, около 1200 токенов.
- [bench/](bench/) — замер токенов, по которому выбирали синтаксис ([DECISION.md](bench/DECISION.md)), и замер скорости ([speed](bench/speed/)).

## Тесты

```bash
python3 -m unittest discover -s tests
```

С санитайзерами:

```bash
SIP_TEST_CFLAGS="-O1 -fsanitize=address,undefined" python3 -m unittest discover -s tests
```
