/* Рантайм Sip для нативной сборки.
 *
 * Подключается в каждый сгенерированный .c файл одной единицей трансляции,
 * поэтому clang может встраивать и оптимизировать всё вместе с кодом программы.
 * Таблицу исходников SIP_FILES генератор определяет в единице с main.
 *
 * Здесь только ядро: сборщик мусора, ошибки (setjmp), потоки, то, что генератор
 * вставляет прямо в код (арифметика с проверкой, строки, хэши), примитивы для
 * std/rt.sip и тонкие обёртки над libc и libcurl. Остальной рантайм — строковые
 * функции, числа, JSON, CSV, аргументы fn main — написан на Sip в std/rt.sip.
 */
#include <errno.h>
#include <math.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Глобальное состояние рантайма. Программа из нескольких единиц компиляции (SIP_SPLIT):
 * переменные определены в единице с main (SIP_RT_IMPL), остальные видят их через extern.
 * Одна единица — обычные static. */
#if defined(SIP_SPLIT) && !defined(SIP_RT_IMPL)
#define SIP_GV(decl, ...) extern decl
#elif defined(SIP_SPLIT)
#define SIP_GV(decl, ...) decl __VA_ARGS__
#else
#define SIP_GV(decl, ...) static decl __VA_ARGS__
#endif

#define SIP_PI 3.14159265358979323846
#define SIP_LIKELY(x) __builtin_expect(!!(x), 1)
#define SIP_UNLIKELY(x) __builtin_expect(!!(x), 0)
#define SIP_LIT(s) ((sip_str){(s), (int64_t)(sizeof(s) - 1)})

typedef struct { const char *p; int64_t n; } sip_str;

/* исходники для сообщений об ошибках: строка программы line лежит в файле с наибольшим start < line */
typedef struct { int start; const char *name; const int *n; const char *const *lines; int std; } sip_srcfile;
extern const sip_srcfile SIP_FILES[];
extern const int SIP_NFILES;
typedef struct { int64_t lo, hi; } sip_range;

/* ---------- память: сборщик мусора ----------
 *
 * Консервативный mark-sweep, как Boehm GC. Указателем считается любое слово
 * в стеке, в глобальных переменных и в объектах, которое попадает внутрь
 * выделенного объекта (в том числе в середину: срезы строк указывают внутрь
 * буфера). Поэтому сгенерированному коду не нужно регистрировать корни,
 * а выделение памяти остаётся почти таким же быстрым, как сдвиг указателя.
 *
 * Куча:
 * - маленькие объекты (< 16 КБ) лежат в блоках по 64 КБ, в каждом блоке
 *   объекты одного размера; блоки нарезаются из кусков по 4 МБ;
 * - большие объекты выделяются через calloc и хранятся в отсортированном массиве;
 * - «атомарные» объекты (строки, массивы чисел) не содержат указателей,
 *   их не сканируют: случайное число не удержит мусор.
 *
 * Первая сборка — когда куча дорастёт до 64 МБ; следующая — когда программа займёт
 * ещё столько новых блоков, сколько пережило сборку (но не меньше 64 МБ). Свободные
 * места в старых блоках при этом расходуются бесплатно. Короткие программы обычно
 * не собирают мусор ни разу.
 *
 * Блок по адресу находится за O(1): куски выровнены на 4 МБ, карта кусков хранит
 * байт на каждые 4 МБ адресов.
 *
 * SIP_GC=off выключает сборку, SIP_GC_STATS=1 печатает статистику в конце,
 * SIP_GC_MIN=0 собирает мусор как можно чаще (для проверки самого сборщика).
 */

#include <sys/mman.h>
#include <time.h>
#ifdef __APPLE__
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#endif

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
/* ASan кладёт локальные переменные в «ложные кадры» в куче, их сборщик не увидит */
#if !defined(SIP_SPLIT) || defined(SIP_RT_IMPL)
const char *__asan_default_options(void) { return "detect_stack_use_after_return=0"; }
#endif
#endif
#endif

#define SIP_NOSAN __attribute__((no_sanitize("address", "thread"), noinline))

#define SIP_BLK_SHIFT 16
#define SIP_BLK ((size_t)1 << SIP_BLK_SHIFT)
#define SIP_CHUNK_BLKS 64
#define SIP_CHUNK (SIP_BLK * SIP_CHUNK_BLKS)
#define SIP_SMALL_MAX 16384
#define SIP_NCLASS 34
#define SIP_FREE_CLS 0xFF

static const uint32_t sip_class_size[SIP_NCLASS] = {
    16, 32, 48, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 640,
    768, 896, 1024, 1280, 1536, 1792, 2048, 2560, 3072, 3584, 4096, 5120, 6144, 8192,
    10240, 12288, 16384};

typedef struct sip_blk {
    uint32_t size, nobj;      /* размер объекта и их число */
    uint8_t cls, atomic;      /* cls == SIP_FREE_CLS — блок свободен */
    uint8_t pad[6];
    uint64_t mark[(SIP_BLK / 16 + 63) / 64];
} sip_blk;
#define SIP_BLK_HDR ((sizeof(sip_blk) + 15) & ~(size_t)15)

typedef struct { char *p; size_t n; bool mark, atomic; } sip_large;

/* размер -> класс: индекс (n + 16) >> 4, лишний байт — для указателя «сразу за концом» */
SIP_GV(uint8_t sip_class_of[SIP_SMALL_MAX / 16 + 2]);

SIP_GV(void *sip_fl[2][SIP_NCLASS]);                    /* списки свободных объектов */
SIP_GV(char *sip_bump[2][SIP_NCLASS]); SIP_GV(char *sip_bend[2][SIP_NCLASS]);  /* ещё не тронутая часть блока */

SIP_GV(char **sip_chunks);          /* куски по 4 МБ, по возрастанию адреса */
SIP_GV(size_t sip_nchunks); SIP_GV(size_t sip_chunks_cap);
SIP_GV(sip_blk **sip_empty);        /* свободные блоки */
SIP_GV(size_t sip_nempty); SIP_GV(size_t sip_empty_cap);
SIP_GV(sip_large *sip_larges);      /* большие объекты, по возрастанию адреса */
SIP_GV(size_t sip_nlarge); SIP_GV(size_t sip_large_cap);
SIP_GV(uintptr_t sip_lo, = UINTPTR_MAX); SIP_GV(uintptr_t sip_hi, = 0);
/* карта кусков: байт на каждые 4 МБ адресов от sip_cmap_lo; 1 — там кусок (куски выровнены на 4 МБ) */
SIP_GV(uint8_t *sip_cmap); SIP_GV(uintptr_t sip_cmap_lo); SIP_GV(size_t sip_cmap_n);

