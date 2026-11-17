# строки: подстановки, склейка, срезы, поиск, сравнение
words = ["alpha", "beta", "gamma", "delta", "epsilon"]
total = 0
hits = 0
for i in 0..3000000
    w = words[i % 5]
    s = "{w}-{i}"
    total += len(s)
    if s[:4] == "beta" then hits += 1
    if "99" in s then hits += 1
    if s < "b" then hits += 1
print(total, hits)
