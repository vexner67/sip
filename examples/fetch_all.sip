# Параллельная загрузка: sip run fetch_all.sip https://a.com https://b.com
async fn fetch_all(urls [str]) [int] = [r.status for r in await all(http.get(u) for u in urls)]

async fn main(urls [str])
    for url, status in zip(urls, await fetch_all(urls))
        print "{status} {url}"