SIP_GV(size_t sip_heap_used);       /* блоки в работе + большие объекты */
SIP_GV(size_t sip_gc_min, = (size_t)64 << 20);  /* порог не ниже этого (SIP_GC_MIN, в МБ) */
SIP_GV(size_t sip_gc_next, = (size_t)64 << 20);
SIP_GV(bool sip_gc_on, = true); SIP_GV(bool sip_gc_stats);
SIP_GV(int64_t sip_gc_count);
SIP_GV(double sip_gc_time);
SIP_GV(size_t sip_gc_peak);

/* стеки потоков: сборщик сканирует стек каждого потока от sp до top */
typedef struct sip_thr { char *top, *sp; jmp_buf regs; struct sip_thr *next; } sip_thr;
SIP_GV(sip_thr sip_main_thr);
SIP_GV(sip_thr *sip_threads, = &sip_main_thr);
SIP_GV(_Thread_local sip_thr *sip_cur_thr, = &sip_main_thr);

__attribute__((noreturn, cold)) static void sip_oom(void) {
    fputs("sip: out of memory\n", stderr);
    exit(1);
}

static void sip_gc_report(void) {
    fprintf(stderr, "sip gc: %lld collections, %.3f s, peak heap %.1f MB\n", (long long)sip_gc_count, sip_gc_time,
            (double)sip_gc_peak / (1 << 20));
}

static void sip_gc_init(void *stack_top) {
    sip_main_thr.top = stack_top;
    for (size_t i = 0, c = 0; i < sizeof sip_class_of; i++) {
        size_t n = i * 16;
        while (c < SIP_NCLASS - 1 && sip_class_size[c] < n) c++;
        sip_class_of[i] = (uint8_t)c;
    }
    const char *e = getenv("SIP_GC");
    if (e && (!strcmp(e, "off") || !strcmp(e, "0"))) sip_gc_on = false;
    e = getenv("SIP_GC_MIN");
    if (e && *e) sip_gc_min = sip_gc_next = (size_t)strtoull(e, NULL, 10) << 20;
    e = getenv("SIP_GC_STATS");
    if (e && *e && strcmp(e, "0")) { sip_gc_stats = true; atexit(sip_gc_report); }
}

/* ---- куски и блоки ---- */

/* отметить кусок в карте; карта растёт, чтобы покрыть его адрес (1 байт на 4 МБ — даже 1 ТБ разброса это 256 КБ) */
static void sip_cmap_add(uintptr_t p) {
    uintptr_t k = p / SIP_CHUNK;
    uintptr_t lo = sip_cmap_n ? sip_cmap_lo : k, hi = sip_cmap_n ? sip_cmap_lo + sip_cmap_n : k + 1;
    if (k < lo) lo = k;
    if (k >= hi) hi = k + 1;
    if (lo != sip_cmap_lo || hi - lo != sip_cmap_n) {
        uint8_t *m = calloc((size_t)(hi - lo), 1);
        if (!m) sip_oom();
        if (sip_cmap_n) memcpy(m + (sip_cmap_lo - lo), sip_cmap, sip_cmap_n);
        free(sip_cmap);
        sip_cmap = m;
        sip_cmap_lo = lo;
        sip_cmap_n = (size_t)(hi - lo);
    }
    sip_cmap[k - lo] = 1;
}

static void sip_new_chunk(void) {
    size_t len = SIP_CHUNK * 2;  /* с запасом, чтобы выровнять кусок на 4 МБ */
    char *raw = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (raw == MAP_FAILED) sip_oom();
    char *p = (char *)(((uintptr_t)raw + SIP_CHUNK - 1) & ~(uintptr_t)(SIP_CHUNK - 1));
    if (p > raw) munmap(raw, (size_t)(p - raw));
    char *end = p + SIP_CHUNK;
    if (raw + len > end) munmap(end, (size_t)(raw + len - end));
    if (sip_nchunks == sip_chunks_cap) {
        sip_chunks_cap = sip_chunks_cap ? sip_chunks_cap * 2 : 16;
        sip_chunks = realloc(sip_chunks, sip_chunks_cap * sizeof *sip_chunks);
        if (!sip_chunks) sip_oom();
    }
    size_t i = sip_nchunks++;
    while (i > 0 && sip_chunks[i - 1] > p) { sip_chunks[i] = sip_chunks[i - 1]; i--; }
    sip_chunks[i] = p;
    sip_cmap_add((uintptr_t)p);
    if ((uintptr_t)p < sip_lo) sip_lo = (uintptr_t)p;
    if ((uintptr_t)end > sip_hi) sip_hi = (uintptr_t)end;
    if (sip_nchunks * SIP_CHUNK_BLKS > sip_empty_cap) {  /* в запас могут вернуться все блоки */
        sip_empty_cap = sip_nchunks * SIP_CHUNK_BLKS * 2;
        sip_empty = realloc(sip_empty, sip_empty_cap * sizeof *sip_empty);
        if (!sip_empty) sip_oom();
    }
    for (int k = SIP_CHUNK_BLKS - 1; k >= 0; k--) {  /* память из mmap уже нулевая */
        sip_blk *b = (sip_blk *)(p + (size_t)k * SIP_BLK);
        b->cls = SIP_FREE_CLS;
        sip_empty[sip_nempty++] = b;
    }
}

static void sip_gc_collect(void);

static bool sip_gc_due(size_t more) {
    return sip_gc_on && sip_heap_used + more > sip_gc_next;
}

__attribute__((noinline)) static void *sip_alloc_refill(int c, int atomic) {
    if (sip_gc_due(SIP_BLK)) {
        sip_gc_collect();
        void *p = sip_fl[atomic][c];
        if (p) {
            sip_fl[atomic][c] = *(void **)p;
            *(void **)p = NULL;
            return p;
        }
    }
    if (!sip_nempty) sip_new_chunk();
    sip_blk *b = sip_empty[--sip_nempty];
    uint32_t size = sip_class_size[c];
    b->size = size;
    b->nobj = (uint32_t)((SIP_BLK - SIP_BLK_HDR) / size);
    b->cls = (uint8_t)c;
    b->atomic = (uint8_t)atomic;
    sip_heap_used += SIP_BLK;
    if (sip_heap_used > sip_gc_peak) sip_gc_peak = sip_heap_used;
    char *start = (char *)b + SIP_BLK_HDR;
    sip_bump[atomic][c] = start + size;
    sip_bend[atomic][c] = start + (size_t)b->nobj * size;
    return start;
}

