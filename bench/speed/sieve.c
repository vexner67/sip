#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
int main(void) {
    long n = 20000000;
    bool *p = malloc(n + 1);
    memset(p, 1, n + 1);
    p[0] = p[1] = 0;
    for (long i = 2; i * i <= n; i++)
        if (p[i]) for (long j = i * i; j <= n; j += i) p[j] = 0;
    long c = 0;
    for (long i = 0; i <= n; i++) c += p[i];
    printf("%ld\n", c);
    return 0;
}
