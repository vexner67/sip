type Person(name str, age int, email str? = nil)

fn find(people [Person], name str) Person?
    for p in people
        if p.name == name then return p
    nil

fn main(who str = "Bob")
    people = [Person("Ann", 31, "ann@example.com"), Person("Bob", 17), Person("Cid", 45)]
    adults = people.filter(fn(p) = p.age >= 18)
    print adults.map(fn(p) = p.name).join(", ")
    print people.sort_by(fn(p) = p.age, reverse: true).first().name
    p = find(people, who)
    if p == nil
        print "{who}: not found"
    else
        print "{p.name}: {p.email or "no email"}"
