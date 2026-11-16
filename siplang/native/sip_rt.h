/* Рантайм Sip для нативной сборки.
 *
 * Подключается в каждый сгенерированный .c файл одной единицей трансляции,
 * поэтому clang может встраивать и оптимизировать всё вместе с кодом программы.
 * Перед подключением генератор определяет SIP_FILE, SIP_SRC и SIP_NSRC.
 */
#include <errno.h>
#include <math.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SIP_PI 3.14159265358979323846
#define SIP_LIKELY(x) __builtin_expect(!!(x), 1)
#define SIP_UNLIKELY(x) __builtin_expect(!!(x), 0)
#define SIP_LIT(s) ((sip_str){(s), (int64_t)(sizeof(s) - 1)})

typedef struct { const char *p; int64_t n; } sip_str;
typedef struct { int64_t lo, hi; } sip_range;

/* ---------- память: bump-аллокатор ----------
 * Самый быстрый способ выделять память: сдвиг указателя. Память не освобождается
 * до конца программы. Буферы списков и словарей растут через realloc. */

static char *sip_heap_ptr, *sip_heap_end;

static void *sip_alloc_slow(size_t n) {
    size_t chunk = n > (1u << 20) ? n : (1u << 20);
    char *p = malloc(chunk);
    if (!p) { fputs("sip: out of memory\n", stderr); exit(1); }
    sip_heap_ptr = p + n;
    sip_heap_end = p + chunk;
    return p;
}

static inline void *sip_alloc(size_t n) {
    n = (n + 15) & ~(size_t)15;
    if (SIP_UNLIKELY((size_t)(sip_heap_end - sip_heap_ptr) < n)) return sip_alloc_slow(n);
    void *p = sip_heap_ptr;
    sip_heap_ptr += n;
    return p;
}

static void *sip_realloc(void *p, size_t n) {
    void *q = realloc(p, n ? n : 1);
    if (!q) { fputs("sip: out of memory\n", stderr); exit(1); }
    return q;
}

/* ---------- ошибки ---------- */

enum {
    SIP_E_Error, SIP_E_NotFound, SIP_E_ParseError, SIP_E_IndexError, SIP_E_KeyError,
    SIP_E_ValueError, SIP_E_ZeroDivisionError, SIP_E_AssertionError, SIP_E_IOError, SIP_E_NilError,
    SIP_E_HttpError
};
static const char *const sip_err_names[] = {
    "Error", "NotFound", "ParseError", "IndexError", "KeyError",
    "ValueError", "ZeroDivisionError", "AssertionError", "IOError", "NilError", "HttpError"
};

typedef struct sip_try { jmp_buf jb; struct sip_try *prev; } sip_try;
static sip_try *sip_try_top;
static int sip_err_kind;
static sip_str sip_err_msg;
static int sip_err_line;

static inline void sip_try_push(sip_try *t) { t->prev = sip_try_top; sip_try_top = t; }
static inline void sip_try_pop(void) { sip_try_top = sip_try_top->prev; }

/* async: задачи выполняются в потоках, но код Sip в каждый момент выполняет только один поток —
 * тот, что держит sip_gil (как GIL в Python). Блокирующие вызовы (http, sleep) отпускают его,
 * поэтому ожидание идёт параллельно. При смене потока сохраняется его стек try. */
#ifdef SIP_USE_ASYNC
#include <pthread.h>
static pthread_mutex_t sip_gil = PTHREAD_MUTEX_INITIALIZER;
static bool sip_threaded;
typedef struct { sip_try *try_top; } sip_tstate;
static inline sip_tstate sip_gil_release(void) {
    sip_tstate st = {sip_try_top};
    if (sip_threaded) pthread_mutex_unlock(&sip_gil);
    return st;
}
static inline void sip_gil_acquire(sip_tstate st) {
    if (sip_threaded) pthread_mutex_lock(&sip_gil);
    sip_try_top = st.try_top;
}
#define SIP_BLOCKING_BEGIN sip_tstate sip_st_ = sip_gil_release();
#define SIP_BLOCKING_END sip_gil_acquire(sip_st_);
#else
#define SIP_BLOCKING_BEGIN
#define SIP_BLOCKING_END
#endif

static bool sip_kind_matches(int kind, int want) {
    if (kind == want) return true;
    return want == SIP_E_ValueError && kind == SIP_E_ParseError;  /* ParseError — частный случай */
}

__attribute__((noreturn, cold)) static void sip_die(void) {
    fflush(stdout);
    int f = 0;
    while (f + 1 < SIP_NFILES && SIP_FILES[f + 1].start < sip_err_line) f++;
    fprintf(stderr, "%s:%d: %s", SIP_FILES[f].name, sip_err_line - SIP_FILES[f].start, sip_err_names[sip_err_kind]);
    if (sip_err_msg.n) fprintf(stderr, ": %.*s", (int)sip_err_msg.n, sip_err_msg.p);
    fputc('\n', stderr);
    if (sip_err_line > 0 && sip_err_line <= SIP_NSRC) {
        const char *s = SIP_SRC[sip_err_line - 1];
        while (*s == ' ') s++;
        fprintf(stderr, "    %s\n", s);
    }
    exit(1);
}

__attribute__((noreturn, cold)) static void sip_reraise(void) {
    if (!sip_try_top) sip_die();
    sip_try *t = sip_try_top;
    sip_try_pop();
    longjmp(t->jb, 1);
}

__attribute__((noreturn, cold)) static void sip_raise(int kind, sip_str msg, int line) {
    sip_err_kind = kind;
    sip_err_msg = msg;
    sip_err_line = line;
    sip_reraise();
}

__attribute__((noreturn, cold)) static void sip_raisef(int kind, int line, const char *fmt, ...);

/* ---------- построитель строк ---------- */

typedef struct { char *p; int64_t n, cap; } sip_sb;

static inline sip_sb sip_sb_new(void) { return (sip_sb){NULL, 0, 0}; }

static void sip_sb_grow(sip_sb *b, int64_t need) {
    int64_t cap = b->cap ? b->cap : 32;
    while (cap < b->n + need) cap *= 2;
    b->p = sip_realloc(b->p, (size_t)cap);
    b->cap = cap;
}

static inline void sip_sb_put(sip_sb *b, const char *s, int64_t n) {
    if (SIP_UNLIKELY(b->n + n > b->cap)) sip_sb_grow(b, n);
    memcpy(b->p + b->n, s, (size_t)n);
    b->n += n;
}

static inline void sip_sb_putc(sip_sb *b, char c) {
    if (SIP_UNLIKELY(b->n + 1 > b->cap)) sip_sb_grow(b, 1);
    b->p[b->n++] = c;
}

static inline void sip_sb_str(sip_sb *b, sip_str s) { sip_sb_put(b, s.p, s.n); }

static inline sip_str sip_sb_done(sip_sb *b) { return (sip_str){b->p ? b->p : "", b->n}; }

#include <stdarg.h>
static void sip_sb_printf(sip_sb *b, const char *fmt, ...) {
    char tmp[128];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    if (n < (int)sizeof tmp) { sip_sb_put(b, tmp, n); return; }
    char *big = malloc((size_t)n + 1);
    va_start(ap, fmt);
    vsnprintf(big, (size_t)n + 1, fmt, ap);
    va_end(ap);
    sip_sb_put(b, big, n);
    free(big);
}

static void sip_raisef(int kind, int line, const char *fmt, ...) {
    sip_sb b = sip_sb_new();
    char tmp[256];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(tmp, sizeof tmp, fmt, ap);
    va_end(ap);
    sip_sb_put(&b, tmp, n < (int)sizeof tmp ? n : (int)sizeof tmp - 1);
    sip_raise(kind, sip_sb_done(&b), line);
}

/* ---------- вывод ---------- */

static sip_sb sip_out_line;

