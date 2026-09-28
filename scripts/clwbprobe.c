// Does CLWB leave the written-back line in the cache on this CPU?
//
// The instruction-level half of the CLWB-eviction experiment
// (scripts/clwb-eviction.sh). Deliberately plain C, independent of the engine
// and of pwbench, so the answer does not rest on the code under suspicion.
//
// Each sample dirties one line, optionally writes it back, fences, and then
// times one re-access of that line:
//
//   load   lfence; rdtsc; lfence; load; lfence; rdtsc
//   store  lfence; rdtsc; lfence; store; mfence; rdtsc   (mfence waits for the
//          store to reach L1, so an RFO miss is inside the window)
//
// with writeback none, clwb or clflushopt, on anonymous DRAM and on a MAP_SYNC
// mapping of a file on a DAX mount. A line that stayed cached re-accesses at
// the none row's cost; a line that was invalidated re-accesses at the cost of
// a miss to its medium. The store probe is the one the WAL workload resembles:
// record construction writes lines the previous commits wrote back.
//
// One line per page, at a different offset in each page, so the adjacent-line
// and streaming prefetchers have nothing to pair; the store that dirties the
// line also warms its TLB entry, and 64 pages fit the first-level DTLB.
//
//   cc -O2 -mclwb -mclflushopt -o clwbprobe scripts/clwbprobe.c
//   numactl --cpunodebind=0 --membind=0 ./clwbprobe <scratch file on a DAX mount>
//
// The scratch file is created (O_EXCL) and removed; an existing file is never
// touched. Output lines are "<medium> <access> <writeback> p10 <c> median <c>
// p90 <c>" in TSC cycles; the script parses them.

#define _GNU_SOURCE
#include <cpuid.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <x86intrin.h>

#ifndef MAP_SYNC
#define MAP_SYNC 0x80000
#endif
#ifndef MAP_SHARED_VALIDATE
#define MAP_SHARED_VALIDATE 0x03
#endif

enum { PAGES = 64, ROUNDS = 4000, SIZE = PAGES * 4096 };
enum { WB_NONE, WB_CLWB, WB_CLFLUSHOPT, WB_COUNT };
enum { ACCESS_LOAD, ACCESS_STORE, ACCESS_COUNT };

static const char *wb_names[WB_COUNT] = { "none", "clwb", "clflushopt" };
static const char *access_names[ACCESS_COUNT] = { "load", "store" };
static uint64_t samples[PAGES * ROUNDS];

static int cmp_u64(const void *a, const void *b) {
    uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
    return (x > y) - (x < y);
}

// The writeback intrinsics take a non-volatile pointer; the line is only ever
// accessed through volatile ones, so the compiler cannot move the accesses.
static inline void writeback(volatile char *p, int wb) {
    if (wb == WB_CLWB) _mm_clwb((void *)p);
    else if (wb == WB_CLFLUSHOPT) _mm_clflushopt((void *)p);
}

static void measure(const char *medium, volatile char *base, int access, int wb) {
    int n = 0;
    for (int r = 0; r < ROUNDS; r++) {
        for (int i = 0; i < PAGES; i++) {
            volatile char *p = base + (size_t)i * 4096 + (size_t)(i % 64) * 64;
            *p = (char)r;               // dirty the line
            writeback(p, wb);
            _mm_mfence();               // writeback ordered; store buffer drained
            _mm_lfence();
            uint64_t t0 = __rdtsc();
            _mm_lfence();
            if (access == ACCESS_LOAD) {
                (void)*p;
                _mm_lfence();
            } else {
                *p = (char)(r + 1);
                _mm_mfence();
            }
            uint64_t t1 = __rdtsc();
            samples[n++] = t1 - t0;
        }
    }
    qsort(samples, n, sizeof samples[0], cmp_u64);
    printf("%-5s %-5s %-10s p10 %5lu median %5lu p90 %5lu\n", medium,
           access_names[access], wb_names[wb],
           (unsigned long)samples[n / 10], (unsigned long)samples[n / 2],
           (unsigned long)samples[(n * 9) / 10]);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <scratch file to create on a DAX mount>\n", argv[0]);
        return 2;
    }
    setvbuf(stdout, NULL, _IOLBF, 0);   // the script tees this; keep lines whole and ordered
    unsigned a, b, c, d;
    if (!__get_cpuid_count(7, 0, &a, &b, &c, &d)) {
        fprintf(stderr, "CPUID leaf 7 is not available\n");
        return 2;
    }
    int has_clwb = (b >> 24) & 1, has_clflushopt = (b >> 23) & 1;
    unsigned eax1 = 0, ebx1, ecx1, edx1;
    __get_cpuid(1, &eax1, &ebx1, &ecx1, &edx1);
    unsigned family = (eax1 >> 8) & 0xf, model = (eax1 >> 4) & 0xf, stepping = eax1 & 0xf;
    if (family == 6 || family == 15) model += ((eax1 >> 16) & 0xf) << 4;
    if (family == 15) family += (eax1 >> 20) & 0xff;
    printf("cpu family %u model %u stepping %u clwb %s clflushopt %s\n", family, model,
           stepping, has_clwb ? "yes" : "no", has_clflushopt ? "yes" : "no");
    if (!has_clwb || !has_clflushopt) {
        fprintf(stderr, "this CPU lacks CLWB or CLFLUSHOPT; the comparison cannot be made\n");
        return 2;
    }

    char *dram = mmap(NULL, SIZE, PROT_READ | PROT_WRITE,
                      MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
    if (dram == MAP_FAILED) { perror("mmap (anonymous)"); return 1; }

    int fd = open(argv[1], O_RDWR | O_CREAT | O_EXCL, 0600);
    if (fd < 0) { perror(argv[1]); return 1; }
    int err = posix_fallocate(fd, 0, SIZE);
    char *pmem = MAP_FAILED;
    if (err == 0) {
        pmem = mmap(NULL, SIZE, PROT_READ | PROT_WRITE,
                    MAP_SHARED_VALIDATE | MAP_SYNC | MAP_POPULATE, fd, 0);
        if (pmem == MAP_FAILED) err = errno;
    }
    unlink(argv[1]);
    close(fd);
    if (err != 0) {
        fprintf(stderr, "%s: %s (MAP_SYNC needs a file on a filesystem-DAX mount)\n",
                argv[1], strerror(err));
        return 1;
    }

    for (int access = 0; access < ACCESS_COUNT; access++) {
        for (int wb = 0; wb < WB_COUNT; wb++) {
            measure("dram", dram, access, wb);
            measure("pmem", pmem, access, wb);
        }
    }
    return 0;
}
