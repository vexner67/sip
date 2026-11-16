from collections import Counter
seed = 42
words = []
for _ in range(2_000_000):
    seed = (seed * 1103515245 + 12345) % 2147483648
    words.append(f"w{seed % 50000}")
counts = {}
for w in words:
    counts[w] = counts.get(w, 0) + 1
best = Counter(counts).most_common(3)
print(len(counts), best)