__attribute__((noinline)) static void *sip_alloc_large(size_t n, int atomic) {
    size_t sz = (n + 16) & ~(size_t)15;  /* +1 байт: указатель «сразу за концом» тоже внутри */
    if (sip_gc_due(sz)) sip_gc_collect();
    char *p = atomic ? malloc(sz) : calloc(1, sz);
    if (!p) sip_oom();
    if (sip_nlarge == sip_large_cap) {
        sip_large_cap = sip_large_cap ? sip_large_cap * 2 : 64;
        sip_larges = realloc(sip_larges, sip_large_cap * sizeof *sip_larges);
        if (!sip_larges) sip_oom();
    }
    size_t lo = 0, hi = sip_nlarge;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (sip_larges[mid].p < p) lo = mid + 1; else hi = mid;
    }
    memmove(sip_larges + lo + 1, sip_larges + lo, (sip_nlarge - lo) * sizeof *sip_larges);
    sip_larges[lo] = (sip_large){p, sz, false, (bool)atomic};
    sip_nlarge++;
    if ((uintptr_t)p < sip_lo) sip_lo = (uintptr_t)p;
    if ((uintptr_t)p + sz > sip_hi) sip_hi = (uintptr_t)p + sz;
    sip_heap_used += sz;
    if (sip_heap_used > sip_gc_peak) sip_gc_peak = sip_heap_used;
    return p;
}

/* Свободная память всегда нулевая, кроме первого слова (ссылки в списке свободных).
 * У атомарных объектов содержимое не обнуляется. */
static inline void *sip_alloc_k(size_t n, int atomic) {
    if (SIP_UNLIKELY(n >= SIP_SMALL_MAX)) return sip_alloc_large(n, atomic);
    int c = sip_class_of[(n + 16) >> 4];
    void *p = sip_fl[atomic][c];
    if (SIP_LIKELY(p != NULL)) {
        sip_fl[atomic][c] = *(void **)p;
        *(void **)p = NULL;
        return p;
    }
    char *q = sip_bump[atomic][c];
    if (SIP_UNLIKELY(q == NULL || q >= sip_bend[atomic][c])) return sip_alloc_refill(c, atomic);
    sip_bump[atomic][c] = q + sip_class_size[c];
    return q;
}

/* обнулённая память, в которой могут быть указатели */
static inline void *sip_alloc(size_t n) { return sip_alloc_k(n, 0); }

/* память без указателей (байты строк, массивы чисел); содержимое не обнулено */
static inline void *sip_alloc_atomic(size_t n) { return sip_alloc_k(n, 1); }

/* блок или большой объект, внутри которого лежит адрес (или NULL) */
static inline sip_blk *sip_find_blk(uintptr_t w) {
    uintptr_t k = w / SIP_CHUNK - sip_cmap_lo;  /* адрес ниже карты даёт огромное k */
    if (k >= sip_cmap_n || !sip_cmap[k]) return NULL;
    sip_blk *b = (sip_blk *)(w & ~(uintptr_t)(SIP_BLK - 1));
    return b->cls == SIP_FREE_CLS ? NULL : b;
}

static inline sip_large *sip_find_large(uintptr_t w) {
    size_t lo = 0, hi = sip_nlarge;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if ((uintptr_t)sip_larges[mid].p <= w) lo = mid + 1; else hi = mid;
    }
    if (lo == 0) return NULL;
    sip_large *l = &sip_larges[lo - 1];
    return w < (uintptr_t)l->p + l->n ? l : NULL;
}

/* сколько байт можно использовать в объекте p */
static size_t sip_obj_size(void *p) {
    sip_blk *b = sip_find_blk((uintptr_t)p);
    if (b) return b->size - 1;
    sip_large *l = sip_find_large((uintptr_t)p);
    return l ? l->n - 1 : 0;
}

static void *sip_realloc_k(void *p, size_t n, int atomic) {
    if (!p) return sip_alloc_k(n ? n : 1, atomic);
    size_t old = sip_obj_size(p);
    if (n <= old) return p;
    void *q = sip_alloc_k(n, atomic);
    memcpy(q, p, old);
    return q;
}

/* старый объект не освобождается сразу: на него может ещё кто-то ссылаться */
static void *sip_realloc(void *p, size_t n) { return sip_realloc_k(p, n, 0); }
static void *sip_realloc_atomic(void *p, size_t n) { return sip_realloc_k(p, n, 1); }

/* ---- пометка ---- */

typedef struct { char *p; size_t n; } sip_range_t;
SIP_GV(sip_range_t *sip_mstack);
SIP_GV(size_t sip_msn); SIP_GV(size_t sip_mscap);

static inline void sip_mpush(char *p, size_t n) {
    if (sip_msn == sip_mscap) {
        sip_mscap = sip_mscap ? sip_mscap * 2 : 4096;
        sip_mstack = realloc(sip_mstack, sip_mscap * sizeof *sip_mstack);
        if (!sip_mstack) sip_oom();
    }
    sip_mstack[sip_msn++] = (sip_range_t){p, n};
}

static inline void sip_mark_word(uintptr_t w) {
    if (w < sip_lo || w >= sip_hi) return;
    sip_blk *b = sip_find_blk(w);
    if (b) {
        uintptr_t base = (uintptr_t)b + SIP_BLK_HDR;
        if (w < base) return;
        size_t i = (w - base) / b->size;
        if (i >= b->nobj) return;
        uint64_t bit = (uint64_t)1 << (i & 63);
        if (b->mark[i >> 6] & bit) return;
        b->mark[i >> 6] |= bit;
        if (!b->atomic) sip_mpush((char *)(base + i * b->size), b->size);
        return;
    }
    sip_large *l = sip_find_large(w);
    if (l && !l->mark) {
        l->mark = true;
        if (!l->atomic) sip_mpush(l->p, l->n);
    }
}

SIP_NOSAN static void sip_mark_range(const char *lo, const char *hi) {
    uintptr_t a = ((uintptr_t)lo + sizeof(void *) - 1) & ~(uintptr_t)(sizeof(void *) - 1);
    for (; a + sizeof(void *) <= (uintptr_t)hi; a += sizeof(void *)) sip_mark_word(*(const uintptr_t *)a);
}

static void sip_mark_drain(void) {
    while (sip_msn) {
        sip_range_t r = sip_mstack[--sip_msn];
        sip_mark_range(r.p, r.p + r.n);
    }
}

static void sip_mark_globals(void) {
#ifdef __APPLE__
    unsigned long size = 0;
    static const char *const segs[] = {"__DATA", "__DATA_DIRTY"};
    for (int i = 0; i < 2; i++) {
        uint8_t *p = getsegmentdata(&_mh_execute_header, segs[i], &size);
        if (p) sip_mark_range((char *)p, (char *)p + size);
    }
#else
    extern char __data_start[], _end[];
    sip_mark_range(__data_start, _end);
#endif
}

