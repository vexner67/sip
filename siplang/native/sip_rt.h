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
    SIP_E_ValueError, SIP_E_ZeroDivisionError, SIP_E_AssertionError, SIP_E_IOError
};
static const char *const sip_err_names[] = {
    "Error", "NotFound", "ParseError", "IndexError", "KeyError",
    "ValueError", "ZeroDivisionError", "AssertionError", "IOError"
};

typedef struct sip_try { jmp_buf jb; struct sip_try *prev; } sip_try;
static sip_try *sip_try_top;
static int sip_err_kind;
static sip_str sip_err_msg;
static int sip_err_line;

static inline void sip_try_push(sip_try *t) { t->prev = sip_try_top; sip_try_top = t; }
static inline void sip_try_pop(void) { sip_try_top = sip_try_top->prev; }

static bool sip_kind_matches(int kind, int want) {
    if (kind == want) return true;
    return want == SIP_E_ValueError && kind == SIP_E_ParseError;  /* ParseError — частный случай */
}

__attribute__((noreturn, cold)) static void sip_die(void) {
    fflush(stdout);
    fprintf(stderr, "%s:%d: %s", SIP_FILE, sip_err_line, sip_err_names[sip_err_kind]);
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
