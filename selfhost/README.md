# Sip на Sip

Компилятор Sip постепенно переписывается на самом Sip. Каждая часть должна
выдавать ровно то же, что эталон на Python в `siplang/`: это проверяет
`python3 selfhost/parity.py` (и тест `SelfhostTest`).

| Часть | Python | Sip | Статус |
|---|---|---|---|
| Лексер | `siplang/lexer.py` | `lexer.sip` | готов: токены, позиции и ошибки совпадают |
| Парсер | `siplang/parser.py` | `parser.sip` | готов: дерево и ошибки совпадают |
| Проверка типов | `siplang/checker.py` | — | ещё на Python |
| Генерация C | `siplang/cgen.py` | — | ещё на Python |

```bash
sip run selfhost/lexer.sip FILE.sip    # токены построчно
sip run selfhost/parser.sip FILE.sip   # дерево, узел на строку
python3 selfhost/parity.py             # сравнение с Python на всех .sip репозитория
```

Дерево в `parser.sip` — один общий узел `N(kind, line, s, kids)`: `kind` — имя
класса из `siplang/nodes.py`, дети идут в порядке его полей. Листья: строка
(`str`), `None`, `bool`, список (`list`) и кортеж (`tuple`). Поля extern-функций
лежат в дополнительном ребёнке `extern`.

Обе части разбирают сами себя и весь код репозитория, включая стандартную библиотеку.
