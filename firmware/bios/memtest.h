#ifndef MEMTEST_H
#define MEMTEST_H

#include <stdint.h>

/*
 * Run the SDRAM test suite. `stride` is in words: 1 touches every location,
 * larger values sample, which keeps simulation runs finite.
 * Returns the number of failures.
 */
int memtest_run(uint32_t stride);

#endif
