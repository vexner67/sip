/* Рантайм Sip для нативной сборки.
 *
 * Подключается в каждый сгенерированный .c файл одной единицей трансляции,
 * поэтому clang может встраивать и оптимизировать всё вместе с кодом программы.
 * Таблицу исходников SIP_FILES генератор определяет в единице с main.
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
 * Сборка запускается, когда занятая память превышает порог: вдвое больше того,
 * что пережило прошлую сборку, но не меньше 64 МБ. Короткие программы обычно
 * не собирают мусор ни разу.
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

static void sip_new_chunk(void) {
    size_t len = SIP_CHUNK + SIP_BLK;
    char *raw = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (raw == MAP_FAILED) sip_oom();
    char *p = (char *)(((uintptr_t)raw + SIP_BLK - 1) & ~(uintptr_t)(SIP_BLK - 1));
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
    size_t lo = 0, hi = sip_nchunks;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if ((uintptr_t)sip_chunks[mid] <= w) lo = mid + 1; else hi = mid;
    }
    if (lo == 0) return NULL;
    uintptr_t c = (uintptr_t)sip_chunks[lo - 1];
    if (w >= c + SIP_CHUNK) return NULL;
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
    size_t next = live * 2;
    sip_gc_next = next > sip_gc_min ? next : sip_gc_min;
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

/* ord: код символа UTF-8; у строки из одного байта — сам байт (s[i] режет по байтам) */
static int64_t sip_ord(sip_str s, int line) {
    if (s.n == 1) return (unsigned char)s.p[0];
    const unsigned char *p = (const unsigned char *)s.p;
    int64_t n = s.n, cp = -1;
    if (n == 2 && (p[0] & 0xE0) == 0xC0) cp = ((p[0] & 0x1F) << 6) | (p[1] & 0x3F);
    else if (n == 3 && (p[0] & 0xF0) == 0xE0) cp = ((p[0] & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F);
    else if (n == 4 && (p[0] & 0xF8) == 0xF0)
        cp = ((p[0] & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F);
    if (cp < 0) sip_raisef(SIP_E_ValueError, line, "ord() expected a character, but string of length %lld found", (long long)n);
    return cp;
}

static sip_str sip_chr(int64_t cp, int line) {
    if (cp < 0 || cp > 0x10FFFF) sip_raisef(SIP_E_ValueError, line, "chr() arg not in range(0x110000)");
    char *p = sip_alloc_atomic(4);
    int n;
    if (cp < 0x80) { p[0] = (char)cp; n = 1; }
    else if (cp < 0x800) { p[0] = (char)(0xC0 | (cp >> 6)); p[1] = (char)(0x80 | (cp & 0x3F)); n = 2; }
    else if (cp < 0x10000) {
        p[0] = (char)(0xE0 | (cp >> 12)); p[1] = (char)(0x80 | ((cp >> 6) & 0x3F)); p[2] = (char)(0x80 | (cp & 0x3F)); n = 3;
    } else {
        p[0] = (char)(0xF0 | (cp >> 18)); p[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        p[2] = (char)(0x80 | ((cp >> 6) & 0x3F)); p[3] = (char)(0x80 | (cp & 0x3F)); n = 4;
    }
    return (sip_str){p, n};
}







static inline bool sip_str_startswith(sip_str s, sip_str p) {
    return p.n <= s.n && memcmp(s.p, p.p, (size_t)p.n) == 0;
}

static inline bool sip_str_endswith(sip_str s, sip_str p) {
    return p.n <= s.n && memcmp(s.p + s.n - p.n, p.p, (size_t)p.n) == 0;
}


static inline bool sip_isspace(char c) { return c == ' ' || (c >= '\t' && c <= '\r'); }

static sip_str sip_str_strip(sip_str s, int left, int right) {
    int64_t a = 0, b = s.n;
    if (left) while (a < b && sip_isspace(s.p[a])) a++;
    if (right) while (b > a && sip_isspace(s.p[b - 1])) b--;
    return (sip_str){s.p + a, b - a};
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
/* ошибки rt.sip — на строке кода пользователя, который вызвал рантайм */
static void sip_rt_parse_error(sip_str msg) { sip_raise(SIP_E_ParseError, msg, sip_std_line); }
static void sip_rt_overflow(sip_str msg) { sip_raise(SIP_E_OverflowError, msg, sip_std_line); }

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
SIP_GV(char *sip_used);          /* какие argv уже разобраны */
SIP_GV(int sip_npos);

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

/* Регулярные выражения: POSIX ERE (regex.h) и сокращения \d \w \s \D \W \S, в том числе внутри [...] */
typedef struct { regex_t re; int64_t ngroups; } sip_re;
typedef struct { int64_t n; regmatch_t m[]; } sip_re_match;

static void *sip_re_compile(sip_str pat) {
    sip_sb sb = sip_sb_new();
    int in_class = 0;
    for (int64_t i = 0; i < pat.n; i++) {
        char c = pat.p[i];
        if (c == '\\' && i + 1 < pat.n) {
            char d = pat.p[++i];
            const char *cls = d == 'd' ? "0-9" : d == 'w' ? "[:alnum:]_" : d == 's' ? "[:space:]" : NULL;
            const char *neg = d == 'D' ? "0-9" : d == 'W' ? "[:alnum:]_" : d == 'S' ? "[:space:]" : NULL;
            if (cls) {
                if (in_class) sip_sb_put(&sb, cls, (int64_t)strlen(cls));
                else { sip_sb_putc(&sb, '['); sip_sb_put(&sb, cls, (int64_t)strlen(cls)); sip_sb_putc(&sb, ']'); }
            } else if (neg && !in_class) {
                sip_sb_put(&sb, "[^", 2); sip_sb_put(&sb, neg, (int64_t)strlen(neg)); sip_sb_putc(&sb, ']');
            } else if (d == 'n' || d == 't' || d == 'r') {
                sip_sb_putc(&sb, d == 'n' ? '\n' : d == 't' ? '\t' : '\r');
            } else if (in_class) {
                sip_sb_putc(&sb, d);  /* [\]] и т. п.: символ как есть */
            } else {
                sip_sb_putc(&sb, '\\'); sip_sb_putc(&sb, d);
            }
            continue;
        }
        if (!in_class && c == '[') {
            in_class = 1;
            sip_sb_putc(&sb, c);
            if (i + 1 < pat.n && pat.p[i + 1] == '^') sip_sb_putc(&sb, pat.p[++i]);
            if (i + 1 < pat.n && pat.p[i + 1] == ']') sip_sb_putc(&sb, pat.p[++i]);
            continue;
        }
        if (in_class && c == '[' && i + 1 < pat.n && pat.p[i + 1] == ':') {  /* [:alpha:] */
            const char *end = memchr(pat.p + i + 2, ']', (size_t)(pat.n - i - 2));
            if (end) {
                int64_t k = end - pat.p;
                sip_sb_put(&sb, pat.p + i, k - i + 1);
                i = k;
                continue;
            }
        }
        if (in_class && c == ']') in_class = 0;
        sip_sb_putc(&sb, c);
    }
    sip_str t = sip_sb_done(&sb);
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
