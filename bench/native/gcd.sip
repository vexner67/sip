# остаток от деления в цикле: сумма НОД всех пар
fn gcd(a0 int, b0 int) int
    a = a0
    b = b0
    while b != 0
        a, b = b, a % b
    a

total = 0
for i in 1..3000
    for j in 1..3000
        total += gcd(i, j)
print total