/* стек текущего потока: от кадра этой функции (ниже всех вызывающих) до вершины */
SIP_NOSAN static void sip_mark_own_stack(void) {
    char *sp = (char *)__builtin_frame_address(0);
    sip_mark_range(sp, sip_cur_thr->top);
}

static void sip_mark_threads(void) {
    for (sip_thr *t = sip_threads; t; t = t->next) {
        if (t == sip_cur_thr) continue;
        sip_mark_range((char *)&t->regs, (char *)&t->regs + sizeof t->regs);
        if (t->sp) sip_mark_range(t->sp, t->top);
    }
}

/* Поток отпускает GIL: запомнить его регистры и вершину стека, чтобы сборщик,
 * запущенный в другом потоке, нашёл указатели этого потока. */
SIP_NOSAN static void sip_gc_park(void) {
    sip_thr *t = sip_cur_thr;
    setjmp(t->regs);
    char *sp;
#if defined(__aarch64__)
    __asm__ volatile("mov %0, sp" : "=r"(sp));
#elif defined(__x86_64__)
    __asm__ volatile("mov %%rsp, %0" : "=r"(sp));
#else
    sp = (char *)__builtin_frame_address(0) - 4096;
#endif
    t->sp = sp;
}

/* новый поток (держит GIL): его стек сканируется до top */
static void sip_gc_thread_add(sip_thr *t, void *top) {
    t->top = top;
    t->sp = NULL;
    t->next = sip_threads;
    sip_threads = t;
    sip_cur_thr = t;
}

static void sip_gc_thread_remove(sip_thr *t) {
    for (sip_thr **pp = &sip_threads; *pp; pp = &(*pp)->next)
        if (*pp == t) { *pp = t->next; break; }
}

/* ---- уборка ---- */

static size_t sip_sweep(void) {
    size_t live = 0;
    for (int a = 0; a < 2; a++)
        for (int c = 0; c < SIP_NCLASS; c++) {
            sip_fl[a][c] = NULL;
            sip_bump[a][c] = sip_bend[a][c] = NULL;
        }
    void **tail[2][SIP_NCLASS];
    for (int a = 0; a < 2; a++)
        for (int c = 0; c < SIP_NCLASS; c++) tail[a][c] = &sip_fl[a][c];
    for (size_t ci = 0; ci < sip_nchunks; ci++) {
        for (size_t k = 0; k < SIP_CHUNK_BLKS; k++) {
            sip_blk *b = (sip_blk *)(sip_chunks[ci] + k * SIP_BLK);
            if (b->cls == SIP_FREE_CLS) continue;
            char *base = (char *)b + SIP_BLK_HDR;
            size_t nlive = 0, words = (b->nobj + 63) / 64;
            for (size_t w = 0; w < words; w++) nlive += (size_t)__builtin_popcountll(b->mark[w]);
            if (nlive == 0) {  /* весь блок — мусор: обнулить и вернуть в общий запас */
                memset(base, 0, (size_t)b->nobj * b->size);
                b->cls = SIP_FREE_CLS;
                sip_empty[sip_nempty++] = b;
                sip_heap_used -= SIP_BLK;
                continue;
            }
            live += nlive * b->size;
            int a = b->atomic, c = b->cls;
            for (size_t i = 0; i < b->nobj; i++) {
                if (b->mark[i >> 6] & ((uint64_t)1 << (i & 63))) continue;
                char *o = base + i * b->size;
                if (!a) memset(o, 0, b->size);
                *tail[a][c] = o;
                tail[a][c] = (void **)o;
            }
            memset(b->mark, 0, words * sizeof(uint64_t));
        }
    }
    for (int a = 0; a < 2; a++)
        for (int c = 0; c < SIP_NCLASS; c++) *tail[a][c] = NULL;
    size_t j = 0;
    for (size_t i = 0; i < sip_nlarge; i++) {
        sip_large l = sip_larges[i];
        if (!l.mark) {
            free(l.p);
            sip_heap_used -= l.n;
            continue;
        }
        live += l.n;
        l.mark = false;
        sip_larges[j++] = l;
    }
    sip_nlarge = j;
    return live;
}

SIP_NOSAN __attribute__((noinline)) static void sip_gc_collect(void) {
    struct timespec t0, t1;
    if (sip_gc_stats) clock_gettime(CLOCK_MONOTONIC, &t0);
    jmp_buf regs;  /* регистры текущего потока попадают в стек */
    setjmp(regs);
    sip_mark_own_stack();
    sip_mark_range((char *)&regs, (char *)&regs + sizeof regs);
    sip_mark_threads();
    sip_mark_globals();
    sip_mark_drain();
    size_t live = sip_sweep();
    /* следующая сборка — когда выделим ещё max(live, min) в новых блоках; свободные места в старых блоках
     * идут в счёт бесплатно. Цена сборки пропорциональна live, так что на байт выделенной памяти она
     * не растёт с размером кучи. SIP_GC_MIN=0 — собирать на каждом новом блоке. */
    size_t grow = !sip_gc_min ? 0 : live > sip_gc_min ? live : sip_gc_min;
    sip_gc_next = sip_heap_used + grow;
    sip_gc_count++;
    if (sip_gc_stats) {
        clock_gettime(CLOCK_MONOTONIC, &t1);
        sip_gc_time += (double)(t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) * 1e-9;
    }
}

/* для тестов: собрать мусор сейчас */
static void sip_gc_now(void) {
    if (sip_gc_on) sip_gc_collect();
}

/* ---------- ошибки ---------- */

enum {
    SIP_E_Error, SIP_E_NotFound, SIP_E_ParseError, SIP_E_IndexError, SIP_E_KeyError,
    SIP_E_ValueError, SIP_E_ZeroDivisionError, SIP_E_AssertionError, SIP_E_IOError, SIP_E_NilError,
    SIP_E_HttpError, SIP_E_OverflowError, SIP_E_NKINDS
};
static const char *const sip_err_names[] = {
    "Error", "NotFound", "ParseError", "IndexError", "KeyError",
    "ValueError", "ZeroDivisionError", "AssertionError", "IOError", "NilError", "HttpError", "OverflowError"
};
/* Ошибки-значения (fail NotEnough(5, 2)): вид — номер типа (>= SIP_E_USER), объект — в sip_err_obj,
 * в сообщении — его запись: NotEnough(need=5, have=2). */
#define SIP_E_USER 1000

typedef struct sip_try { jmp_buf jb; struct sip_try *prev; } sip_try;
SIP_GV(sip_try *sip_try_top);
SIP_GV(int sip_err_kind);
SIP_GV(sip_str sip_err_msg);
SIP_GV(int sip_err_line);
SIP_GV(void *sip_err_obj);
SIP_GV(int sip_std_line);  /* строка, где код пользователя вызвал стандартную библиотеку */

