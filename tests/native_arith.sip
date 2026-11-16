# деление, остаток, умножение на константы и перестановки: вывод сверяется с C-бэкендом
fn fd(a int, b int) int = a // b
fn md(a int, b int) int = a % b

fn divs(lo int, hi int) int
    h = 0
    for x in lo..hi
        for y in -4..4
            if y != 0
                q = x // y
                r = x % y
                h = (h * 31 + q * 7 + r) % 1000000007
                if fd(x, y) != q or md(x, y) != r then print "mismatch", x, y
                if x % y == 0 then h += 1
                if x % y != 0 then h += 2
    h

fn consts(x int) int = x // 3 + x % 3 + x // 4 + x % 4 + x // 7 + x % 7 + x * 3 + 5 * x + x * 2 + 4 * x + (x & 255)

print divs(-20, 20)
total = 0
for x in -50..50
    total += consts(x)
    if x % 2 == 0 then total += 1
    if x % 8 != 0 then total += 3
print total
a = 1
b = 2
c = 3
a, b = b, a
print a, b
a, b, c = c, a, b
print a, b, c
a, b = b, a + b
print a, b
for i in 1..10
    a, b = b, a + b
print a, b
n = 10
m = 0
for k in 0..n
    m = m * 2 + k
print m, k
big = 4611686018427387903
print big * 2 // 3, big % 1000, -big // 7, -big % 7
