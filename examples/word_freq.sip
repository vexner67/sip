# Самые частые слова в файле: sip run word_freq.sip text.txt --n 5
fn top_words(path str, n = 10) [(str, int)] = read(path).lower().split().count().top(n)

fn main(path str, n = 3)
    for word, k in top_words(path, n)
        print "{word}: {k}"
