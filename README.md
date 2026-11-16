# Sip

Язык программирования, который бережёт токены ИИ. Это Python без лишнего шума: тот же смысл и те же библиотеки, но на типичных задачах **на 39% меньше токенов**. Sip транслируется в читаемый Python 3.12.

```
type Shape = Circle(r float) | Rect(w float, h float)

fn area(s Shape) float = match s
    Circle(r) -> pi * r * r
    Rect(w, h) -> w * h

fn main(path str, n = 3)
    for word, k in read(path).lower().split().count().top(n)
        print "{word}: {k}"
```

## Запуск

Нужен только Python 3.12 или новее, зависимостей нет.

```bash
python3 -m siplang run examples/greet.sip Ann --times 2
```

Или установить команду `sip`:

```bash
pip install -e .
```

```bash
sip run examples/fizzbuzz.sip
```

| команда | что делает |
|---|---|
| `sip run FILE.sip [args]` | компилирует и запускает (короче: `sip FILE.sip`) |
| `sip build FILE.sip [-o OUT.py]` | сохраняет сгенерированный Python |
| `sip check FILE.sip...` | только проверяет синтаксис |

## Устройство

| файл | роль |
|---|---|
| [siplang/lexer.py](siplang/lexer.py) | токены, отступы → INDENT/DEDENT |
| [siplang/parser.py](siplang/parser.py) | рекурсивный спуск → AST ([nodes.py](siplang/nodes.py)) |
| [siplang/codegen.py](siplang/codegen.py) | AST → Python с учётом приоритетов и картой строк |
| [siplang/runtime.py](siplang/runtime.py) | стандартная библиотека: `read`, `http`, `csv`, `json`, методы коллекций |
| [siplang/compiler.py](siplang/compiler.py) | компиляция, запуск, ошибки в координатах `.sip` |
| [siplang/cli.py](siplang/cli.py) | команда `sip` |

## Документация

- [docs/spec.md](docs/spec.md) — справочник языка.
- [docs/prompt.md](docs/prompt.md) — сжатая спецификация для ИИ-модели, около 620 токенов.
- [bench/](bench/) — замер токенов, по которому выбирали синтаксис ([DECISION.md](bench/DECISION.md)).

## Тесты

```bash
python3 -m unittest discover -s tests
```
