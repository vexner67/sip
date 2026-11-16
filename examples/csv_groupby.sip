fn avg_salary_by_dept(path str) {str: float}
    lines = read(path).splitlines()
    head = lines[0].split(",")
    dept, salary = head.index("dept"), head.index("salary")
    groups: {str: [float]} = {}
    for line in lines[1:]
        cols = line.split(",")
        groups[cols[dept]] = groups.get(cols[dept], []) + [float(cols[salary])]
    {d: avg(xs) for d, xs in groups}

fn main(path str)
    for dept, salary in avg_salary_by_dept(path)
        print "{dept}: {salary:.0f}"
