DEFAULTS = {host: "localhost", port: "8080", debug: "false"}

fn parse(text str) {str: str}
    conf = DEFAULTS.copy()
    for line in text.splitlines()
        line = line.strip()
        if not line or line.startswith("#") then continue
        i = line.find("=")
        if i < 0 then fail "bad config line: {line}"
        conf[line[:i].strip()] = line[i + 1:].strip()
    conf

fn load_config(path str) {str: str}
    try parse(read(path))
    catch NotFound -> DEFAULTS

fn main(path str)
    for key, value in load_config(path)
        print "{key} = {value}"
