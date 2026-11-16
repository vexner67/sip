# Параллельная загрузка: sip run fetch_all.sip "https://a.com https://b.com"
async fn status(url str) int
    try http.get(url, timeout: 10).status
    catch HttpError e -> 0
    catch IOError e -> -1

async fn main(urls str)
    list = urls.split()
    for url, code in zip(list, await all(status(u) for u in list))
        print "{code} {url}"
