n = 20_000_000
is_p = [True] * (n + 1)
is_p[0] = is_p[1] = False
i = 2
while i * i <= n:
    if is_p[i]:
        j = i * i
        while j <= n:
            is_p[j] = False
            j += i
    i += 1
print(sum(1 for x in is_p if x))
