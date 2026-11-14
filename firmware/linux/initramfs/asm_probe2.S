/*
 * Which kind of page fault hangs this machine?
 *
 * The previous probe printed "user mode reached" and "this line came from
 * write(1)", which settles a lot: user mode, ecall, openat, write, the tty and
 * stdio all work. But that program was smaller than it looked. Its single LOAD
 * segment is 0x10000..0x10174 - entry, both strings, everything inside one
 * 4 KiB page - and write() passes its arguments in registers while ecall
 * pushes nothing, so it never touched the stack either.
 *
 * It caused exactly ONE page fault in its entire life, and that one worked.
 *
 * Two things then stand out. The store to address zero at the end should have
 * produced "unhandled signal 11" followed by "Attempted to kill init", both
 * printk output - and neither appeared. And every libc, glibc and musl alike,
 * touches fresh anonymous memory before it prints anything: a thread pointer,
 * a malloc arena, a deeper stack frame. Raw assembly that stays inside one
 * already-mapped page does not.
 *
 * So this walks up the fault types one at a time, announcing each step through
 * /dev/kmsg *before* attempting it. Whichever message is last on the console
 * names the operation that hangs. No libc, no allocation by us, nothing that
 * could hang for its own reasons.
 *
 *   A  start                     - kmsg works, as before
 *   B  store just below sp       - the initial stack pages the kernel mapped
 *   C  store 8 KiB below sp      - forces expand_downwards: a NEW anon page
 *   D  brk(0)                    - read the current break
 *   E  brk(+8 KiB)               - extend it
 *   F  store into the new break  - first touch of a fresh anon page
 *   G  clone(SIGCHLD)            - fork, whose COW is the next suspect
 *   H  store to address 0        - must fault, and must be delivered as a
 *                                  signal rather than resolved. If A..G print
 *                                  and H's line is last, the fault path can
 *                                  map pages but cannot deliver SIGSEGV.
 *
 * rv32 syscall numbers, generic ABI: openat 56, write 64, exit 93, getpid 172,
 * brk 214, clone 220. There is no fork(); clone(SIGCHLD, 0) is the equivalent.
 */

    .section .rodata

mA: .ascii "ASM A: probe2 start, kmsg open\n"
    .equ lA, . - mA
mB: .ascii "ASM B: storing just below sp (already-mapped stack)\n"
    .equ lB, . - mB
mC: .ascii "ASM C: storing 8 KiB below sp (forces a new stack page)\n"
    .equ lC, . - mC
mD: .ascii "ASM D: calling brk(0)\n"
    .equ lD, . - mD
mE: .ascii "ASM E: extending brk by 8 KiB\n"
    .equ lE, . - mE
mF: .ascii "ASM F: storing into the newly broken heap page\n"
    .equ lF, . - mF
mG: .ascii "ASM G: clone(SIGCHLD) - fork\n"
    .equ lG, . - mG
mGp:.ascii "ASM G+: fork returned in the parent\n"
    .equ lGp, . - mGp
mH: .ascii "ASM H: storing to address 0, expect SIGSEGV then panic\n"
    .equ lH, . - mH
mI: .ascii "ASM I: THE NULL STORE DID NOT FAULT - MMU allows writes to 0\n"
    .equ lI, . - mI

    .section .text
    .globl _start

/* say <addr>, <len> - write to the kmsg fd held in s0, if it opened. */
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
    /* openat(AT_FDCWD, "/dev/kmsg", O_WRONLY) */
    li      a0, -100
    lla     a1, kmsg_path
    li      a2, 1
    li      a3, 0
    li      a7, 56
    ecall
    mv      s0, a0

    say     mA, lA

    /* ---- B: a store into the stack the kernel already mapped ------- */
    say     mB, lB
    sw      zero, -32(sp)

    /* ---- C: 8 KiB below sp, which the kernel must grow the stack for */
    say     mC, lC
    li      t1, -8192
    add     t1, sp, t1
    sw      zero, 0(t1)

    /* ---- D: current break ------------------------------------------ */
    say     mD, lD
    li      a0, 0
    li      a7, 214
    ecall
    mv      s1, a0                  /* old break                       */

    /* ---- E: extend it ---------------------------------------------- */
    say     mE, lE
    li      t2, 8192
    add     a0, s1, t2
    li      a7, 214
    ecall

    /* ---- F: touch the fresh anonymous page ------------------------- */
    say     mF, lF
    sw      zero, 0(s1)

    /* ---- G: fork --------------------------------------------------- */
    say     mG, lG
    li      a0, 17                  /* SIGCHLD, no CLONE_* flags       */
    li      a1, 0
    li      a7, 220                 /* clone                           */
    ecall
    bnez    a0, 1f                  /* parent continues                */
    /* child: leave immediately, nothing to report */
    li      a0, 0
    li      a7, 93
    ecall
1:
    say     mGp, lGp

    /* ---- H: the fault that must be delivered, not resolved --------- */
    say     mH, lH
    sw      zero, 0(zero)

    /* Reached only if a store to address 0 succeeded, which is itself a
     * serious MMU finding worth saying out loud. */
    say     mI, lI
    li      a0, 77
    li      a7, 93
    ecall

hang:
    j       hang

    .section .rodata
kmsg_path:
    .asciz "/dev/kmsg"