static inline void sip_try_push(sip_try *t) { t->prev = sip_try_top; sip_try_top = t; }
static inline void sip_try_pop(void) { sip_try_top = sip_try_top->prev; }

/* async: задачи выполняются в потоках, но код Sip в каждый момент выполняет только один поток —
 * тот, что держит sip_gil (как GIL в Python). Блокирующие вызовы (http, sleep) отпускают его,
 * поэтому ожидание идёт параллельно. При смене потока сохраняется его стек try. */
#ifdef SIP_USE_ASYNC
#include <pthread.h>
SIP_GV(pthread_mutex_t sip_gil, = PTHREAD_MUTEX_INITIALIZER);
SIP_GV(bool sip_threaded);
typedef struct { sip_try *try_top; } sip_tstate;
static inline sip_tstate sip_gil_release(void) {
    sip_tstate st = {sip_try_top};
    if (sip_threaded) {
        sip_gc_park();
        pthread_mutex_unlock(&sip_gil);
    }
    return st;
}
static inline void sip_gil_acquire(sip_tstate st) {
    if (sip_threaded) {
        pthread_mutex_lock(&sip_gil);
        sip_cur_thr->sp = NULL;
    }
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

/* Текущая ошибка: `файл:строка: Вид: сообщение` и строка исходника */
static void sip_err_print(FILE *out, const char *indent) {
    int f = 0;
    while (f + 1 < SIP_NFILES && SIP_FILES[f + 1].start < sip_err_line) f++;
    int local = sip_err_line - SIP_FILES[f].start;
    if (sip_err_kind >= SIP_E_USER) {
        fprintf(out, "%s%s:%d: %.*s", indent, SIP_FILES[f].name, local, (int)sip_err_msg.n, sip_err_msg.p);
    } else {
        fprintf(out, "%s%s:%d: %s", indent, SIP_FILES[f].name, local, sip_err_names[sip_err_kind]);
        if (sip_err_msg.n) fprintf(out, ": %.*s", (int)sip_err_msg.n, sip_err_msg.p);
    }
    fputc('\n', out);
    if (local > 0 && local <= *SIP_FILES[f].n) {
        const char *s = SIP_FILES[f].lines[local - 1];
        while (*s == ' ') s++;
        fprintf(out, "%s    %s\n", indent, s);
    }
}

__attribute__((noreturn, cold)) static void sip_die(void) {
    fflush(stdout);
    sip_err_print(stderr, "");
    exit(1);
}

/* sip test: блоки `test "имя"` корневого файла. Печатаются только упавшие тесты и итог. */
static int sip_test_n, sip_test_failed, sip_test_verbose;
static const char *sip_test_filter, *sip_test_file;

static void sip_test_begin(int argc, char **argv) {
    sip_test_file = argv[0];
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-v")) sip_test_verbose = 1;
        else sip_test_filter = argv[i];
    }
}

static bool sip_test_want(const char *name) { return !sip_test_filter || strstr(name, sip_test_filter); }

static void sip_test_ok(const char *name) {
    sip_test_n++;
    if (sip_test_verbose) printf("ok   %s\n", name);
}

static void sip_test_fail(const char *name) {
    sip_test_n++;
    sip_test_failed++;
    printf("FAIL %s\n", name);
    sip_err_print(stdout, "    ");
}

static int sip_test_end(void) {
    if (sip_test_failed) printf("%s: %d of %d tests failed\n", sip_test_file, sip_test_failed, sip_test_n);
    else printf("%s: ok, %d test%s\n", sip_test_file, sip_test_n, sip_test_n == 1 ? "" : "s");
    fflush(stdout);
    return sip_test_failed ? 1 : 0;
}

__attribute__((noreturn, cold)) static void sip_reraise(void) {
    if (!sip_try_top) sip_die();
    sip_try *t = sip_try_top;
    sip_try_pop();
    longjmp(t->jb, 1);
}

/* Ошибка внутри стандартной библиотеки (std/*.sip) показывается на строке вызова в коде пользователя */
static int sip_user_line(int line) {
    if (!sip_std_line) return line;
    int f = 0;
    while (f + 1 < SIP_NFILES && SIP_FILES[f + 1].start < line) f++;
    return SIP_FILES[f].std ? sip_std_line : line;
}

__attribute__((noreturn, cold)) static void sip_raise_obj(int kind, void *obj, sip_str msg, int line) {
    line = sip_user_line(line);
    sip_err_kind = kind;
    sip_err_obj = obj;
    sip_err_msg = msg;
    sip_err_line = line;
    sip_reraise();
}

__attribute__((noreturn, cold)) static void sip_raise(int kind, sip_str msg, int line) {
    sip_raise_obj(kind, NULL, msg, line);
}

__attribute__((noreturn, cold, noinline)) static void sip_overflow(int line) {
    sip_raise(SIP_E_OverflowError, SIP_LIT("integer overflow"), line);
}

__attribute__((noreturn, cold)) static void sip_raisef(int kind, int line, const char *fmt, ...);

/* ---------- построитель строк ---------- */

typedef struct { char *p; int64_t n, cap; } sip_sb;

static inline sip_sb sip_sb_new(void) { return (sip_sb){NULL, 0, 0}; }

