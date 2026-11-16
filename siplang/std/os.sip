# Операционная система: переменные окружения, файлы и папки, команды.
# import os; ошибки: NotFound (нет такого файла), IOError (остальные).

extern "sip" fn _getenv(name str) str? = sip_os_getenv
extern "sip" fn _setenv(name str, value str) = sip_os_setenv
extern "sip" fn _unsetenv(name str) = sip_os_unsetenv
extern "sip" fn _cwd() str = sip_os_cwd
extern "sip" fn _chdir(path str) = sip_os_chdir
extern "sip" fn _kind(path str) int = sip_os_kind
extern "sip" fn _size(path str) int = sip_os_size
extern "sip" fn _mtime(path str) float = sip_os_mtime
extern "sip" fn _mkdir(path str, exist_ok bool) = sip_os_mkdir
extern "sip" fn _remove(path str) = sip_os_remove
extern "sip" fn _rename(src str, dst str) = sip_os_rename
extern "sip" fn _opendir(path str) ptr = sip_os_opendir
extern "sip" fn _readdir(d ptr) str? = sip_os_readdir
extern "sip" fn _closedir(d ptr) = sip_os_closedir
extern "sip" fn _system(cmd str) int = sip_os_system
extern "sip" fn _output(cmd str) str = sip_os_output
extern "sip" fn _status() int = sip_os_status
extern "sip" fn _pid() int = sip_os_pid
extern "sip" fn _platform() str = sip_os_platform

# значение переменной окружения или nil
fn env(name str) str? = _getenv(name)

fn setenv(name str, value str) = _setenv(name, value)

fn unsetenv(name str) = _unsetenv(name)

# текущая папка
fn cwd() str = _cwd()

fn chdir(path str) = _chdir(path)

fn exists(path str) bool = _kind(path) != 0

fn isfile(path str) bool = _kind(path) == 1

fn isdir(path str) bool = _kind(path) == 2

# размер файла в байтах
fn size(path str) int = _size(path)

# время изменения, секунды с 1970 года (как time.time())
fn mtime(path str) float = _mtime(path)

# имена в папке (без . и ..), по алфавиту
fn listdir(path str = ".") [str]
    d = _opendir(path)
    names: [str] = []
    while true
        name = _readdir(d)
        if name == nil then break
        names.append(name)
    _closedir(d)
    sorted(names)

# все файлы в папке и вложенных папках: пути от path, по алфавиту
fn walk(path str = ".") [str]
    out: [str] = []
    for name in listdir(path)
        full = if path == "." then name else _join(path, name)
        if _kind(full) == 2
            out.extend(walk(full))
        else
            out.append(full)
    out

fn _join(a str, b str) str = if a.endswith("/") then a + b else a + "/" + b

# parents: создать и недостающие папки выше; уже существующая папка тогда не ошибка
fn mkdir(path str, parents = false)
    if not parents
        _mkdir(path, false)
        return
    cur = if path.startswith("/") then "/" else ""
    for part in path.split("/")
        if part == "" then continue
        cur = if cur == "" or cur == "/" then cur + part else cur + "/" + part
        _mkdir(cur, true)

# удаляет файл или пустую папку
fn remove(path str) = _remove(path)

fn rename(src str, dst str) = _rename(src, dst)

# запускает команду через sh; вывод идёт на экран; результат — код выхода
fn run(cmd str) int = _system(cmd)

# запускает команду через sh и возвращает её вывод; если код выхода не 0 — ошибка
fn output(cmd str) str
    out = _output(cmd)
    code = _status()
    if code != 0 then fail "command failed (exit {code}): {cmd}"
    out

fn pid() int = _pid()

# "darwin", "linux" или "unix"
fn platform() str = _platform()
