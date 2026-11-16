fn get_user_name(id int, base = "https://api.example.com") str?
    try http.get("{base}/users/{id}", timeout: 5).json()["name"]
    catch e
        print "error: {e}"
        nil

fn main(id int, base = "https://api.example.com")
    print get_user_name(id, base)