static inline void sip_print_line(void) {
    sip_sb_putc(&sip_out_line, '\n');
    fwrite(sip_out_line.p, 1, (size_t)sip_out_line.n, stdout);
    sip_out_line.n = 0;
}

/* ---------- числа ---------- */

static inline int64_t sip_floordiv(int64_t a, int64_t b, int line) {
    if (SIP_UNLIKELY(b == 0)) sip_raise(SIP_E_ZeroDivisionError, SIP_LIT("division by zero"), line);
    int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
    return q;
}

static inline int64_t sip_mod(int64_t a, int64_t b, int line) {
    if (SIP_UNLIKELY(b == 0)) sip_raise(SIP_E_ZeroDivisionError, SIP_LIT("modulo by zero"), line);
    int64_t r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) r += b;
    return r;
}

static inline double sip_fdiv(double a, double b, int line) {
    if (SIP_UNLIKELY(b == 0.0)) sip_raise(SIP_E_ZeroDivisionError, SIP_LIT("float division by zero"), line);
    return a / b;
}

static inline double sip_ffloordiv(double a, double b, int line) { return floor(sip_fdiv(a, b, line)); }

static inline double sip_fmod(double a, double b, int line) {
    if (SIP_UNLIKELY(b == 0.0)) sip_raise(SIP_E_ZeroDivisionError, SIP_LIT("float modulo"), line);
    double r = fmod(a, b);
    if (r != 0.0 && ((r < 0) != (b < 0))) r += b;
    return r;
}

static int64_t sip_ipow(int64_t a, int64_t b, int line) {
    if (b < 0) sip_raise(SIP_E_ValueError, SIP_LIT("negative exponent for int; use a float"), line);
    int64_t r = 1;
    while (b) { if (b & 1) r *= a; a *= a; b >>= 1; }
    return r;
}

static inline int64_t sip_round(double x) {
    /* как в Python: банковское округление */
    double r = nearbyint(x);
    return (int64_t)r;
}

static inline double sip_round_to(double x, int64_t nd) {
    double m = pow(10.0, (double)nd);
    return nearbyint(x * m) / m;
}

/* ---------- строки ---------- */

static inline bool eq_str(sip_str a, sip_str b) {
    return a.n == b.n && (a.p == b.p || memcmp(a.p, b.p, (size_t)a.n) == 0);
}

static inline int cmp_str(sip_str a, sip_str b) {
    int64_t n = a.n < b.n ? a.n : b.n;
    int c = memcmp(a.p, b.p, (size_t)n);
    if (c) return c < 0 ? -1 : 1;
    return a.n < b.n ? -1 : a.n > b.n;
}

