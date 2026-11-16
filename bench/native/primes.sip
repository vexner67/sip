# деление: перебор делителей до корня
fn is_prime(n int) bool
    if n < 2 then return false
    if n % 2 == 0 then return n == 2
    d = 3
    while d * d <= n
        if n % d == 0 then return false
        d += 2
    true

count = 0
for n in 0..3000000
    if is_prime(n) then count += 1
print count
