DEFAULTS = {host: "localhost", port: 8080, debug: false}

fn load_config(path str) dict
    try DEFAULTS | json.parse(read(path))
    catch NotFound -> DEFAULTS
    catch ParseError e -> fail "bad config: {e}"

fn main(path str)
    for key, value in load_config(path)
        print "{key} = {value}"