static inline uint64_t sip_mix(uint64_t x) {
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27; x *= 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

static inline uint64_t hash_str(sip_str s) {
    uint64_t h = 0xcbf29ce484222325ULL ^ (uint64_t)s.n;
    int64_t i = 0;
    for (; i + 8 <= s.n; i += 8) {
        uint64_t w;
        memcpy(&w, s.p + i, 8);
        h = (h ^ w) * 0x100000001b3ULL;
        h ^= h >> 29;
    }
    for (; i < s.n; i++) h = (h ^ (unsigned char)s.p[i]) * 0x100000001b3ULL;
    return sip_mix(h);
}

static inline bool eq_int(int64_t a, int64_t b) { return a == b; }
static inline int cmp_int(int64_t a, int64_t b) { return (a > b) - (a < b); }
static inline uint64_t hash_int(int64_t a) { return sip_mix((uint64_t)a); }
static inline bool eq_float(double a, double b) { return a == b; }
static inline int cmp_float(double a, double b) { return (a > b) - (a < b); }
static inline uint64_t hash_float(double a) {
    if (a == (double)(int64_t)a) return hash_int((int64_t)a);  /* 1.0 и 1 — один ключ */
    uint64_t u; memcpy(&u, &a, 8); return sip_mix(u);
}
static inline bool eq_bool(bool a, bool b) { return a == b; }
static inline int cmp_bool(bool a, bool b) { return (int)a - (int)b; }
static inline uint64_t hash_bool(bool a) { return hash_int(a); }
static inline bool eq_range(sip_range a, sip_range b) { return a.lo == b.lo && a.hi == b.hi; }

static sip_str sip_str_concat(sip_str a, sip_str b) {
    if (!a.n) return b;
    if (!b.n) return a;
    char *p = sip_alloc((size_t)(a.n + b.n));
    memcpy(p, a.p, (size_t)a.n);
    memcpy(p + a.n, b.p, (size_t)b.n);
    return (sip_str){p, a.n + b.n};
}

static sip_str sip_str_repeat(sip_str s, int64_t k) {
    if (k <= 0 || !s.n) return SIP_LIT("");
    char *p = sip_alloc((size_t)(s.n * k));
    for (int64_t i = 0; i < k; i++) memcpy(p + i * s.n, s.p, (size_t)s.n);
    return (sip_str){p, s.n * k};
}

static inline sip_str sip_str_at(sip_str s, int64_t i, int line) {
    if (i < 0) i += s.n;
    if (SIP_UNLIKELY(i < 0 || i >= s.n)) sip_raise(SIP_E_IndexError, SIP_LIT("string index out of range"), line);
    return (sip_str){s.p + i, 1};
}

static inline void sip_clamp(int64_t n, int64_t *lo, int64_t *hi, bool has_lo, bool has_hi) {
    int64_t a = has_lo ? *lo : 0, b = has_hi ? *hi : n;
    if (a < 0) a += n;
    if (b < 0) b += n;
    if (a < 0) a = 0;
    if (b > n) b = n;
    if (b < a) b = a;
    *lo = a; *hi = b;
}

static inline sip_str sip_str_slice(sip_str s, int64_t lo, int64_t hi, bool has_lo, bool has_hi) {
    sip_clamp(s.n, &lo, &hi, has_lo, has_hi);
    return (sip_str){s.p + lo, hi - lo};
}

static int64_t sip_str_find(sip_str s, sip_str sub) {
    if (sub.n == 0) return 0;
    if (sub.n > s.n) return -1;
    for (int64_t i = 0; i + sub.n <= s.n; i++)
        if (s.p[i] == sub.p[0] && memcmp(s.p + i, sub.p, (size_t)sub.n) == 0) return i;
    return -1;
}

static inline bool sip_str_contains(sip_str s, sip_str sub) { return sip_str_find(s, sub) >= 0; }

static int64_t sip_str_count(sip_str s, sip_str sub) {
    if (sub.n == 0) return s.n + 1;
    int64_t c = 0;
    for (int64_t i = 0; i + sub.n <= s.n;) {
        if (memcmp(s.p + i, sub.p, (size_t)sub.n) == 0) { c++; i += sub.n; } else i++;
    }
    return c;
}

static inline bool sip_str_startswith(sip_str s, sip_str p) {
    return p.n <= s.n && memcmp(s.p, p.p, (size_t)p.n) == 0;
}

static inline bool sip_str_endswith(sip_str s, sip_str p) {
    return p.n <= s.n && memcmp(s.p + s.n - p.n, p.p, (size_t)p.n) == 0;
}

static sip_str sip_str_map(sip_str s, int upper) {
    char *p = sip_alloc((size_t)s.n);
    for (int64_t i = 0; i < s.n; i++) {
        char c = s.p[i];
        if (upper) p[i] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
        else p[i] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
    }
    return (sip_str){p, s.n};
}

static inline bool sip_isspace(char c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

static sip_str sip_str_strip(sip_str s, int left, int right) {
    int64_t a = 0, b = s.n;
    if (left) while (a < b && sip_isspace(s.p[a])) a++;
    if (right) while (b > a && sip_isspace(s.p[b - 1])) b--;
    return (sip_str){s.p + a, b - a};
}

static bool sip_str_all(sip_str s, int kind) {
    if (!s.n) return false;
    for (int64_t i = 0; i < s.n; i++) {
        char c = s.p[i];
        bool ok = kind == 0 ? (c >= '0' && c <= '9')
                : kind == 1 ? ((c | 32) >= 'a' && (c | 32) <= 'z')
                : sip_isspace(c);
        if (!ok) return false;
    }
    return true;
}

static sip_str sip_str_replace(sip_str s, sip_str old, sip_str rep) {
    if (old.n == 0) return s;
    sip_sb b = sip_sb_new();
    int64_t i = 0;
    while (i < s.n) {
        if (i + old.n <= s.n && memcmp(s.p + i, old.p, (size_t)old.n) == 0) {
            sip_sb_str(&b, rep);
            i += old.n;
        } else sip_sb_putc(&b, s.p[i++]);
    }
    return sip_sb_done(&b);
}

static int64_t sip_parse_int(sip_str s, int line) {
    sip_str t = sip_str_strip(s, 1, 1);
    char buf[64];
    if (t.n == 0 || t.n >= (int64_t)sizeof buf) goto bad;
    int64_t j = 0;
    for (int64_t i = 0; i < t.n; i++) if (t.p[i] != '_') buf[j++] = t.p[i];
    buf[j] = 0;
    char *end;
    errno = 0;
    long long v = strtoll(buf, &end, 10);
    if (*end || errno) goto bad;
    return v;
bad:
    sip_raisef(SIP_E_ParseError, line, "invalid int: '%.*s'", (int)(s.n > 40 ? 40 : s.n), s.p);
}

static double sip_parse_float(sip_str s, int line) {
    sip_str t = sip_str_strip(s, 1, 1);
    char buf[128];
    if (t.n == 0 || t.n >= (int64_t)sizeof buf) goto bad;
    memcpy(buf, t.p, (size_t)t.n);
    buf[t.n] = 0;
    char *end;
    double v = strtod(buf, &end);
    if (*end) goto bad;
    return v;
bad:
    sip_raisef(SIP_E_ParseError, line, "invalid float: '%.*s'", (int)(s.n > 40 ? 40 : s.n), s.p);
}

/* Печать float как в Python: кратчайшее число цифр, которое читается обратно.
 * Экспонента используется, если порядок < -4 или >= 16. */
static void str_float(sip_sb *b, double x) {
    char buf[48];
    if (isnan(x)) { sip_sb_put(b, "nan", 3); return; }
    if (isinf(x)) { if (x < 0) sip_sb_put(b, "-inf", 4); else sip_sb_put(b, "inf", 3); return; }
    int prec = 1;
    for (; prec < 17; prec++) {
        snprintf(buf, sizeof buf, "%.*e", prec - 1, x);
        if (strtod(buf, NULL) == x) break;
    }
    snprintf(buf, sizeof buf, "%.*e", prec - 1, x);
    int exp = atoi(strchr(buf, 'e') + 1);
    int n;
    if (exp < -4 || exp >= 16) {
        n = (int)strlen(buf);
    } else {
        int decimals = prec - 1 - exp;
        if (decimals < 1) decimals = 0;
        n = snprintf(buf, sizeof buf, "%.*f", decimals, x);
        if (decimals == 0) { buf[n++] = '.'; buf[n++] = '0'; buf[n] = 0; }
    }
    sip_sb_put(b, buf, n);
}

static inline void str_int(sip_sb *b, int64_t x) {
    char buf[24];
    char *p = buf + sizeof buf;
    uint64_t u = x < 0 ? (uint64_t)0 - (uint64_t)x : (uint64_t)x;
    do { *--p = (char)('0' + u % 10); u /= 10; } while (u);
    if (x < 0) *--p = '-';
    sip_sb_put(b, p, (int64_t)(buf + sizeof buf - p));
}

static inline void str_bool(sip_sb *b, bool x) {
    if (x) sip_sb_put(b, "True", 4); else sip_sb_put(b, "False", 5);
}

static inline void str_str(sip_sb *b, sip_str s) { sip_sb_str(b, s); }

static void str_range(sip_sb *b, sip_range r) {
    sip_sb_put(b, "range(", 6); str_int(b, r.lo); sip_sb_put(b, ", ", 2);
    str_int(b, r.hi + 1); sip_sb_putc(b, ')');
}

#define repr_int str_int
#define repr_float str_float
#define repr_bool str_bool
#define repr_range str_range

static void repr_str(sip_sb *b, sip_str s) {
    bool has_sq = memchr(s.p, '\'', (size_t)s.n) != NULL;
    bool has_dq = memchr(s.p, '"', (size_t)s.n) != NULL;
    char q = (has_sq && !has_dq) ? '"' : '\'';
    sip_sb_putc(b, q);
    for (int64_t i = 0; i < s.n; i++) {
        unsigned char c = (unsigned char)s.p[i];
        if (c == '\\') sip_sb_put(b, "\\\\", 2);
        else if (c == (unsigned char)q) { sip_sb_putc(b, '\\'); sip_sb_putc(b, (char)c); }
        else if (c == '\n') sip_sb_put(b, "\\n", 2);
        else if (c == '\t') sip_sb_put(b, "\\t", 2);
        else if (c == '\r') sip_sb_put(b, "\\r", 2);
        else if (c < 32 || c == 127) sip_sb_printf(b, "\\x%02x", c);
        else sip_sb_putc(b, (char)c);
    }
    sip_sb_putc(b, q);
}

static inline sip_str sip_int_to_str(int64_t x) { sip_sb b = sip_sb_new(); str_int(&b, x); return sip_sb_done(&b); }

/* Форматирование `{x:.2f}`: спецификация уже переведена в формат printf генератором. */
static inline void sip_fmt_float(sip_sb *b, const char *fmt, double x) { sip_sb_printf(b, fmt, x); }
static inline void sip_fmt_int(sip_sb *b, const char *fmt, int64_t x) { sip_sb_printf(b, fmt, (long long)x); }
static inline void sip_fmt_str(sip_sb *b, const char *fmt, sip_str s) { sip_sb_printf(b, fmt, (int)s.n, s.p); }

/* ---------- файлы ---------- */

static sip_str sip_read(sip_str path, int line) {
    char *cpath = sip_alloc((size_t)path.n + 1);
    memcpy(cpath, path.p, (size_t)path.n);
    cpath[path.n] = 0;
    FILE *f = fopen(cpath, "rb");
    if (!f) {
        int kind = errno == ENOENT ? SIP_E_NotFound : SIP_E_IOError;
        sip_raisef(kind, line, "%s: %s", cpath, strerror(errno));
    }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = sip_alloc((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    return (sip_str){buf, (int64_t)got};
}

static void sip_write(sip_str path, sip_str text, int line) {
    char *cpath = sip_alloc((size_t)path.n + 1);
    memcpy(cpath, path.p, (size_t)path.n);
    cpath[path.n] = 0;
    FILE *f = fopen(cpath, "wb");
    if (!f) sip_raisef(SIP_E_IOError, line, "%s: %s", cpath, strerror(errno));
    fwrite(text.p, 1, (size_t)text.n, f);
    fclose(f);
}

static sip_str sip_input(sip_str prompt) {
    if (prompt.n) { fwrite(prompt.p, 1, (size_t)prompt.n, stdout); }
    fflush(stdout);
    sip_sb b = sip_sb_new();
    int c;
    while ((c = getchar()) != EOF && c != '\n') sip_sb_putc(&b, (char)c);
    return sip_sb_done(&b);
}

/* ---------- аргументы командной строки для fn main ---------- */

static int sip_argc;
static char **sip_argv;
static char *sip_used;          /* какие argv уже разобраны */
static int sip_npos;

static void sip_args_init(int argc, char **argv) {
    sip_argc = argc;
    sip_argv = argv;
    sip_used = calloc((size_t)argc + 1, 1);
}

__attribute__((noreturn)) static void sip_usage_error(const char *usage, const char *msg, const char *arg) {
    fflush(stdout);
    fprintf(stderr, "%s%s\nusage: %s\n", msg, arg ? arg : "", usage);
    exit(2);
}

static void sip_args_help(const char *usage) {
    for (int i = 1; i < sip_argc; i++)
        if (!strcmp(sip_argv[i], "-h") || !strcmp(sip_argv[i], "--help")) {
            printf("usage: %s\n", usage);
            exit(0);
        }
}

/* Ищет --name value или --name=value. Возвращает NULL, если флага нет. */
static const char *sip_flag(const char *name, const char *usage) {
    size_t n = strlen(name);
    for (int i = 1; i < sip_argc; i++) {
        const char *a = sip_argv[i];
        if (sip_used[i] || a[0] != '-' || a[1] != '-' || strncmp(a + 2, name, n)) continue;
        if (a[2 + n] == '=') { sip_used[i] = 1; return a + 3 + n; }
        if (a[2 + n] == 0) {
            if (i + 1 >= sip_argc) sip_usage_error(usage, "missing value for --", name);
            sip_used[i] = sip_used[i + 1] = 1;
            return sip_argv[i + 1];
        }
    }
    return NULL;
}

static bool sip_flag_bool(const char *name, bool dflt) {
    size_t n = strlen(name);
    for (int i = 1; i < sip_argc; i++) {
        const char *a = sip_argv[i];
        if (sip_used[i] || a[0] != '-' || a[1] != '-') continue;
        if (!strcmp(a + 2, name)) { sip_used[i] = 1; return true; }
        if (!strncmp(a + 2, "no-", 3) && !strcmp(a + 5, name)) { sip_used[i] = 1; return false; }
        (void)n;
    }
    return dflt;
}

static const char *sip_positional(int index, const char *name, const char *usage) {
    int k = 0;
    for (int i = 1; i < sip_argc; i++) {
        const char *a = sip_argv[i];
        if (sip_used[i] || (a[0] == '-' && a[1] == '-' && a[2])) continue;
        if (k++ == index) { sip_used[i] = 1; return a; }
    }
    sip_usage_error(usage, "missing argument: ", name);
}

/* следующий ещё не разобранный позиционный аргумент (для *args у main) */
static const char *sip_rest_next(void) {
    for (int i = 1; i < sip_argc; i++) {
        const char *a = sip_argv[i];
        if (sip_used[i] || (a[0] == '-' && a[1] == '-' && a[2])) continue;
        sip_used[i] = 1;
        return a;
    }
    return NULL;
}

static void sip_args_done(const char *usage) {
    for (int i = 1; i < sip_argc; i++)
        if (!sip_used[i]) sip_usage_error(usage, "unexpected argument: ", sip_argv[i]);
}

static inline sip_str sip_cstr(const char *s) { return (sip_str){s, (int64_t)strlen(s)}; }

static int64_t sip_arg_int(const char *s, const char *name, const char *usage) {
    char *end;
    errno = 0;
    long long v = strtoll(s, &end, 10);
    if (!*s || *end || errno) sip_usage_error(usage, "expected an integer for ", name);
    return v;
}

static double sip_arg_float(const char *s, const char *name, const char *usage) {
    char *end;
    double v = strtod(s, &end);
    if (!*s || *end) sip_usage_error(usage, "expected a number for ", name);
    return v;
}

static bool sip_arg_bool(const char *s, const char *name, const char *usage) {
    if (!strcmp(s, "true") || !strcmp(s, "1") || !strcmp(s, "yes")) return true;
    if (!strcmp(s, "false") || !strcmp(s, "0") || !strcmp(s, "no")) return false;
    sip_usage_error(usage, "expected true or false for ", name);
}

/* ---------- math, random, time ---------- */
#include <time.h>

static inline double sip_sqrt(double x, int line) {
    if (SIP_UNLIKELY(x < 0)) sip_raise(SIP_E_ValueError, SIP_LIT("math domain error"), line);
    return sqrt(x);
}

static inline double sip_log(double x, int line) {
    if (SIP_UNLIKELY(x <= 0)) sip_raise(SIP_E_ValueError, SIP_LIT("math domain error"), line);
    return log(x);
}

static inline int64_t sip_gcd(int64_t a, int64_t b) {
    if (a < 0) a = -a;
    if (b < 0) b = -b;
    while (b) { int64_t t = a % b; a = b; b = t; }
    return a;
}

static uint64_t sip_rng = 0;

static inline uint64_t sip_rand_next(void) {  /* splitmix64 */
    if (SIP_UNLIKELY(!sip_rng)) {
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        sip_rng = (uint64_t)ts.tv_nsec ^ ((uint64_t)ts.tv_sec << 32) ^ (uint64_t)(uintptr_t)&ts;
        if (!sip_rng) sip_rng = 1;
    }
    uint64_t z = (sip_rng += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

static inline void sip_rand_seed(uint64_t s) { sip_rng = s * 0x2545F4914F6CDD1Dull + 1; }

static inline double sip_rand_float(void) { return (double)(sip_rand_next() >> 11) * 0x1.0p-53; }

static inline int64_t sip_rand_int(int64_t a, int64_t b, int line) {
    if (SIP_UNLIKELY(a > b)) sip_raise(SIP_E_ValueError, SIP_LIT("empty range for randint"), line);
    uint64_t span = (uint64_t)(b - a) + 1;
    if (!span) return (int64_t)sip_rand_next();
    uint64_t lim = UINT64_MAX - UINT64_MAX % span, r;
    do r = sip_rand_next(); while (r >= lim);
    return a + (int64_t)(r % span);
}

static inline double sip_time_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static inline double sip_perf_counter(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec * 1e-9;
}

static inline void sip_sleep(double s) {
    if (s <= 0) return;
    struct timespec ts = {(time_t)s, (long)((s - (double)(time_t)s) * 1e9)};
    SIP_BLOCKING_BEGIN
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR) {}
    SIP_BLOCKING_END
}

/* ---------- JSON ----------
 * Разбор сразу в нужный тип: для каждого типа компилятор генерирует jdec_K,
 * которая читает текст через функции ниже. Путь ($.users[0].age) — для ошибок. */

typedef struct { const char *s; int64_t n, i; int line; sip_sb path; } sip_jp;

static sip_jp sip_jp_new(sip_str s, int line) {
    sip_jp p = {s.p, s.n, 0, line, sip_sb_new()};
    sip_sb_putc(&p.path, '$');
    return p;
}

static void sip_jp_pos(sip_jp *p, int64_t *ln, int64_t *col) {
    *ln = 1; *col = 1;
    for (int64_t k = 0; k < p->i && k < p->n; k++) {
        if (p->s[k] == '\n') { (*ln)++; *col = 1; } else (*col)++;
    }
}

__attribute__((noreturn, cold)) static void sip_jp_syntax(sip_jp *p, const char *what) {
    int64_t ln, col;
    sip_jp_pos(p, &ln, &col);
    sip_raisef(SIP_E_ParseError, p->line, "invalid JSON: %s (line %lld, column %lld)", what,
               (long long)ln, (long long)col);
}

static inline void sip_jp_ws(sip_jp *p) {
    while (p->i < p->n) {
        char c = p->s[p->i];
        if (c != ' ' && c != '\t' && c != '\n' && c != '\r') break;
        p->i++;
    }
}

static inline char sip_jp_peek(sip_jp *p) {
    sip_jp_ws(p);
    return p->i < p->n ? p->s[p->i] : 0;
}

static const char *sip_jp_kind(sip_jp *p) {
    switch (sip_jp_peek(p)) {
    case '"': return "string";
    case '{': return "object";
    case '[': return "array";
    case 't': case 'f': return "bool";
    case 'n': return "null";
    case 0: return "end of input";
    default: return (p->s[p->i] == '-' || (p->s[p->i] >= '0' && p->s[p->i] <= '9')) ? "number" : "invalid value";
    }
}

/* «ожидали X, а пришло Y» с путём до значения */
__attribute__((noreturn, cold)) static void sip_jp_type(sip_jp *p, const char *want) {
    const char *got = sip_jp_kind(p);
    if (!strcmp(got, "invalid value")) sip_jp_syntax(p, "unexpected character");
    int64_t ln, col;
    sip_jp_pos(p, &ln, &col);
    sip_raisef(SIP_E_ParseError, p->line, "JSON %.*s: expected %s, got %s (line %lld, column %lld)",
               (int)p->path.n, p->path.p, want, got, (long long)ln, (long long)col);
}

__attribute__((noreturn, cold)) static void sip_jp_fail(sip_jp *p, const char *msg) {
    sip_raisef(SIP_E_ParseError, p->line, "JSON %.*s: %s", (int)p->path.n, p->path.p, msg);
}

static inline void sip_jp_want(sip_jp *p, char c, const char *what) {
    if (sip_jp_peek(p) != c) sip_jp_type(p, what);
    p->i++;
}

static inline bool sip_jp_word(sip_jp *p, const char *w, int64_t n) {
    if (p->n - p->i >= n && !memcmp(p->s + p->i, w, (size_t)n)) { p->i += n; return true; }
    return false;
}

static inline bool sip_jp_null(sip_jp *p) {
    return sip_jp_peek(p) == 'n' && sip_jp_word(p, "null", 4);
}

static bool sip_jp_bool(sip_jp *p) {
    char c = sip_jp_peek(p);
    if (c == 't' && sip_jp_word(p, "true", 4)) return true;
    if (c == 'f' && sip_jp_word(p, "false", 5)) return false;
    sip_jp_type(p, "bool");
}

static void sip_utf8_put(sip_sb *b, uint32_t cp) {
    if (cp < 0x80) sip_sb_putc(b, (char)cp);
    else if (cp < 0x800) { sip_sb_putc(b, (char)(0xC0 | cp >> 6)); sip_sb_putc(b, (char)(0x80 | (cp & 63))); }
    else if (cp < 0x10000) {
        sip_sb_putc(b, (char)(0xE0 | cp >> 12)); sip_sb_putc(b, (char)(0x80 | ((cp >> 6) & 63)));
        sip_sb_putc(b, (char)(0x80 | (cp & 63)));
    } else {
        sip_sb_putc(b, (char)(0xF0 | cp >> 18)); sip_sb_putc(b, (char)(0x80 | ((cp >> 12) & 63)));
        sip_sb_putc(b, (char)(0x80 | ((cp >> 6) & 63))); sip_sb_putc(b, (char)(0x80 | (cp & 63)));
    }
}

static int sip_jp_hex4(sip_jp *p) {
    if (p->n - p->i < 4) sip_jp_syntax(p, "bad \\u escape");
    int v = 0;
    for (int k = 0; k < 4; k++) {
        char c = p->s[p->i++];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else { p->i--; sip_jp_syntax(p, "bad \\u escape"); }
    }
    return v;
}

static sip_str sip_jp_str(sip_jp *p) {
    sip_jp_want(p, '"', "string");
    int64_t start = p->i;
    while (p->i < p->n && p->s[p->i] != '"' && p->s[p->i] != '\\' && (unsigned char)p->s[p->i] >= 0x20) p->i++;
    if (p->i < p->n && p->s[p->i] == '"') {  /* без экранирования — строка указывает в исходный текст */
        sip_str r = {p->s + start, p->i - start};
        p->i++;
        return r;
    }
    sip_sb b = sip_sb_new();
    sip_sb_put(&b, p->s + start, p->i - start);
    for (;;) {
        if (p->i >= p->n) sip_jp_syntax(p, "unterminated string");
        char c = p->s[p->i++];
        if (c == '"') break;
        if ((unsigned char)c < 0x20) { p->i--; sip_jp_syntax(p, "control character in string"); }
        if (c != '\\') { sip_sb_putc(&b, c); continue; }
        if (p->i >= p->n) sip_jp_syntax(p, "unterminated string");
        c = p->s[p->i++];
        switch (c) {
        case '"': case '\\': case '/': sip_sb_putc(&b, c); break;
        case 'b': sip_sb_putc(&b, '\b'); break;
        case 'f': sip_sb_putc(&b, '\f'); break;
        case 'n': sip_sb_putc(&b, '\n'); break;
        case 'r': sip_sb_putc(&b, '\r'); break;
        case 't': sip_sb_putc(&b, '\t'); break;
        case 'u': {
            uint32_t cp = (uint32_t)sip_jp_hex4(p);
            if (cp >= 0xD800 && cp < 0xDC00 && p->n - p->i >= 6 && p->s[p->i] == '\\' && p->s[p->i + 1] == 'u') {
                int64_t save = p->i;
                p->i += 2;
                uint32_t lo = (uint32_t)sip_jp_hex4(p);
                if (lo >= 0xDC00 && lo < 0xE000) cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                else p->i = save;
            }
            sip_utf8_put(&b, cp);
            break;
        }
        default: p->i--; sip_jp_syntax(p, "bad escape");
        }
    }
    return sip_sb_done(&b);
}

/* число: границы токена; is_int — без дробной части и экспоненты */
static int64_t sip_jp_num(sip_jp *p, bool *is_int) {
    char c = sip_jp_peek(p);
    if (c != '-' && !(c >= '0' && c <= '9')) {
        if (c == 'N' && sip_jp_word(p, "NaN", 3)) { *is_int = false; return -1; }
        if (c == 'I' && sip_jp_word(p, "Infinity", 8)) { *is_int = false; return -2; }
        sip_jp_type(p, "number");
    }
    int64_t start = p->i;
    if (p->s[p->i] == '-') {
        p->i++;
        if (sip_jp_word(p, "Infinity", 8)) { *is_int = false; return -3; }
    }
    if (p->i >= p->n || !(p->s[p->i] >= '0' && p->s[p->i] <= '9')) sip_jp_syntax(p, "bad number");
    if (p->s[p->i] == '0') p->i++;
    else while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
    *is_int = true;
    if (p->i < p->n && p->s[p->i] == '.') {
        *is_int = false;
        p->i++;
        if (p->i >= p->n || !(p->s[p->i] >= '0' && p->s[p->i] <= '9')) sip_jp_syntax(p, "bad number");
        while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
    }
    if (p->i < p->n && (p->s[p->i] == 'e' || p->s[p->i] == 'E')) {
        *is_int = false;
        p->i++;
        if (p->i < p->n && (p->s[p->i] == '+' || p->s[p->i] == '-')) p->i++;
        if (p->i >= p->n || !(p->s[p->i] >= '0' && p->s[p->i] <= '9')) sip_jp_syntax(p, "bad number");
        while (p->i < p->n && p->s[p->i] >= '0' && p->s[p->i] <= '9') p->i++;
    }
    return start;
}

static int64_t sip_jp_int(sip_jp *p) {
    bool is_int;
    int64_t save = p->i;
    int64_t start = sip_jp_num(p, &is_int);
    if (!is_int) {
        int64_t ln, col;
        p->i = save;
        sip_jp_pos(p, &ln, &col);
        sip_raisef(SIP_E_ParseError, p->line, "JSON %.*s: expected int, got float (line %lld, column %lld)",
                   (int)p->path.n, p->path.p, (long long)ln, (long long)col);
    }
    char buf[32];
    int64_t len = p->i - start;
    errno = 0;
    if (len >= (int64_t)sizeof buf) { p->i = save; sip_jp_fail(p, "integer out of range"); }
    memcpy(buf, p->s + start, (size_t)len);
    buf[len] = 0;
    long long v = strtoll(buf, NULL, 10);
    if (errno == ERANGE) { p->i = save; sip_jp_fail(p, "integer out of range"); }
    return (int64_t)v;
}

static double sip_jp_float(sip_jp *p) {
    bool is_int;
    int64_t start = sip_jp_num(p, &is_int);
    if (start == -1) return NAN;
    if (start == -2) return INFINITY;
    if (start == -3) return -INFINITY;
    char buf[64];
    int64_t len = p->i - start;
    if (len < (int64_t)sizeof buf) {
        memcpy(buf, p->s + start, (size_t)len);
        buf[len] = 0;
        return strtod(buf, NULL);
    }
    char *big = malloc((size_t)len + 1);
    memcpy(big, p->s + start, (size_t)len);
    big[len] = 0;
    double v = strtod(big, NULL);
    free(big);
    return v;
}

static void sip_jp_skip(sip_jp *p);

/* обход массива: for (i = 0; sip_jp_arr_next(p, i); i++) — после '[' */
static inline bool sip_jp_arr_next(sip_jp *p, int64_t i) {
    char c = sip_jp_peek(p);
    if (c == ']') { p->i++; return false; }
    if (i > 0) {
        if (c != ',') sip_jp_syntax(p, "expected ',' or ']'");
        p->i++;
    } else if (c == 0) sip_jp_syntax(p, "expected ']'");
    return true;
}

/* обход объекта: после '{', ключ кладётся в *key */
static inline bool sip_jp_obj_next(sip_jp *p, int64_t i, sip_str *key) {
    char c = sip_jp_peek(p);
    if (c == '}') { p->i++; return false; }
    if (i > 0) {
        if (c != ',') sip_jp_syntax(p, "expected ',' or '}'");
        p->i++;
    }
    if (sip_jp_peek(p) != '"') sip_jp_syntax(p, "expected a string key");
    *key = sip_jp_str(p);
    if (sip_jp_peek(p) != ':') sip_jp_syntax(p, "expected ':'");
    p->i++;
    return true;
}

static void sip_jp_skip(sip_jp *p) {
    char c = sip_jp_peek(p);
    if (c == '"') { sip_jp_str(p); return; }
    if (c == '{') {
        p->i++;
        sip_str k;
        for (int64_t i = 0; sip_jp_obj_next(p, i, &k); i++) sip_jp_skip(p);
        return;
    }
    if (c == '[') {
        p->i++;
        for (int64_t i = 0; sip_jp_arr_next(p, i); i++) sip_jp_skip(p);
        return;
    }
    if (c == 't' || c == 'f') { sip_jp_bool(p); return; }
    if (sip_jp_null(p)) return;
    bool is_int;
    if (c == '-' || (c >= '0' && c <= '9') || c == 'N' || c == 'I') { sip_jp_num(p, &is_int); return; }
    sip_jp_syntax(p, c ? "unexpected character" : "unexpected end of input");
}

static inline int64_t sip_jp_path_idx(sip_jp *p, int64_t i) {
    int64_t mark = p->path.n;
    sip_sb_printf(&p->path, "[%lld]", (long long)i);
    return mark;
}

static inline int64_t sip_jp_path_key(sip_jp *p, sip_str k) {
    int64_t mark = p->path.n;
    sip_sb_putc(&p->path, '.');
    sip_sb_str(&p->path, k);
    return mark;
}

static inline bool sip_str_is(sip_str s, const char *lit, int64_t n) {
    return s.n == n && !memcmp(s.p, lit, (size_t)n);
}

static int64_t sip_jp_key_int(sip_jp *p, sip_str k) {
    int64_t i = (k.n && k.p[0] == '-') ? 1 : 0;
    bool ok = k.n > i && k.n < 21;
    for (int64_t j = i; ok && j < k.n; j++) ok = k.p[j] >= '0' && k.p[j] <= '9';
    if (!ok) sip_jp_fail(p, "object key is not an int");
    char buf[24];
    memcpy(buf, k.p, (size_t)k.n);
    buf[k.n] = 0;
    errno = 0;
    long long v = strtoll(buf, NULL, 10);
    if (errno == ERANGE) sip_jp_fail(p, "integer out of range");
    return (int64_t)v;
}

static inline void sip_jp_end(sip_jp *p) {
    if (sip_jp_peek(p) != 0) sip_jp_syntax(p, "extra data after the value");
}

/* поиск поля "type" у объекта (для типов-сумм), позиция не меняется */
static sip_str sip_jp_tag(sip_jp *p) {
    int64_t save = p->i;
    sip_jp_want(p, '{', "object");
    sip_str k, tag = {NULL, -1};
    for (int64_t i = 0; sip_jp_obj_next(p, i, &k); i++) {
        if (sip_str_is(k, "type", 4) && sip_jp_peek(p) == '"') tag = sip_jp_str(p);
        else sip_jp_skip(p);
    }
    p->i = save;
    if (tag.n < 0) sip_jp_fail(p, "object has no \"type\" field");
    return tag;
}

/* вывод: ind < 0 — в одну строку, как json.dumps; иначе с отступом ind */
static inline void sip_je_sep(sip_sb *b, int64_t ind, int64_t depth, bool first) {
    if (!first) sip_sb_putc(b, ',');
    if (ind < 0) { if (!first) sip_sb_putc(b, ' '); return; }
    sip_sb_putc(b, '\n');
    for (int64_t k = 0; k < ind * depth; k++) sip_sb_putc(b, ' ');
}

static inline void sip_je_close(sip_sb *b, int64_t ind, int64_t depth, char c) {
    if (ind >= 0) sip_je_sep(b, ind, depth, true);
    sip_sb_putc(b, c);
}

static void sip_je_str(sip_sb *b, sip_str s) {
    static const char hex[] = "0123456789abcdef";
    sip_sb_putc(b, '"');
    for (int64_t i = 0; i < s.n; i++) {
        unsigned char c = (unsigned char)s.p[i];
        if (c == '"') sip_sb_put(b, "\\\"", 2);
        else if (c == '\\') sip_sb_put(b, "\\\\", 2);
        else if (c == '\n') sip_sb_put(b, "\\n", 2);
        else if (c == '\r') sip_sb_put(b, "\\r", 2);
        else if (c == '\t') sip_sb_put(b, "\\t", 2);
        else if (c == '\b') sip_sb_put(b, "\\b", 2);
        else if (c == '\f') sip_sb_put(b, "\\f", 2);
        else if (c < 0x20) {
            char e[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
            sip_sb_put(b, e, 6);
        } else sip_sb_putc(b, (char)c);
    }
    sip_sb_putc(b, '"');
}

static void sip_je_float(sip_sb *b, double x) {
    if (isnan(x)) sip_sb_put(b, "NaN", 3);
    else if (isinf(x)) { if (x < 0) sip_sb_put(b, "-Infinity", 9); else sip_sb_put(b, "Infinity", 8); }
    else str_float(b, x);
}

static inline void sip_je_bool(sip_sb *b, bool x) {
    if (x) sip_sb_put(b, "true", 4); else sip_sb_put(b, "false", 5);
}

/* ---------- CSV ----------
 * Диалект Python по умолчанию: поля в кавычках с "" внутри, строки \n, \r\n или \r,
 * при записи кавычки ставятся только там, где нужны, строки кончаются \r\n. */

typedef struct {
    const char *s; int64_t n, i;
    char d; int line;
    int64_t row_line, next_line;  /* номер строки файла: для ошибок */
    sip_str *f; int64_t nf, cap;
} sip_csv;

static char sip_csv_delim(sip_str d, int line) {
    if (d.n != 1) sip_raise(SIP_E_ValueError, SIP_LIT("delimiter must be a 1-character string"), line);
    return d.p[0];
}

static sip_csv sip_csv_new(sip_str text, sip_str delim, int line) {
    sip_csv c = {text.p, text.n, 0, sip_csv_delim(delim, line), line, 1, 1, NULL, 0, 0};
    return c;
}

static inline void sip_csv_push(sip_csv *c, sip_str f) {
    if (c->nf == c->cap) {
        c->cap = c->cap ? c->cap * 2 : 16;
        c->f = sip_realloc(c->f, (size_t)c->cap * sizeof(sip_str));
    }
    c->f[c->nf++] = f;
}

/* следующая запись файла: поля в c->f[0..nf); false — данных больше нет */
static bool sip_csv_row(sip_csv *c) {
    const char *s = c->s;
    int64_t n = c->n;
    if (c->i >= n) return false;
    c->nf = 0;
    c->row_line = c->next_line;
    if (s[c->i] == '\n' || s[c->i] == '\r') {  /* пустая строка — запись без полей */
        if (s[c->i] == '\r' && c->i + 1 < n && s[c->i + 1] == '\n') c->i++;
        c->i++;
        c->next_line++;
        return true;
    }
    for (;;) {
        if (c->i < n && s[c->i] == '"') {
            sip_sb b = sip_sb_new();
            c->i++;
            for (;;) {
                if (c->i >= n) break;
                char ch = s[c->i];
                if (ch == '"') {
                    if (c->i + 1 < n && s[c->i + 1] == '"') { sip_sb_putc(&b, '"'); c->i += 2; continue; }
                    c->i++;
                    break;
                }
                if (ch == '\n') c->next_line++;
                sip_sb_putc(&b, ch);
                c->i++;
            }
            /* после закрывающей кавычки — как в Python: всё до разделителя дописывается в поле */
            while (c->i < n && s[c->i] != c->d && s[c->i] != '\n' && s[c->i] != '\r') sip_sb_putc(&b, s[c->i++]);
            sip_csv_push(c, sip_sb_done(&b));
        } else {
            int64_t start = c->i;
            while (c->i < n && s[c->i] != c->d && s[c->i] != '\n' && s[c->i] != '\r') c->i++;
            sip_csv_push(c, (sip_str){s + start, c->i - start});
        }
        if (c->i >= n) return true;
        char ch = s[c->i];
        if (ch == c->d) {
            c->i++;
            if (c->i >= n) { sip_csv_push(c, (sip_str){"", 0}); return true; }
            continue;
        }
        if (ch == '\r' && c->i + 1 < n && s[c->i + 1] == '\n') c->i++;
        c->i++;
        c->next_line++;
        return true;
    }
}

static inline sip_str sip_csv_cell(sip_csv *c, int64_t i) {
    return (i >= 0 && i < c->nf) ? c->f[i] : (sip_str){"", 0};
}

static int64_t sip_csv_col(sip_str *hdr, int64_t nh, sip_str name) {
    for (int64_t i = 0; i < nh; i++) if (hdr[i].n == name.n && !memcmp(hdr[i].p, name.p, (size_t)name.n)) return i;
    return -1;
}

static sip_str *sip_csv_header(sip_csv *c) {
    sip_str *h = sip_alloc((size_t)(c->nf ? c->nf : 1) * sizeof(sip_str));
    memcpy(h, c->f, (size_t)c->nf * sizeof(sip_str));
    return h;
}

__attribute__((noreturn, cold)) static void sip_csv_bad(sip_csv *c, int64_t i, sip_str col, const char *what) {
    sip_str v = sip_csv_cell(c, i);
    if (col.n)
        sip_raisef(SIP_E_ParseError, c->line, "CSV line %lld, column '%.*s': invalid %s: '%.*s'",
                   (long long)c->row_line, (int)col.n, col.p, what, (int)(v.n > 40 ? 40 : v.n), v.p);
    sip_raisef(SIP_E_ParseError, c->line, "CSV line %lld, column %lld: invalid %s: '%.*s'",
               (long long)c->row_line, (long long)i + 1, what, (int)(v.n > 40 ? 40 : v.n), v.p);
}

static int64_t sip_csv_int(sip_csv *c, int64_t i, sip_str col) {
    sip_str t = sip_str_strip(sip_csv_cell(c, i), 1, 1);
    char buf[64];
    if (t.n == 0 || t.n >= (int64_t)sizeof buf) sip_csv_bad(c, i, col, "int");
    int64_t j = 0;
    for (int64_t k = 0; k < t.n; k++) if (t.p[k] != '_') buf[j++] = t.p[k];
    buf[j] = 0;
    char *end;
    errno = 0;
    long long v = strtoll(buf, &end, 10);
    if (*end || errno) sip_csv_bad(c, i, col, "int");
    return v;
}

static double sip_csv_float(sip_csv *c, int64_t i, sip_str col) {
    sip_str t = sip_str_strip(sip_csv_cell(c, i), 1, 1);
    char buf[128];
    if (t.n == 0 || t.n >= (int64_t)sizeof buf) sip_csv_bad(c, i, col, "float");
    memcpy(buf, t.p, (size_t)t.n);
    buf[t.n] = 0;
    char *end;
    double v = strtod(buf, &end);
    if (*end) sip_csv_bad(c, i, col, "float");
    return v;
}

static bool sip_csv_bool(sip_csv *c, int64_t i, sip_str col) {
    sip_str t = sip_str_strip(sip_csv_cell(c, i), 1, 1);
    if (sip_str_is(t, "true", 4) || sip_str_is(t, "True", 4) || sip_str_is(t, "1", 1) || sip_str_is(t, "yes", 3))
        return true;
    if (sip_str_is(t, "false", 5) || sip_str_is(t, "False", 5) || sip_str_is(t, "0", 1) || sip_str_is(t, "no", 2) ||
        t.n == 0)
        return false;
    sip_csv_bad(c, i, col, "bool");
}

static void sip_csv_put(sip_sb *b, sip_str s, char d) {
    bool q = false;
    for (int64_t i = 0; i < s.n && !q; i++) q = s.p[i] == d || s.p[i] == '"' || s.p[i] == '\n' || s.p[i] == '\r';
    if (!q) { sip_sb_str(b, s); return; }
    sip_sb_putc(b, '"');
    for (int64_t i = 0; i < s.n; i++) {
        if (s.p[i] == '"') sip_sb_putc(b, '"');
        sip_sb_putc(b, s.p[i]);
    }
    sip_sb_putc(b, '"');
}

/* ---------- HTTP (libcurl; подключается, только если программа пользуется http) ---------- */
#ifdef SIP_USE_HTTP
#include <curl/curl.h>
#include <pthread.h>
#include <ctype.h>

typedef struct { int64_t status; sip_str body, url; sip_str *hk, *hv; int64_t nh, hcap; } sip_http_resp;

static pthread_once_t sip_http_once = PTHREAD_ONCE_INIT;
static void sip_http_init(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

/* во время запроса другие потоки могут выполнять код Sip, поэтому здесь только malloc */
typedef struct { char *p; size_t n, cap; } sip_mbuf;

static size_t sip_http_wbuf(char *p, size_t sz, size_t n, void *ud) {
    sip_mbuf *b = ud;
    size_t len = sz * n;
    if (b->n + len > b->cap) {
        size_t cap = b->cap ? b->cap : 4096;
        while (cap < b->n + len) cap *= 2;
        char *np = realloc(b->p, cap);
        if (!np) return 0;
        b->p = np;
        b->cap = cap;
    }
    memcpy(b->p + b->n, p, len);
    b->n += len;
    return len;
}

/* заголовки ответа; имена — в нижнем регистре. После редиректа список начинается заново. */
static void sip_http_headers(sip_http_resp *r, const char *p, size_t total) {
    size_t i = 0;
    while (i < total) {
        const char *line = p + i;
        const char *nl = memchr(line, '\n', total - i);
        size_t len = nl ? (size_t)(nl - line) + 1 : total - i;
        i += len;
        if (len >= 5 && !memcmp(line, "HTTP/", 5)) { r->nh = 0; continue; }
        const char *colon = memchr(line, ':', len);
        if (!colon) continue;
        int64_t kn = colon - line;
        const char *v = colon + 1;
        int64_t vn = (int64_t)len - kn - 1;
        while (vn > 0 && (*v == ' ' || *v == '\t')) { v++; vn--; }
        while (vn > 0 && (v[vn - 1] == '\r' || v[vn - 1] == '\n' || v[vn - 1] == ' ')) vn--;
        char *k = sip_alloc((size_t)kn + 1);
        for (int64_t j = 0; j < kn; j++) k[j] = (char)tolower((unsigned char)line[j]);
        char *vv = sip_alloc((size_t)vn + 1);
        memcpy(vv, v, (size_t)vn);
        if (r->nh == r->hcap) {
            r->hcap = r->hcap ? r->hcap * 2 : 16;
            r->hk = sip_realloc(r->hk, (size_t)r->hcap * sizeof(sip_str));
            r->hv = sip_realloc(r->hv, (size_t)r->hcap * sizeof(sip_str));
        }
        r->hk[r->nh] = (sip_str){k, kn};
        r->hv[r->nh] = (sip_str){vv, vn};
        r->nh++;
    }
}

static char *sip_to_c(sip_str s) {
    char *c = sip_alloc((size_t)s.n + 1);
    memcpy(c, s.p, (size_t)s.n);
    c[s.n] = 0;
    return c;
}

static struct curl_slist *sip_http_header(struct curl_slist *h, sip_str k, sip_str v) {
    sip_sb b = sip_sb_new();
    sip_sb_str(&b, k);
    sip_sb_put(&b, ": ", 2);
    sip_sb_str(&b, v);
    sip_sb_putc(&b, 0);
    return curl_slist_append(h, b.p);
}

/* body == NULL — GET. Ошибка сети — IOError, ответ 4xx/5xx — HttpError. */
static sip_http_resp sip_http_do(const char *method, sip_str url, const sip_str *body, struct curl_slist *hdrs,
                                 double timeout, int line) {
    pthread_once(&sip_http_once, sip_http_init);
    CURL *c = curl_easy_init();
    if (!c) sip_raise(SIP_E_IOError, SIP_LIT("http: cannot start libcurl"), line);
    sip_http_resp r = {0};
    sip_mbuf out = {0}, hbuf = {0};
    char err[CURL_ERROR_SIZE] = {0};
    char *curl = sip_to_c(url);
    curl_easy_setopt(c, CURLOPT_URL, curl);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_ACCEPT_ENCODING, "");
    curl_easy_setopt(c, CURLOPT_USERAGENT, "sip/0.2");
    curl_easy_setopt(c, CURLOPT_ERRORBUFFER, err);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, sip_http_wbuf);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &out);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, sip_http_wbuf);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &hbuf);
    if (timeout > 0) curl_easy_setopt(c, CURLOPT_TIMEOUT_MS, (long)(timeout * 1000));
    if (body) {
        curl_easy_setopt(c, CURLOPT_POST, 1L);
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, body->p);
        curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body->n);
    }
    if (strcmp(method, "GET") && strcmp(method, "POST")) curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, method);
    if (hdrs) curl_easy_setopt(c, CURLOPT_HTTPHEADER, hdrs);
    SIP_BLOCKING_BEGIN
    CURLcode rc = curl_easy_perform(c);
    SIP_BLOCKING_END
    if (hdrs) curl_slist_free_all(hdrs);
    long status = 0;
    char *eff = NULL;
    if (rc == CURLE_OK) {
        curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
        curl_easy_getinfo(c, CURLINFO_EFFECTIVE_URL, &eff);
        r.status = status;
        if (eff) {
            int64_t n = (int64_t)strlen(eff);
            char *u = sip_alloc((size_t)n + 1);
            memcpy(u, eff, (size_t)n + 1);
            r.url = (sip_str){u, n};
        } else r.url = url;
        char *bp = sip_alloc(out.n ? out.n : 1);
        memcpy(bp, out.p ? out.p : "", out.n);
        r.body = (sip_str){bp, (int64_t)out.n};
        sip_http_headers(&r, hbuf.p ? hbuf.p : "", hbuf.n);
    }
    free(out.p);
    free(hbuf.p);
    curl_easy_cleanup(c);
    if (rc != CURLE_OK)
        sip_raisef(SIP_E_IOError, line, "http: %s (%.*s)", err[0] ? err : curl_easy_strerror(rc),
                   (int)(url.n > 200 ? 200 : url.n), url.p);
    if (status >= 400)
        sip_raisef(SIP_E_HttpError, line, "HTTP %ld for %.*s", status, (int)(url.n > 200 ? 200 : url.n), url.p);
    return r;
}
#endif

