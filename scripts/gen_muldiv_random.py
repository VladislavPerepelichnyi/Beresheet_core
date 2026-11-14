#!/usr/bin/env python3
"""
Generate a randomised RV32M test from a reference model.

Directed tests prove the cases you thought of. For arithmetic units the cases
you did not think of are the dangerous ones, so this emits a few hundred random
operand pairs across all eight RV32M instructions, with every expected value
computed here from the spec:

  * MUL / MULH / MULHU / MULHSU per section 12.1
  * DIV / DIVU / REM / REMU per section 12.2 and Table 11, including
    division by zero and signed overflow

Usage:  gen_muldiv_random.py [cases] [seed] > tests/rv32i/07_muldiv_random.S
The seed is fixed by default so the generated test is reproducible and can be
committed alongside the RTL.
"""

import random
import sys

M32 = 0xFFFFFFFF
M64 = 0xFFFFFFFFFFFFFFFF


def s32(x):
    """Reinterpret the low 32 bits of x as a signed value."""
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def u32(x):
    return x & M32


# --- Reference model ------------------------------------------------------
def ref_mul(a, b):
    return u32(s32(a) * s32(b))


def ref_mulh(a, b):
    return u32(((s32(a) * s32(b)) >> 32))


def ref_mulhu(a, b):
    return u32((u32(a) * u32(b)) >> 32)


def ref_mulhsu(a, b):
    return u32((s32(a) * u32(b)) >> 32)


def ref_div(a, b):
    if u32(b) == 0:
        return M32                                  # quotient all ones
    x, y = s32(a), s32(b)
    if x == -(1 << 31) and y == -1:
        return u32(x)                               # overflow: quotient = dividend
    q = abs(x) // abs(y)                            # truncate towards zero
    return u32(-q if (x < 0) != (y < 0) else q)


def ref_divu(a, b):
    if u32(b) == 0:
        return M32
    return u32(u32(a) // u32(b))


def ref_rem(a, b):
    if u32(b) == 0:
        return u32(a)                               # remainder = dividend
    x, y = s32(a), s32(b)
    if x == -(1 << 31) and y == -1:
        return 0                                    # overflow: remainder = 0
    r = abs(x) % abs(y)
    return u32(-r if x < 0 else r)                  # sign of the dividend


def ref_remu(a, b):
    if u32(b) == 0:
        return u32(a)
    return u32(u32(a) % u32(b))


OPS = [
    ("mul",    ref_mul),
    ("mulh",   ref_mulh),
    ("mulhsu", ref_mulhsu),
    ("mulhu",  ref_mulhu),
    ("div",    ref_div),
    ("divu",   ref_divu),
    ("rem",    ref_rem),
    ("remu",   ref_remu),
]

# Values that historically break multiply/divide hardware, always included
CORNERS = [
    0x00000000, 0x00000001, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000,
    0x80000001, 0x00010000, 0xFFFF0000, 0x0000FFFF, 0xAAAAAAAA,
    0x55555555, 0x00000002, 0xFFFFFFFE, 0x40000000, 0xC0000000,
]


def operands(rng, n):
    """Corner-by-corner pairs first, then random ones."""
    pairs = [(a, b) for a in CORNERS for b in CORNERS]
    rng.shuffle(pairs)
    while len(pairs) < n:
        pick = lambda: rng.choice(CORNERS) if rng.random() < 0.25 \
            else rng.getrandbits(32)
        pairs.append((pick(), pick()))
    return pairs[:n]


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 2048
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 20260820
    rng = random.Random(seed)

    per_op = max(1, n // len(OPS))
    total = per_op * len(OPS)

    out = []
    w = out.append
    w("/*")
    w(" * 07_muldiv_random - GENERATED, do not edit by hand.")
    w(" *")
    w(" * Produced by scripts/gen_muldiv_random.py, which carries a reference")
    w(" * model of all eight RV32M instructions written straight from the spec.")
    w(f" *   cases : {total} ({per_op} per instruction)")
    w(f" *   seed  : {seed}")
    w(" *")
    w(" * Operands and expected results live in .rodata as (a, b, expected)")
    w(" * triples, and one loop per instruction walks its own table. That costs")
    w(" * 12 bytes per case instead of the ~36 an inline sequence needs, so many")
    w(" * more cases fit in the same memory - and it adds a load-use hazard")
    w(" * feeding the M unit on every iteration, which the inline form cannot.")
    w(" *")
    w(" * On failure a0 = <op base> + <1-based case index>, so 3017 means the")
    w(" * 17th mulhsu case. Bases are listed against each table below.")
    w(" *")
    w(" * Regenerate with:  make regen-random CASES=<n> SEED=<n>")
    w(" */")
    w("")
    w('#include "test_macros.h"')
    w("")
    w("/*")
    w(" * s0 table cursor   s1 table end   s2/s3 operands")
    w(" * s4 expected       s5 actual      s6 case id")
    w(" */")
    w(".macro RUN_OP mnem, tbl, base")
    w("        la      s0, \\tbl")
    w("        la      s1, \\tbl\\()_end")
    w("        li      s6, \\base")
    w("9:      lw      s2, 0(s0)")
    w("        lw      s3, 4(s0)")
    w("        lw      s4, 8(s0)")
    w("        \\mnem   s5, s2, s3")
    w("        addi    s6, s6, 1")
    w("        add     a0, s6, x0")
    w("        bne     s5, s4, test_fail")
    w("        addi    s0, s0, 12")
    w("        blt     s0, s1, 9b")
    w(".endm")
    w("")
    w("TEST_ENTRY")
    w("")

    tables = []
    for idx, (mnem, model) in enumerate(OPS):
        base = (idx + 1) * 10000
        w(f"        RUN_OP  {mnem}, tbl_{mnem}, {base}")
        rows = []
        for a, b in operands(rng, per_op):
            rows.append((a, b, model(a, b)))
        tables.append((mnem, base, rows))

    w("")
    w("TEST_END")
    w("")
    w("        .section .rodata")
    w("        .align  2")
    for mnem, base, rows in tables:
        w("")
        w(f"        # {mnem}: a0 = {base} + case index on failure")
        w(f"tbl_{mnem}:")
        for a, b, e in rows:
            w(f"        .word 0x{a:08X}, 0x{b:08X}, 0x{e:08X}")
        w(f"tbl_{mnem}_end:")

    print("\n".join(out))


if __name__ == "__main__":
    main()
