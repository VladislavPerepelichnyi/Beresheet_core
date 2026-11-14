/*
 * The smallest possible proof that this core reaches user mode.
 *
 * Every diagnostic so far has depended on something that is itself in doubt:
 * a C library's startup, a console driver, an inherited file descriptor, a
 * busybox applet set. This depends on none of them. It is raw RV32 assembly,
 * linked with -nostdlib, and its whole job is to answer one question in a way
 * that cannot be swallowed by a broken console:
 *
 *     does the kernel ever execute a user-mode instruction on this machine?
 *
 * It answers in three escalating ways, so whichever channels work, something
 * appears:
 *
 *   1. write() to /dev/kmsg  - goes to printk, out through
 *      uart_console_write(), the polled path the 60-second boot log proves
 *      works. Needs no inherited fd and no tty.
 *
 *   2. write() to fd 1 and fd 2 - the ordinary path. If (1) prints and this
 *      does not, the fault is stdio or the tty, not the core.
 *
 *   3. a store to address zero - deliberately faults. The kernel then prints
 *      "unhandled signal 11" and, because this is PID 1, panics with
 *      "Attempted to kill init". Both are printk output. This is the
 *      important one: it needs no filesystem, no fd, no console setup and no
 *      cooperation from userspace at all. If NOTHING appears - not even this
 *      - then the kernel never reached user mode, and no amount of busybox or
 *      initramfs configuration was ever going to matter.
 *
 * Syscall numbers are the RV32 generic ABI: openat 56, write 64, exit 93.
 * There is no plain open() on rv32; openat with AT_FDCWD (-100) is the only
 * form.
 */

    .section .rodata
kmsg_path:
    .asciz "/dev/kmsg"

msg:
    .ascii "ASM 1: user mode reached on the hand-written core\n"
msg_end:
    .equ msg_len, msg_end - msg

msg2:
    .ascii "ASM 2: this line came from write(1)\n"
msg2_end:
    .equ msg2_len, msg2_end - msg2

    .section .text
    .globl _start
_start:
    /* ---- 1. openat(AT_FDCWD, "/dev/kmsg", O_WRONLY) ---------------- */
    li      a0, -100                /* AT_FDCWD                        */
    lla     a1, kmsg_path
    li      a2, 1                   /* O_WRONLY                        */
    li      a3, 0
    li      a7, 56                  /* openat                          */
    ecall
    mv      s0, a0                  /* keep the fd (or the error)      */

    /* ---- write(kmsg_fd, msg, msg_len) ------------------------------ */
    blt     s0, zero, try_stdout    /* openat failed - skip ahead      */
    mv      a0, s0
    lla     a1, msg
    li      a2, msg_len
    li      a7, 64                  /* write                           */
    ecall

try_stdout:
    /* ---- 2. write(1, ...) then write(2, ...) ----------------------- */
    li      a0, 1
    lla     a1, msg2
    li      a2, msg2_len
    li      a7, 64
    ecall

    li      a0, 2
    lla     a1, msg2
    li      a2, msg2_len
    li      a7, 64
    ecall

    /* Report what openat returned, through kmsg, as a single digit of
     * evidence about whether the filesystem is mountable at all. Skipped
     * when kmsg itself could not be opened - there is nowhere to say it. */
    blt     s0, zero, fault_now
    mv      a0, s0
    lla     a1, msg
    li      a2, 6                   /* "ASM 1" plus the newline slot   */
    li      a7, 64
    ecall

fault_now:
    /* ---- 3. the unmissable one: store to address zero -------------- */
    li      t0, 0
    sw      t0, 0(t0)

    /* Not reached unless the store to zero somehow succeeded, which would
     * itself be a serious MMU finding. Exit with a distinctive code so the
     * "Attempted to kill init" line names it. */
    li      a0, 77
    li      a7, 93                  /* exit                            */
    ecall

hang:
    j       hang
