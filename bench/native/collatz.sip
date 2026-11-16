# ветвления и деление на 2: самая длинная последовательность Коллатца
fn steps(n int) int
    s = 0
    x = n
    while x != 1
        x = if x % 2 == 0 then x // 2 else 3 * x + 1
        s += 1
    s

best = 0
arg = 0
for n in 1..2000000
    s = steps(n)
    if s > best
        best = s
        arg = n
print arg, best
