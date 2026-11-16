seed = 42
words: [str] = []
for _ in 1..2_000_000
    seed = (seed * 1103515245 + 12345) % 2147483648
    words.append("w{seed % 50000}")
counts: {str: int} = {}
for w in words
    counts[w] = counts.get(w, 0) + 1
best = counts.top(3)
print len(counts), best
