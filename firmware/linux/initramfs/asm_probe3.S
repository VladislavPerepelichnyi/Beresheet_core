/*
 * The three instruction classes the previous probes never executed.
 *
 * probe2 passed every test: stack growth, brk, a fresh heap page, fork with
 * COW, and a store to address zero that faulted with cause 0x0f, delivered
 * SIGSEGV and panicked exactly as it should. So the MMU, demand paging and
 * signal delivery are all correct, and the machine is not the problem in the
 * way I claimed.
 *
 * But probe2 was still a narrow program. Disassembled, it contains:
 *
 *     atomics (lr.w / sc.w / amo*)   0 instructions
 *     misaligned accesses            0
 *     mmap                           0  (only brk was tested)
 *
 * The musl busybox contains 56 atomic instructions, and every libc's memcpy
 * and string routines perform unaligned word accesses - which on this core
 * trap and are emulated by the kernel. Your boot log says so itself:
 *
 *     Ratio of byte access time to unaligned word access is 0.00,
 *     unaligned accesses are slow
 *
 * A ratio of 0.00 means the unaligned copy was immeasurably slower than the
 * byte copy, i.e. every one of those accesses took a trap. That path works in
 * kernel mode, because the benchmark completed. Whether it works from *user*
 * mode is untested, and a trap-and-emulate that returns to the faulting
 * instruction without making progress is an infinite loop that prints nothing
 * - which is exactly the symptom every libc binary has shown.
 *
 * Every loop below is bounded. A bounded loop that gives up and says so is
 * worth more than one that hangs and says nothing: if sc.w never succeeds we
 * get a message rather than another dead console.
 *
 * rv32 syscalls: openat 56, write 64, exit 93, brk 214, clone 220, mmap 222.
 */

    .section .rodata

mA: .ascii "ASM A: probe3 start\n"
    .equ lA, . - mA

mB: .ascii "ASM B: misaligned load from an odd address (user mode)\n"
    .equ lB, . - mB
mC: .ascii "ASM C: misaligned load returned\n"
    .equ lC, . - mC
mD: .ascii "ASM D: misaligned store to an odd address\n"
    .equ lD, . - mD
mE: .ascii "ASM E: misaligned store returned, value read back matches\n"
    .equ lE, . - mE
mEbad:
    .ascii "ASM E: misaligned store returned but the VALUE IS WRONG\n"
    .equ lEbad, . - mEbad

mF: .ascii "ASM F: amoadd.w\n"
    .equ lF, . - mF
mG: .ascii "ASM G: amoadd.w returned the right old value\n"
    .equ lG, . - mG
mGbad:
    .ascii "ASM G: amoadd.w returned but the RESULT IS WRONG\n"
    .equ lGbad, . - mGbad

mH: .ascii "ASM H: lr.w / sc.w loop, up to 1000 tries\n"
    .equ lH, . - mH
mI: .ascii "ASM I: lr/sc succeeded\n"
    .equ lI, . - mI
mIbad:
    .ascii "ASM I: sc.w NEVER SUCCEEDED in 1000 tries - this hangs every libc\n"
    .equ lIbad, . - mIbad

mJ: .ascii "ASM J: mmap 256 KiB anonymous\n"
    .equ lJ, . - mJ
mK: .ascii "ASM K: mmap returned, touching all 64 pages\n"
    .equ lK, . - mK
mL: .ascii "ASM L: all 64 pages written\n"
    .equ lL, . - mL
mKbad:
    .ascii "ASM K: mmap FAILED\n"
    .equ lKbad, . - mKbad

mZ: .ascii "ASM Z: every remaining instruction class works\n"
    .equ lZ, . - mZ

kmsg_path:
    .asciz "/dev/kmsg"

    .section .text
    .globl _start

    .macro say a, l
    blt     s0, zero, 9f
    mv      a0, s0
    lla     a1, \a
    li      a2, \l
    li      a7, 64
    ecall
9:
    .endm

_start:
    li      a0, -100
    lla     a1, kmsg_path
    li      a2, 1
    li      a3, 0
    li      a7, 56
    ecall
    mv      s0, a0

    say     mA, lA

    /* s1 = an aligned scratch word on the stack; sp is 16-byte aligned. */
    addi    s1, sp, -64

    /* Seed it with a known pattern through aligned stores only. */
    li      t0, 0x12345678
    sw      t0, 0(s1)
    sw      zero, 4(s1)

    /* ---- B/C: misaligned LOAD ------------------------------------- */
    say     mB, lB
    addi    t1, s1, 1               /* deliberately odd               */
    lw      t2, 0(t1)
    say     mC, lC

    /* ---- D/E: misaligned STORE, then read back --------------------- */
    say     mD, lD
    li      t3, 0x0000AA55
    sw      t3, 0(t1)
    lw      t4, 0(t1)

    bne     t3, t4, 1f
    say     mE, lE
    j       2f
1:  say     mEbad, lEbad
2:

    /* ---- F/G: amoadd.w -------------------------------------------- */
    say     mF, lF
    li      t0, 100
    sw      t0, 0(s1)               /* aligned again                  */
    li      t1, 5
    amoadd.w t2, t1, (s1)           /* t2 = old value = 100           */
    li      t3, 100
    bne     t2, t3, 3f
    lw      t4, 0(s1)
    li      t5, 105
    bne     t4, t5, 3f
    say     mG, lG
    j       4f
3:  say     mGbad, lGbad
4:

    /* ---- H/I: lr.w / sc.w, bounded --------------------------------- */
    say     mH, lH
    li      t6, 1000                /* retry budget                   */
5:
    lr.w    t0, (s1)
    addi    t0, t0, 1
    sc.w    t1, t0, (s1)
    beqz    t1, 6f                  /* 0 = success                    */
    addi    t6, t6, -1
    bnez    t6, 5b
    say     mIbad, lIbad
    j       7f
6:  say     mI, lI
7:

    /* ---- J/K/L: mmap, then touch every page ------------------------ */
    say     mJ, lJ
    li      a0, 0                   /* addr: let the kernel choose    */
    li      a1, 262144              /* 256 KiB                        */
    li      a2, 3                   /* PROT_READ|PROT_WRITE           */
    li      a3, 0x22                /* MAP_PRIVATE|MAP_ANONYMOUS      */
    li      a4, -1                  /* fd                             */
    li      a5, 0                   /* offset                         */
    li      a7, 222
    ecall
    li      t0, -4096               /* mmap errors are small negatives */
    bgeu    a0, t0, 8f
    say     mK, lK
    mv      t1, a0
    li      t2, 64                  /* pages                          */
10:
    sw      t2, 0(t1)
    li      t3, 4096
    add     t1, t1, t3
    addi    t2, t2, -1
    bnez    t2, 10b
    say     mL, lL
    j       11f
8:  say     mKbad, lKbad
11:

    say     mZ, lZ

    li      a0, 0
    li      a7, 93
    ecall
hang:
    j       hang
