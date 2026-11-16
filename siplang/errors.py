"""Ошибки компиляции Sip.

Формат намеренно короткий, в одну строку: `файл:строка:колонка: сообщение`.
Ошибки попадают в контекст ИИ-агента, и каждая лишняя строка стоит токенов.
"""


class SipError(Exception):
    def __init__(self, msg: str, line: int = 0, col: int = 0, file: str = "<input>"):
        super().__init__(msg)
        self.msg = msg
        self.line = line
        self.col = col
        self.file = file

    def __str__(self) -> str:
        where = f"{self.file}:{self.line}"
        if self.col:
            where += f":{self.col}"
        return f"{where}: {self.msg}"
