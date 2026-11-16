seed = 7
xs = []
for _ in range(3_000_000):
    seed = (seed * 1103515245 + 12345) % 2147483648
    xs.append((seed % 1_000_000) / 1000.0)
xs.sort()
total = 0.0
for i in range(len(xs)):
    total += xs[i] * (i % 7)
print(xs[0], xs[len(xs) // 2], f"{total:.1f}")