static void sip_sb_grow(sip_sb *b, int64_t need) {
    int64_t cap = b->cap ? b->cap : 32;
    while (cap < b->n + need) cap *= 2;
    b->p = sip_realloc_atomic(b->p, (size_t)cap);
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

SIP_GV(sip_sb sip_out_line);

static inline void sip_print_line(void) {
    sip_sb_putc(&sip_out_line, '\n');
    fwrite(sip_out_line.p, 1, (size_t)sip_out_line.n, stdout);
    sip_out_line.n = 0;
}

/* ---------- числа ---------- */

/* int — 64 бита со знаком; выход за пределы — OverflowError, а не тихое переполнение */
static inline int64_t sip_add(int64_t a, int64_t b, int line) {
    int64_t r;
    if (SIP_UNLIKELY(__builtin_add_overflow(a, b, &r))) sip_overflow(line);
    return r;
}

static inline int64_t sip_sub(int64_t a, int64_t b, int line) {
    int64_t r;
    if (SIP_UNLIKELY(__builtin_sub_overflow(a, b, &r))) sip_overflow(line);
    return r;
}

static inline int64_t sip_mul(int64_t a, int64_t b, int line) {
    int64_t r;
    if (SIP_UNLIKELY(__builtin_mul_overflow(a, b, &r))) sip_overflow(line);
    return r;
}

static inline int64_t sip_neg(int64_t a, int line) {
    if (SIP_UNLIKELY(a == INT64_MIN)) sip_overflow(line);
    return -a;
}

static inline int64_t sip_iabs(int64_t a, int line) { return a < 0 ? sip_neg(a, line) : a; }

/* float -> int: NaN — ValueError, бесконечность и слишком большие числа — OverflowError */
static inline int64_t sip_f2i(double x, int line) {
    if (SIP_LIKELY(x > -9223372036854775809.0 && x < 9223372036854775808.0)) return (int64_t)x;
    if (x != x) sip_raise(SIP_E_ValueError, SIP_LIT("cannot convert float NaN to integer"), line);
    sip_raise(SIP_E_OverflowError, SIP_LIT("float is too large for an int"), line);
}

static inline int64_t sip_floordiv(int64_t a, int64_t b, int line) {
    if (SIP_UNLIKELY(b == 0)) sip_raise(SIP_E_ZeroDivisionError, SIP_LIT("division by zero"), line);
    if (SIP_UNLIKELY(b == -1)) return sip_neg(a, line);
    int64_t q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
    return q;
}

static inline int64_t sip_mod(int64_t a, int64_t b, int line) {
    if (SIP_UNLIKELY(b == 0)) sip_raise(SIP_E_ZeroDivisionError, SIP_LIT("modulo by zero"), line);
    if (SIP_UNLIKELY(b == -1)) return 0;
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
    while (b) {
        if (b & 1) r = sip_mul(r, a, line);
        b >>= 1;
        if (b) a = sip_mul(a, a, line);
    }
    return r;
}

static inline int64_t sip_round(double x, int line) {
    /* как в Python: банковское округление */
    return sip_f2i(nearbyint(x), line);
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
    char *p = sip_alloc_atomic((size_t)(a.n + b.n));
    memcpy(p, a.p, (size_t)a.n);
    memcpy(p + a.n, b.p, (size_t)b.n);
    return (sip_str){p, a.n + b.n};
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
    const char *p = s.p, *last = s.p + (s.n - sub.n);  /* кандидаты — по первому байту через memchr */
    while (p <= last) {
        p = memchr(p, sub.p[0], (size_t)(last - p + 1));
        if (!p) return -1;
        if (memcmp(p + 1, sub.p + 1, (size_t)sub.n - 1) == 0) return p - s.p;
        p++;
    }
    return -1;
}

static inline bool sip_str_contains(sip_str s, sip_str sub) { return sip_str_find(s, sub) >= 0; }

/* ord, chr, strip, float(s), repr строки — в std/rt.sip */

static inline bool sip_isspace(char c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

static inline bool sip_str_startswith(sip_str s, sip_str p) {
    return p.n <= s.n && memcmp(s.p, p.p, (size_t)p.n) == 0;
}

static inline bool sip_str_endswith(sip_str s, sip_str p) {
    return p.n <= s.n && memcmp(s.p + s.n - p.n, p.p, (size_t)p.n) == 0;
}


/* Печать float как в Python (кратчайшая запись, которая читается обратно) написана на Sip: fmt_float
 * в std/rt.sip. Здесь — только объявление: rt.sip подключается к каждой программе. */
#ifdef SIP_SPLIT
#define SIP_RT_DECL
#else
#define SIP_RT_DECL static
#endif
SIP_RT_DECL void f_std__rt__fmt_float(void *b, double x);
SIP_RT_DECL void f_std__rt__repr_str(void *b, sip_str s);
static inline void str_float(sip_sb *b, double x) { f_std__rt__fmt_float(b, x); }
static inline void repr_str(sip_sb *b, sip_str s) { f_std__rt__repr_str(b, s); }

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

static void str_ptr(sip_sb *b, void *p) {
    char buf[32];
    int n = snprintf(buf, sizeof buf, "<ptr %p>", p);
    sip_sb_put(b, buf, n);
}

#define repr_ptr str_ptr
#define repr_int str_int
#define repr_float str_float
#define repr_bool str_bool
#define repr_range str_range

static inline sip_str sip_int_to_str(int64_t x) { sip_sb b = sip_sb_new(); str_int(&b, x); return sip_sb_done(&b); }

/* Форматирование `{x:.2f}`: спецификация уже переведена в формат printf генератором. */
static inline void sip_fmt_float(sip_sb *b, const char *fmt, double x) { sip_sb_printf(b, fmt, x); }
static inline void sip_fmt_int(sip_sb *b, const char *fmt, int64_t x) { sip_sb_printf(b, fmt, (long long)x); }
static inline void sip_fmt_str(sip_sb *b, const char *fmt, sip_str s) { sip_sb_printf(b, fmt, (int)s.n, s.p); }

/* ---------- примитивы для рантайма на Sip (std/rt.sip) ----------
 * Строковые функции (lower, replace, ljust, int(s), ...) написаны на Sip в std/rt.sip; здесь только то,
 * что Sip пока не выражает сам: байт строки, кусок без копии, сырая память. Границы не проверяются:
 * эти функции вызывает только rt.sip, который сам следит за индексами. */
static inline int64_t sip_rt_byte(sip_str s, int64_t i) { return (unsigned char)s.p[i]; }
static inline sip_str sip_rt_sub(sip_str s, int64_t lo, int64_t hi) { return (sip_str){s.p + lo, hi - lo}; }
static inline bool sip_rt_eq_at(sip_str s, int64_t i, sip_str t) { return memcmp(s.p + i, t.p, (size_t)t.n) == 0; }
static inline int64_t sip_rt_find(sip_str s, sip_str sub, int64_t from) {
    int64_t i = sip_str_find((sip_str){s.p + from, s.n - from}, sub);
    return i < 0 ? -1 : i + from;
}
static inline void *sip_rt_alloc(int64_t n) { return sip_alloc_atomic((size_t)(n ? n : 1)); }
static inline void sip_rt_set(void *p, int64_t i, int64_t b) { ((char *)p)[i] = (char)b; }
static inline void sip_rt_fill(void *p, int64_t i, int64_t n, int64_t b) { if (n > 0) memset((char *)p + i, (int)b, (size_t)n); }
static inline void sip_rt_copy(void *p, int64_t i, sip_str s) { if (s.n) memcpy((char *)p + i, s.p, (size_t)s.n); }
static inline sip_str sip_rt_str(void *p, int64_t n) { return (sip_str){(const char *)p, n}; }
static inline void *sip_rt_sb(void) { sip_sb *b = sip_alloc(sizeof *b); *b = sip_sb_new(); return b; }
static inline void sip_rt_put(void *b, sip_str s) { sip_sb_str((sip_sb *)b, s); }
static inline void sip_rt_putc(void *b, int64_t c) { sip_sb_putc((sip_sb *)b, (char)c); }
static inline sip_str sip_rt_done(void *b) { return sip_sb_done((sip_sb *)b); }
/* printf("%.*e") и printf("%.*f") для fmt_float */
static sip_str sip_rt_fmt(double x, int64_t prec, bool exp) {
    char buf[400];
    int n = snprintf(buf, sizeof buf, exp ? "%.*e" : "%.*f", (int)prec, x);
    if (n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    char *p = sip_alloc_atomic((size_t)n + 1);
    memcpy(p, buf, (size_t)n);
    return (sip_str){p, n};
}
/* float из строки целиком (как strtod); если это не число — sip_rt_fbad = true */
SIP_GV(_Thread_local bool sip_rt_fbad);
static double sip_rt_tofloat(sip_str s) {
    char buf[128], *end;
    sip_rt_fbad = true;
    if (s.n == 0 || s.n >= (int64_t)sizeof buf) return 0;
    memcpy(buf, s.p, (size_t)s.n);
    buf[s.n] = 0;
    double v = strtod(buf, &end);
    sip_rt_fbad = *end != 0;
    return v;
}
static inline bool sip_rt_fbad_get(void) { return sip_rt_fbad; }
/* число из правильного токена (его уже проверил разбор на Sip); strtod понимает и nan, inf, -inf */
static double sip_rt_atof(sip_str s) {
    char buf[64], *t = s.n < (int64_t)sizeof buf ? buf : malloc((size_t)s.n + 1);
    memcpy(t, s.p, (size_t)s.n);
    t[s.n] = 0;
    double v = strtod(t, NULL);
    if (t != buf) free(t);
    return v;
}

/* ---------- файлы ---------- */

static sip_str sip_read(sip_str path, int line) {
    char *cpath = sip_alloc_atomic((size_t)path.n + 1);
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
    char *buf = sip_alloc_atomic((size_t)n + 1);
    size_t got = fread(buf, 1, (size_t)n, f);
    fclose(f);
    return (sip_str){buf, (int64_t)got};
}

static void sip_write(sip_str path, sip_str text, int line) {
    char *cpath = sip_alloc_atomic((size_t)path.n + 1);
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

SIP_GV(int sip_argc);
SIP_GV(char **sip_argv);

static void sip_args_init(int argc, char **argv) {
    sip_argc = argc;
    sip_argv = argv;
}

/* разбор аргументов fn main — в std/rt.sip; ему нужны только argv и вывод в stderr */
static inline int64_t sip_rt_argc(void) { return sip_argc; }
static inline sip_str sip_rt_argv(int64_t i) { return (sip_str){sip_argv[i], (int64_t)strlen(sip_argv[i])}; }
static void sip_rt_eput(sip_str s) {
    fflush(stdout);
    fwrite(s.p, 1, (size_t)s.n, stderr);
}

static inline sip_str sip_cstr(const char *s) { return (sip_str){s, (int64_t)strlen(s)}; }

/* FFI: строка для C (копия с нулём в конце; живёт, пока на неё есть ссылки) и обратно */
static const char *sip_ffi_cstr(sip_str s) {
    char *p = sip_alloc_atomic((size_t)s.n + 1);
    if (s.n) memcpy(p, s.p, (size_t)s.n);
    p[s.n] = 0;
    return p;
}

static sip_str sip_from_c(const char *s) {
    size_t n = strlen(s);
    char *p = sip_alloc_atomic(n + 1);
    memcpy(p, s, n + 1);
    return (sip_str){p, (int64_t)n};
}

/* extern fn: имя символа C с префиксом платформы (_ на macOS) */
#define SIP_STR_(x) #x
#define SIP_XSTR_(x) SIP_STR_(x)
#define SIP_SYM(name) SIP_XSTR_(__USER_LABEL_PREFIX__) name

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

SIP_GV(uint64_t sip_rng, = 0);

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
 * Разбор и вывод написаны на Sip (std/rt.sip, функции jp_* и je_*). Для каждого типа компилятор
 * генерирует jdec_K и jenc_K, которые вызывают их. */

static inline bool sip_str_is(sip_str s, const char *lit, int64_t n) {
    return s.n == n && !memcmp(s.p, lit, (size_t)n);
}

/* ---------- CSV ----------
 * Чтение и запись написаны на Sip (std/rt.sip, функции csv_*); код под каждый тип генерирует компилятор. */

/* ---------- HTTP (libcurl; подключается, только если программа пользуется http) ---------- */
#ifdef SIP_USE_HTTP
#include <curl/curl.h>
#include <pthread.h>
#include <ctype.h>

typedef struct { int64_t status; sip_str body, url; sip_str *hk, *hv; int64_t nh, hcap; } sip_http_resp;

SIP_GV(pthread_once_t sip_http_once, = PTHREAD_ONCE_INIT);
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
        char *k = sip_alloc_atomic((size_t)kn + 1);
        for (int64_t j = 0; j < kn; j++) k[j] = (char)tolower((unsigned char)line[j]);
        char *vv = sip_alloc_atomic((size_t)vn + 1);
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
    char *c = sip_alloc_atomic((size_t)s.n + 1);
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
            char *u = sip_alloc_atomic((size_t)n + 1);
            memcpy(u, eff, (size_t)n + 1);
            r.url = (sip_str){u, n};
        } else r.url = url;
        char *bp = sip_alloc_atomic(out.n ? out.n : 1);
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
    void *eo;
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
        t->eo = sip_err_obj;
        t->em = sip_err_msg;
        t->el = sip_err_line;
    }
}

static void sip_task_await(sip_task *t, int line) {
    if (t->state == 0) sip_task_exec(t);
    else if (t->state == 1) sip_raise(SIP_E_Error, SIP_LIT("a task cannot await itself"), line);
    if (t->state == 3) sip_raise_obj(t->ek, t->eo, t->em, t->el);
}

typedef struct { sip_task **ts; int64_t n, next; } sip_pool;

static void *sip_worker(void *arg) {
    sip_pool *p = arg;
    sip_thr self;
    pthread_mutex_lock(&sip_gil);
    sip_gc_thread_add(&self, __builtin_frame_address(0));
    while (p->next < p->n) {
        sip_task *t = p->ts[p->next++];
        if (t->state != 0) continue;
        sip_try_top = NULL;
        sip_task_exec(t);
    }
    sip_gc_thread_remove(&self);
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
        if (ts[i]->state == 3) sip_raise_obj(ts[i]->ek, ts[i]->eo, ts[i]->em, ts[i]->el);
        if (ts[i]->state == 1) sip_raise(SIP_E_Error, SIP_LIT("a task cannot await itself"), line);
    }
}
#endif

