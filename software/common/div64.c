/*
 * 64-bit division helpers that GCC calls on RV32 (__udivdi3, __umoddi3,
 * __divdi3, __moddi3).
 *
 * They normally come from libgcc, but a distribution's rv32 libgcc may be
 * built for rv32imac (Fedora's is), and compressed instructions are illegal on
 * this core. Linking these first keeps the images independent of how the
 * toolchain's libgcc was built. Results follow the RISC-V M extension: x / 0
 * is all ones, x % 0 is x, and INT64_MIN / -1 is INT64_MIN.
 */
#include <stdint.h>

static uint64_t udivmod64(uint64_t n, uint64_t d, uint64_t *rem)
{
    if (d == 0) {
        *rem = n;
        return ~(uint64_t)0;
    }
    /* Both operands fit in 32 bits: one hardware divu/remu. */
    if ((n >> 32) == 0 && (d >> 32) == 0) {
        *rem = (uint32_t)n % (uint32_t)d;
        return (uint32_t)n / (uint32_t)d;
    }
    /* Restoring division, one quotient bit per step. Only constant shifts are
       used: a variable 64-bit shift would itself be a libgcc call. */
    uint64_t q = 0, r = 0;
    for (int i = 0; i < 64; i++) {
        r = (r << 1) | (n >> 63);
        n <<= 1;
        q <<= 1;
        if (r >= d) {
            r -= d;
            q |= 1;
        }
    }
    *rem = r;
    return q;
}

uint64_t __udivdi3(uint64_t n, uint64_t d)
{
    uint64_t r;
    return udivmod64(n, d, &r);
}

uint64_t __umoddi3(uint64_t n, uint64_t d)
{
    uint64_t r;
    udivmod64(n, d, &r);
    return r;
}

/* Signed forms divide the magnitudes; unsigned negation keeps INT64_MIN defined. */
int64_t __divdi3(int64_t a, int64_t b)
{
    uint64_t ua = a < 0 ? -(uint64_t)a : (uint64_t)a;
    uint64_t ub = b < 0 ? -(uint64_t)b : (uint64_t)b;
    uint64_t r;
    if (b == 0)
        return -1;
    uint64_t q = udivmod64(ua, ub, &r);
    return (int64_t)(((a < 0) != (b < 0)) ? -q : q);
}

int64_t __moddi3(int64_t a, int64_t b)
{
    uint64_t ua = a < 0 ? -(uint64_t)a : (uint64_t)a;
    uint64_t ub = b < 0 ? -(uint64_t)b : (uint64_t)b;
    uint64_t r;
    if (b == 0)
        return a;
    udivmod64(ua, ub, &r);
    return (int64_t)(a < 0 ? -r : r);
}