/* ---------- задачи (async fn) ---------- */
#ifdef SIP_USE_ASYNC
typedef struct sip_task {
    void (*run)(struct sip_task *);
    int state;  /* 0 — не запускалась, 1 — выполняется, 2 — готова, 3 — ошибка */
    int ek, el;
    sip_str em;
} sip_task;

/* выполнить задачу в текущем потоке; ошибка запоминается в задаче */
static void sip_task_exec(sip_task *t) {
    sip_try fr;
    t->state = 1;
    sip_try_push(&fr);
    if (setjmp(fr.jb) == 0) {
        t->run(t);
        sip_try_pop();
        t->state = 2;
    } else {
        t->state = 3;
        t->ek = sip_err_kind;
        t->em = sip_err_msg;
        t->el = sip_err_line;
    }
}

static void sip_task_await(sip_task *t, int line) {
    if (t->state == 0) sip_task_exec(t);
    else if (t->state == 1) sip_raise(SIP_E_Error, SIP_LIT("a task cannot await itself"), line);
    if (t->state == 3) sip_raise(t->ek, t->em, t->el);
}

typedef struct { sip_task **ts; int64_t n, next; } sip_pool;

static void *sip_worker(void *arg) {
    sip_pool *p = arg;
    pthread_mutex_lock(&sip_gil);
    while (p->next < p->n) {
        sip_task *t = p->ts[p->next++];
        if (t->state != 0) continue;
        sip_try_top = NULL;
        sip_task_exec(t);
    }
    pthread_mutex_unlock(&sip_gil);
    return NULL;
}

