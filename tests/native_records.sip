# кортежи и record в нативном бэкенде: вывод должен совпасть с C
type Point(x int, y int = 0)
    fn len2() int = .x * .x + .y * .y
    fn shift(d int) Point = Point(.x + d, .y + d)
    fn far(o Point) bool = .len2() > o.len2()

type Bag(name str, items [str] = [], counts [int] = [])
    fn add(it str)
        .items.append(it)
        .counts.append(len(it))
    fn total() int
        t = 0
        for c in .counts
            t += c
        t

type Tree(val int, kids [Tree] = [])
    fn sum() int
        s = .val
        for k in .kids
            s += k.sum()
        s

fn minmax(xs [int]) (int, int)
    lo = xs[0]
    hi = xs[0]
    for x in xs
        if x < lo then lo = x
        if x > hi then hi = x
    (lo, hi)

fn swap(t (int, str)) (str, int) = (t[1], t[0])

p = Point(3, 4)
q = p.shift(1)
print(p, q, p.len2(), q.far(p), p.far(q), p == Point(3, 4), p != q)
r = p
r.x = 100
print(p.x, r == p)
b = Bag("b")
b.add("apple")
b.add("kiwi")
print(b, b.total(), len(b.items))
t = Tree(1, [Tree(2), Tree(3, [Tree(4), Tree(5)])])
print(t.sum(), t.kids[1].kids[0].val, len(t.kids))
lo, hi = minmax([5, -2, 9, 0])
print(lo, hi, minmax([7]))
print(swap((1, "a")), (1,), ((1, 2), (3, "x")), [(1, "a"), (2, "b")])
pairs = [(3, "c"), (1, "a"), (2, "b")]
best = pairs[0]
for n, s in pairs
    if n < best[0] then best = (n, s)
    print(n, s)
print(best, (1, "a") in pairs, (9, "z") in pairs, (1, 2) < (1, 3), (2, 0) > (1, 9), ("a", 2) <= ("a", 2))
print([1, 2] == [1, 2], [1, 2] != [1, 3], [[1], [2]] == [[1], [2]], [1, 2] < [1, 2, 0], [3] > [2, 9])
pts = [Point(1, -1), Point(2, -2)]
pts[0].y = 50
print(pts, Point(1, 50) in pts)
grid: [(int, int)] = []
for i in 0..20000
    grid.append((i % 7, i // 7))
acc = 0
for a, c in grid
    acc += a * c
print(acc, grid[-1], str(Point(-1)), "{p} and {(1, True)}")
