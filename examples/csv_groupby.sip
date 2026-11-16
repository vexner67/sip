fn avg_salary_by_dept(path str) {str: float}
    groups = csv.read(path).group_by("dept")
    {dept: avg(float(r.salary) for r in rows) for dept, rows in groups}

fn main(path str)
    for dept, salary in avg_salary_by_dept(path)
        print "{dept}: {salary:.0f}"