#define SIP_MAX_WORKERS 64

/* await all(...): задачи выполняются одновременно; первая ошибка (по порядку) пробрасывается */
static void sip_gather(sip_task **ts, int64_t n, int line) {
    int64_t todo = 0;
    for (int64_t i = 0; i < n; i++) todo += ts[i]->state == 0;
    if (todo == 1) {
        for (int64_t i = 0; i < n; i++) if (ts[i]->state == 0) sip_task_exec(ts[i]);
    } else if (todo > 1) {
        if (!sip_threaded) { pthread_mutex_lock(&sip_gil); sip_threaded = true; }
        int64_t nw = todo < SIP_MAX_WORKERS ? todo : SIP_MAX_WORKERS;
        sip_pool pool = {ts, n, 0};
        pthread_t th[SIP_MAX_WORKERS];
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, (size_t)64 << 20);
        int64_t started = 0;
        sip_tstate st = sip_gil_release();
        for (int64_t i = 0; i < nw; i++) {
            if (pthread_create(&th[started], &attr, sip_worker, &pool) == 0) started++;
        }
        if (started == 0) sip_worker(&pool);  /* потоки не создались — выполнить по очереди */
        for (int64_t i = 0; i < started; i++) pthread_join(th[i], NULL);
        sip_gil_acquire(st);
        pthread_attr_destroy(&attr);
    }
    for (int64_t i = 0; i < n; i++) {
        if (ts[i]->state == 3) sip_raise(ts[i]->ek, ts[i]->em, ts[i]->el);
        if (ts[i]->state == 1) sip_raise(SIP_E_Error, SIP_LIT("a task cannot await itself"), line);
    }
}
#endif
