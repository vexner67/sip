# сборщик мусора нативного бэкенда: много мусора, живые данные в рекурсии, глобальных и вложенных списках
fn tree(d int) [[int]]
    if d == 0 then return [[d]]
    l = tree(d - 1)
    junk = "{d}"
    for i in 0..2000
        tmp = [i, i, i]
        tmp.append(len(junk))
    l.append([d, d * 2])
    l

fn chain(n int, acc str) str
    if n == 0 then return acc
    s = acc + str(n % 10)
    w = [s, s + "!"]
    return chain(n - 1, w[0])

big = tree(300)
print(len(big), big[0], big[150], big[300])
c = chain(5000, "")
print(len(c), c[:12], c[-5:])
grid: [[str]] = []
for r in 0..299
    row: [str] = []
    for col in 0..99
        row.append("{r}:{col}")
    grid.append(row)
    garbage = [0] * 1000
print(grid[0][0], grid[123][45], grid[299][99], len(grid))
total = 0
for row in grid
    for cell in row
        total += len(cell)
print(total)

keep: [str] = []
total = 0
for i in 0..299999
    s = "x{i}" + "-" + str(i * 7)
    total += len(s)
    if i % 10000 == 0
        keep.append(s)
xs: [[int]] = []
for i in 0..199999
    xs.append([i, i + 1, i + 2])
    if len(xs) > 1000
        xs = xs[500:]
print(total, len(keep), keep[3], len(xs), xs[0])
