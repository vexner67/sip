# Параллельная загрузка: sip run fetch_all.sip https://a.com https://b.com
async fn status(url str) int
    try http.get(url, timeout: 10).status
    catch HttpError e -> 0
    catch IOError e -> -1

async fn main(*urls str)
    for url, code in zip(urls, await all(status(u) for u in urls))
        print "{code} {url}"