/* ---------- стандартная библиотека: помощники для std/os.sip и std/re.sip (extern "sip") ----------
 * Ошибки указывают на строку, где код пользователя вызвал функцию библиотеки (sip_std_line). */
#include <dirent.h>
#include <regex.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define SIP_NIL_STR ((sip_str){NULL, 0})

__attribute__((noreturn, cold)) static void sip_os_fail(sip_str path) {
    int kind = errno == ENOENT ? SIP_E_NotFound : SIP_E_IOError;
    sip_raisef(kind, sip_std_line, "%.*s: %s", (int)path.n, path.p, strerror(errno));
}

static sip_str sip_os_getenv(sip_str name) {
    const char *v = getenv(sip_ffi_cstr(name));
    return v ? sip_from_c(v) : SIP_NIL_STR;
}

static void sip_os_setenv(sip_str name, sip_str value) {
    if (setenv(sip_ffi_cstr(name), sip_ffi_cstr(value), 1)) sip_os_fail(name);
}

static void sip_os_unsetenv(sip_str name) { unsetenv(sip_ffi_cstr(name)); }

static sip_str sip_os_cwd(void) {
    char buf[4096];
    if (!getcwd(buf, sizeof buf)) sip_os_fail(SIP_LIT("."));
    return sip_from_c(buf);
}

