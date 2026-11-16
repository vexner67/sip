type Row(name str, dept str, salary float)

fn avg_salary_by_dept(path str) {str: float}
    rows: [Row] = csv.read(path)
    {dept: avg(r.salary for r in group) for dept, group in rows.group_by(fn(r) = r.dept)}

fn main(path str)
    for dept, salary in avg_salary_by_dept(path)
        print "{dept}: {salary:.0f}"
