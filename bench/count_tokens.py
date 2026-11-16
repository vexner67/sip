"""Сравнение вариантов синтаксиса по числу токенов.

Каждый файл samples/<вариант>.txt содержит задачи, разделённые строками
`### имя_задачи`. Скрипт считает токены каждой задачи двумя токенизаторами
(o200k_base и cl100k_base) и сравнивает варианты с эталоном (python).

Запуск:
    .venv/bin/python count_tokens.py [--baseline python] [--spec spec.md]
"""

import argparse
import math
import re
import statistics
from pathlib import Path

import tiktoken

ENCODINGS = ["o200k_base", "cl100k_base"]
ROOT = Path(__file__).parent
SEP = re.compile(r"^### (\S+)\s*$", re.M)


def load_samples(folder: Path) -> dict[str, dict[str, str]]:
    variants = {}
    for path in sorted(folder.glob("*.txt")):
        parts = SEP.split(path.read_text(encoding="utf-8"))
        # parts = [префикс, имя1, код1, имя2, код2, ...]
        tasks = {parts[i]: parts[i + 1].strip("\n") for i in range(1, len(parts), 2)}
        variants[path.stem] = tasks
    return variants


def geomean(xs: list[float]) -> float:
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", default="python")

    ap.add_argument("--out", default="results.md")
    args = ap.parse_args()

    variants = load_samples(ROOT / "samples")
    base = args.baseline
    task_names = list(variants[base])
    for name, tasks in variants.items():
        missing = set(task_names) ^ set(tasks)
        if missing:
            raise SystemExit(f"{name}: не совпадает набор задач: {sorted(missing)}")

    encs = {e: tiktoken.get_encoding(e) for e in ENCODINGS}
    # counts[enc][variant][task] = число токенов
    counts = {
        e: {v: {t: len(enc.encode(code)) for t, code in tasks.items()} for v, tasks in variants.items()}
        for e, enc in encs.items()
    }

    lines: list[str] = []
    out = lines.append

    # --- Итоговая таблица ---
    out("## Итог по всем задачам\n")
    out("| вариант | символов | " + " | ".join(f"токены {e}" for e in ENCODINGS)
        + " | к python (o200k, сумма) | к python (геом. среднее по задачам) | токенов/символ | не-ASCII символов |")
    out("|---|---:|" + "---:|" * len(ENCODINGS) + "---:|---:|---:|---:|")
    order = sorted(variants, key=lambda v: sum(counts["o200k_base"][v].values()))
    for v in order:
        text = "\n".join(variants[v].values())
        chars = len(text)
        nonascii = sum(1 for ch in text if ord(ch) > 127)
        tot = {e: sum(counts[e][v].values()) for e in ENCODINGS}
        ratio_sum = tot["o200k_base"] / sum(counts["o200k_base"][base].values())
        ratio_geo = geomean([counts["o200k_base"][v][t] / counts["o200k_base"][base][t] for t in task_names])
        out(f"| {v} | {chars} | " + " | ".join(str(tot[e]) for e in ENCODINGS)
            + f" | {ratio_sum:.2f} | {ratio_geo:.2f} | {tot['o200k_base'] / chars:.3f} | {nonascii} |")

    # --- По задачам ---
    out("\n## По задачам (o200k_base, токены; в скобках доля от python)\n")
    out("| задача | " + " | ".join(order) + " |")
    out("|---|" + "---:|" * len(order))
    for t in task_names:
        b = counts["o200k_base"][base][t]
        cells = [f"{counts['o200k_base'][v][t]} ({counts['o200k_base'][v][t] / b:.2f})" for v in order]
        out(f"| {t} | " + " | ".join(cells) + " |")

    # --- Насколько стабилен выигрыш ---
    out("\n## Разброс выигрыша по задачам (o200k_base, доля от python)\n")
    out("| вариант | мин | медиана | макс | задач, где хуже python |")
    out("|---|---:|---:|---:|---:|")
    for v in order:
        rs = [counts["o200k_base"][v][t] / counts["o200k_base"][base][t] for t in task_names]
        worse = sum(r > 1 for r in rs)
        out(f"| {v} | {min(rs):.2f} | {statistics.median(rs):.2f} | {max(rs):.2f} | {worse} |")

    # --- Цена символов ---
    out("\n## Сколько токенов стоит один символ-оператор\n")
    out("| символ | o200k | cl100k |")
    out("|---|---:|---:|")
    probe = ["fn", "def", "=>", "->", "|>", "|", "λ", "→", "↦", "≔", "∷", "▷", "ℤ", "𝕊", "∀", "∈", "⟨", "‥"]
    for s in probe:
        # с пробелом перед символом, как он стоит в коде
        out(f"| `{s}` | " + " | ".join(str(len(encs[e].encode(" " + s))) for e in ENCODINGS) + " |")

    # --- Окупаемость спецификации ---
    # Спецификации: specs/<вариант>.md
    specs = {p.stem: p for p in sorted((ROOT / "specs").glob("*.md"))} if (ROOT / "specs").exists() else {}
    if specs:
        out("\n## Окупаемость спецификации\n")
        out("Новый язык модель не знает, поэтому спецификация лежит в контексте каждой сессии."
            " Окупаемость: сколько python-кода (в токенах) надо написать или прочитать за сессию,"
            " чтобы экономия покрыла стоимость спецификации.\n")
        out("| вариант | токенов в спецификации | экономия на коде | окупается после N токенов python-кода | ≈ задач из набора |")
        out("|---|---:|---:|---:|---:|")
        base_total = sum(counts["o200k_base"][base].values())
        for v, path in specs.items():
            if v not in variants:
                continue
            spec_tokens = len(encs["o200k_base"].encode(path.read_text(encoding="utf-8")))
            saving = 1 - sum(counts["o200k_base"][v].values()) / base_total
            if saving > 0:
                be = spec_tokens / saving
                out(f"| {v} | {spec_tokens} | {saving:.0%} | {be:,.0f} | {be / (base_total / len(task_names)):.0f} |")
            else:
                out(f"| {v} | {spec_tokens} | {saving:.0%} | никогда | — |")

    report = "\n".join(lines)
    print(report)
    (ROOT / args.out).write_text("# Результаты подсчёта токенов\n\n" + report + "\n", encoding="utf-8")
    print(f"\nСохранено в {args.out}")


if __name__ == "__main__":
    main()
