# списки: append, чтение и запись по индексу, обход, срезы
xs: [int] = []
for i in 0..3000000
    xs.append((i * 7919) % 1000)
counts = [0] * 1000
for x in xs
    counts[x] += 1
best = 0
for i in 0..999
    if counts[i] > counts[best] then best = i
s = 0
for k in 0..len(xs) // 1000 - 1
    part = xs[k * 1000:k * 1000 + 10]
    s += part[3]
rows: [[int]] = []
for r in 0..len(xs) // 100
    rows.append([r, r * 2, r * 3])
for row in rows
    s += row[2] - row[1]
print(best, counts[best], s, len(rows))
