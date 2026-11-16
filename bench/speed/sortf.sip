seed = 7
xs: [float] = []
for _ in 1..3_000_000
    seed = (seed * 1103515245 + 12345) % 2147483648
    xs.append((seed % 1_000_000) / 1000.0)
xs.sort()
total = 0.0
for i in 0..len(xs) - 1
    total += xs[i] * (i % 7)
print xs[0], xs[len(xs) / 2], "{total:.1f}"
