type User(name str, age int, email str)
    fn is_adult() bool = .age >= 18
    fn greet() str = "Hello, {.name}!"

ann = User("Ann", 30, "ann@example.com")
print ann.greet(), ann.is_adult()
