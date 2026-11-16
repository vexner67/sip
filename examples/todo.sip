# Список дел в JSON: sip run todo.sip todo.json --add "купить хлеб" | --done 1
type Task(title str, done bool = false)

fn load(path str) [Task]
    try json.read(path)
    catch NotFound -> []

fn main(path str, add str? = nil, done int? = nil)
    tasks = load(path)
    if add != nil then tasks.append(Task(add))
    if done != nil then tasks[done - 1].done = true
    json.write(path, tasks)
    for i, t in enumerate(tasks)
        mark = if t.done then "x" else " "
        print "{i + 1}. [{mark}] {t.title}"
