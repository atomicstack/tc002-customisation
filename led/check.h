/* minimal test checks: count failures, print each, summarise. no framework needed. */
#ifndef CHECK_H
#define CHECK_H

#include <math.h>
#include <stdio.h>

static int checks_run = 0;
static int checks_failed = 0;

#define CHECK(cond) do { \
    checks_run++; \
    if (!(cond)) { checks_failed++; fprintf(stderr, "  fail %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
} while (0)

#define CHECK_EQ(a, b) do { \
    long long _a = (long long)(a), _b = (long long)(b); \
    checks_run++; \
    if (_a != _b) { checks_failed++; fprintf(stderr, "  fail %s:%d: %s == %s (got %lld, want %lld)\n", __FILE__, __LINE__, #a, #b, _a, _b); } \
} while (0)

#define CHECK_NEAR(a, b, eps) do { \
    double _a = (double)(a), _b = (double)(b); \
    checks_run++; \
    if (fabs(_a - _b) > (eps)) { checks_failed++; fprintf(stderr, "  fail %s:%d: %s ~= %s (got %g, want %g)\n", __FILE__, __LINE__, #a, #b, _a, _b); } \
} while (0)

static int check_summary(const char *name) {
    printf("%s: %d checks, %d failed\n", name, checks_run, checks_failed);
    return checks_failed ? 1 : 0;
}

#endif
