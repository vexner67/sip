# строки и списки в нативном бэкенде: вывод должен совпасть с C
fn greet(name str, n int) str = "hi {name} #{n}"

fn rev(s str) str
    out = ""
    i = len(s) - 1
    while i >= 0
        out = out + s[i]
        i -= 1
    out

fn count(s str, c str) int
    k = 0
    for ch in s
        if ch == c then k += 1
    k

s = "Hello, World"
print(s, len(s), s[0], s[-1], s[-12], s[7:], s[:5], s[-5:], s[3:3], s[5:2], s[-100:100])
print(greet("bob", 3), greet("", -7))
print(rev("abcdef"), rev(""), count("banana", "a"))
print("abc" == "abc", "abc" != "abd", "ab" < "abc", "b" > "abc", "a" <= "a", "" < "a", "Z" >= "a")
print("lo, W" in s, "xyz" in s, "" in s, "W" not in s)
print(s.find("o"), s.find("World"), s.find("zz"), s.startswith("Hell"), s.endswith("ld"), s.endswith("x"))
print("-".join(["a", "b", "c"]), "".join([]), ", ".join(["one"]))
t = "x"
for i in 0..4
    t += t
print(t, len(t))
print("{1 + 2} and {True} and {False} and {-5} and {s[1]}")
print(str(123), str(-9223372036854775807 - 1), str(0), str(True), str([1, 2]), str("q"))
q = "it's"
print([q, "say \"hi\"", "back\\slash", "tab\there", "nl\n", "both ' \""])
print(["\x01", "\x7f"])
e = ""
print(e, len(e), e == "", "{e}{e}")
# списки
xs: [int] = []
for i in 0..9
    xs.append(i * i)
print(xs, len(xs), xs[0], xs[-1], xs[2:5], xs[:3], xs[7:], xs[1:-1])
xs[0] = 100
xs[-1] = -1
print(xs, xs.pop(), xs.pop(), len(xs))
ys = xs + [7, 8] + []
print(ys, [0] * 5, [1, 2] * 3, [5] * 0, [5] * -2)
print(3 in ys, 99 in ys, 99 not in ys)
nested = [[1, 2], [], [3]]
nested[1].append(9)
print(nested, len(nested[1]), nested[0][1])
words = ["b", "a", "c"]
words.append("d")
print(words, "a" in words, "z" in words, words[1:3])
bs = [True, False]
print(bs, [[["deep"]]])
total = 0
for v in ys
    total += v
print(total)
