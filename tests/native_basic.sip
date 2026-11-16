LIMIT = 30
count = 0

fn gcd(a int, b int) int
    while b != 0
        a, b = b, a % b
    a

fn is_prime(n int) bool
    if n < 2 then return false
    i = 2
    while i * i <= n
        if n % i == 0 then return false
        i += 1
    true

fn collatz(n int) int
    steps = 0
    x = n
    while x != 1
        x = if x % 2 == 0 then x // 2 else 3 * x + 1
        steps += 1
    steps

fn many(a int, b int, c int, d int, e int, f int, g int, h int) int = a - b + c * d - e // f + g % h

fn bump()
    count += 1

for i in 1..LIMIT
    if is_prime(i)
        bump()
print "primes:", count
total = 0
for i in 0..100
    if i % 3 == 0 then continue
    if i > 50 then break
    total += i
print "total", total
print 7 // 2, -7 // 2, 7 // -2, -7 // -2, 7 % 3, -7 % 3, 7 % -3, -7 % -3
print 7 / 2, -1 * 5, 1 - 10, 0 - 9223372036854775807 - 1
print 1 < 2 < 3, 3 < 2 < 4, 1 == 1, 1 != 1, not true, true and false, false or true
print "collatz {collatz(27)} steps, gcd {gcd(1071, 462)}"
print many(1, 2, 3, 4, 5, 6, 7, 8)
print abs(-5), abs(3), 6 & 3, 6 | 3, 6 ^ 3, ~5, -(-3)
x = 10
x -= 3
x *= 2
print x, x > 13 and x < 15
for j in 5..3
    print "never"
k = 0
while true
    k += 1
    if k >= 4 then break
print "k={k}", true, false
print 9223372036854775807, -9223372036854775807 - 1
