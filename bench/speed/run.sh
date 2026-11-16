#!/bin/bash
# Сборка и замер: sip (clang -O3), C (clang -O3), Go, Python. Лучшее из 3 запусков.
set -e
cd "$(dirname "$0")"
OUT=${OUT:-/tmp/sipbench}
mkdir -p "$OUT"
export PYTHONPATH="$(cd ../.. && pwd)"
best() { local b=999; for _ in 1 2 3; do local s=$(python3 -c 'import time;print(time.perf_counter())'); "$@" > /dev/null; local e=$(python3 -c 'import time;print(time.perf_counter())'); b=$(python3 -c "print(min($b, $e - $s))"); done; printf "%.3f" "$b"; }
printf "%-8s %8s %8s %8s %8s\n" bench sip C Go Python
for t in fib sieve words sortf; do
  python3 -m siplang build $t.sip -o "$OUT/$t.sip.bin" > /dev/null
  [ -f $t.c ] && clang -O3 -march=native $t.c -o "$OUT/$t.c.bin"
  go build -o "$OUT/$t.go.bin" $t.go
  s=$(best "$OUT/$t.sip.bin"); c=-; [ -f $t.c ] && c=$(best "$OUT/$t.c.bin"); g=$(best "$OUT/$t.go.bin"); p=$(best python3 $t.py)
  printf "%-8s %8s %8s %8s %8s\n" $t $s $c $g $p
done
