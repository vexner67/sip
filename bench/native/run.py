"""Скорость нативного бэкенда против C-бэкенда (clang -O3) на программах из этой папки.

    python3 bench/native/run.py [-n 5] [ИМЯ...]

Собирает sipc (через Python, из кэша), затем каждую программу двумя способами: `sipc native` и
`sipc build`. Выводы должны совпасть; печатается лучшее время из n запусков и время компиляции.
"""
import argparse
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(ROOT))

from siplang.compiler import build_cached  # noqa: E402


def best(cmd, n):
    out = None
    t = float("inf")
    for _ in range(n):
        start = time.perf_counter()
        r = subprocess.run(cmd, capture_output=True, text=True)
        t = min(t, time.perf_counter() - start)
        out = (r.stdout, r.stderr, r.returncode)
    return t, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", type=int, default=5)
    ap.add_argument("names", nargs="*")
    args = ap.parse_args()
    sipc = build_cached(str(ROOT / "selfhost" / "sipc.sip"))
    names = args.names or sorted(p.stem for p in HERE.glob("*.sip"))
    print(f"{'программа':10} {'native':>8} {'C':>8} {'C/native':>9}   компиляция native / C")
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        # прогрев: первый запуск свежего бинарника macOS проверяет дольше обычного
        subprocess.run([sipc, "native", str(HERE / "fib.sip"), "-o", f"{tmp}/warm"], capture_output=True)
        for name in names:
            src = str(HERE / f"{name}.sip")
            exe_n, exe_c = f"{tmp}/{name}_n", f"{tmp}/{name}_c"
            cn, _ = best([sipc, "native", src, "-o", exe_n], 1)
            # C: при повторном запуске sipc берёт объектные файлы из кэша — время компиляции C тогда меньше
            cc, _ = best([sipc, "build", src, "-o", exe_c], 1)
            tn, on = best([exe_n], args.n)
            tc, oc = best([exe_c], args.n)
            mark = "" if on == oc else "   ВЫВОД РАЗНЫЙ"
            bad += on != oc
            print(f"{name:10} {tn * 1000:7.0f}м {tc * 1000:7.0f}м {tc / tn:8.2f}x   {cn * 1000:.0f} мс / {cc * 1000:.0f} мс{mark}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