static void sip_os_chdir(sip_str p) { if (chdir(sip_ffi_cstr(p))) sip_os_fail(p); }

/* 0 — нет, 1 — файл, 2 — папка, 3 — что-то другое */
static int64_t sip_os_kind(sip_str p) {
    struct stat st;
    if (stat(sip_ffi_cstr(p), &st)) return 0;
    return S_ISREG(st.st_mode) ? 1 : S_ISDIR(st.st_mode) ? 2 : 3;
}

static int64_t sip_os_size(sip_str p) {
    struct stat st;
    if (stat(sip_ffi_cstr(p), &st)) sip_os_fail(p);
    return (int64_t)st.st_size;
}

static double sip_os_mtime(sip_str p) {
    struct stat st;
    if (stat(sip_ffi_cstr(p), &st)) sip_os_fail(p);
#ifdef __APPLE__
    return (double)st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9;
#else
    return (double)st.st_mtim.tv_sec + st.st_mtim.tv_nsec / 1e9;
#endif
}

static void sip_os_mkdir(sip_str p, bool exist_ok) {
    if (mkdir(sip_ffi_cstr(p), 0777) == 0) return;
    if (errno == EEXIST && exist_ok && sip_os_kind(p) == 2) return;
    sip_os_fail(p);
}

static void sip_os_remove(sip_str p) { if (remove(sip_ffi_cstr(p))) sip_os_fail(p); }

static void sip_os_rename(sip_str a, sip_str b) { if (rename(sip_ffi_cstr(a), sip_ffi_cstr(b))) sip_os_fail(a); }

static void sip_os_chmod(sip_str p, int64_t mode) { if (chmod(sip_ffi_cstr(p), (mode_t)mode)) sip_os_fail(p); }

static void *sip_os_opendir(sip_str p) {
    DIR *d = opendir(sip_ffi_cstr(p));
    if (!d) sip_os_fail(p);
    return d;
}

static sip_str sip_os_readdir(void *d) {
    struct dirent *e;
    while ((e = readdir((DIR *)d)) != NULL) {
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) return sip_from_c(e->d_name);
    }
    return SIP_NIL_STR;
}

static void sip_os_closedir(void *d) { closedir((DIR *)d); }

static int64_t sip_os_status_of(int r) {
    if (r == -1) return -1;
    return WIFEXITED(r) ? WEXITSTATUS(r) : 128 + WTERMSIG(r);
}

static int64_t sip_os_system(sip_str cmd) {
    fflush(stdout);
    return sip_os_status_of(system(sip_ffi_cstr(cmd)));
}

SIP_GV(int64_t sip_os_last);

static sip_str sip_os_output(sip_str cmd) {
    fflush(stdout);
    FILE *f = popen(sip_ffi_cstr(cmd), "r");
    if (!f) sip_os_fail(cmd);
    sip_sb sb = sip_sb_new();
    char buf[8192];
    size_t k;
    while ((k = fread(buf, 1, sizeof buf, f)) > 0) sip_sb_put(&sb, buf, (int64_t)k);
    sip_os_last = sip_os_status_of(pclose(f));
    return sip_sb_done(&sb);
}

static int64_t sip_os_status(void) { return sip_os_last; }

static int64_t sip_os_pid(void) { return (int64_t)getpid(); }

static sip_str sip_os_platform(void) {
#if defined(__APPLE__)
    return SIP_LIT("darwin");
#elif defined(__linux__)
    return SIP_LIT("linux");
#else
    return SIP_LIT("unix");
#endif
}

/* Регулярные выражения: POSIX ERE (regex.h); сокращения \d \w \s ... переводит std/re.sip */
typedef struct { regex_t re; int64_t ngroups; } sip_re;
typedef struct { int64_t n; regmatch_t m[]; } sip_re_match;

/* posix — шаблон, уже переведённый std/re.sip в POSIX ERE; pat — исходный, для сообщения об ошибке */
static void *sip_re_compile(sip_str posix, sip_str pat) {
    sip_str t = posix;
    sip_re *r = malloc(sizeof *r);  /* шаблоны кэширует std/re.sip, поэтому не освобождаются */
    int err = regcomp(&r->re, sip_ffi_cstr(t), REG_EXTENDED);
    if (err) {
        char msg[256];
        regerror(err, &r->re, msg, sizeof msg);
        free(r);
        sip_raisef(SIP_E_ValueError, sip_std_line, "bad regex '%.*s': %s", (int)pat.n, pat.p, msg);
    }
    r->ngroups = (int64_t)r->re.re_nsub;
    return r;
}

static void *sip_re_subject(sip_str s) { return (void *)sip_ffi_cstr(s); }

static void *sip_re_exec(void *rp, void *subj, int64_t start) {
    sip_re *r = rp;
    const char *s = subj;
    int64_t n = r->ngroups + 1;
    sip_re_match *m = sip_alloc_atomic(sizeof *m + (size_t)n * sizeof(regmatch_t));
    m->n = n;
    if (regexec(&r->re, s + start, (size_t)n, m->m, start > 0 ? REG_NOTBOL : 0)) return NULL;
    for (int64_t i = 0; i < n; i++) {
        if (m->m[i].rm_so >= 0) { m->m[i].rm_so += start; m->m[i].rm_eo += start; }
    }
    return m;
}

static int64_t sip_re_ngroups(void *m) { return ((sip_re_match *)m)->n - 1; }
static int64_t sip_re_start(void *m, int64_t i) { return (int64_t)((sip_re_match *)m)->m[i].rm_so; }
static int64_t sip_re_end(void *m, int64_t i) { return (int64_t)((sip_re_match *)m)->m[i].rm_eo; }
