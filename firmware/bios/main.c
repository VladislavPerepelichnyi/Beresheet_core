/*
 * Beresheet BIOS: boot ROM self test and loader.
 *
 * Runs from boot RAM at the reset vector. The UART comes up first so every
 * later failure is visible, then the CPU, CSRs, traps, CLINT, PLIC and atomics
 * are tested before anything depends on them, then SDRAM. After that the build
 * selects what happens next:
 *
 *   default        probe the SD card, then run the LED demo from the timer
 *                  interrupt
 *   BOOT_FROM_SD   load the files named in BOOT.TXT and hand off to the SBI
 *                  (see boot.h); fall back to the LED demo on failure
 *   BOOT_ENTRY     images were preloaded into SDRAM by the simulator; skip the
 *                  destructive SDRAM tests and hand off to BOOT_ENTRY
 *
 * Under SIMULATION, main() returns its error count, which crt0.S leaves in a0
 * for the testbench at the final ebreak.
 */
#include "soc.h"
#include "uart.h"
#include "memtest.h"
#include "csr.h"
#include "clint.h"
#include "leds.h"
#include "plic.h"
#include "atomic.h"
#include "trap.h"
#include "sdcard.h"
#include "fat32.h"
#include "boot.h"

#if defined(BOOT_ENTRY) && (!defined(BOOT_DTB) || !defined(BOOT_NEXT_ADDR))
#error "BOOT_ENTRY also needs BOOT_DTB and BOOT_NEXT_ADDR"
#endif

/* File printed by the SD probe if present. The simulated card built by
 * scripts/mksdimage.py contains it, which exercises fat32_read(). */
#define SD_PROBE_FILE "CLAUDE.TXT"

/* sd_init() attempts in the SD probe; some cards need several after power-up. */
#define SD_INIT_ATTEMPTS 10

static void banner(void)
{
    uart_puts("\n");
    uart_puts("================================================\n");
    uart_puts(" Beresheet  RV32IMA  Tang Nano 20K\n");
    uart_puts(" mini BIOS\n");
    uart_puts("================================================\n");
    /* The UART divisor comes from CPU_HZ, and OpenSBI later reprograms it from
     * the device tree, so a clock mismatch shows up after this banner. */
    uart_puts(" clock  : ");
    uart_putdec(CPU_HZ / 1000000u);
    uart_puts(" MHz\n");
    uart_puts(" baud   : ");
    uart_putdec(BAUD);
    uart_puts("\n");
    uart_puts(" boot   : 0x");
    uart_puthex(BOOT_BASE, 8);
    uart_puts(" + ");
    uart_putdec(BOOT_SIZE / 1024u);
    uart_puts(" KB\n");
    uart_puts(" plic   : 0x");
    uart_puthex(PLIC_BASE, 8);
    uart_puts("\n");
    uart_puts(" uart   : 0x");
    uart_puthex(UART_BASE, 8);
    uart_puts("  (plic source ");
    uart_putdec(PLIC_SRC_UART);
    uart_puts(")\n");
    uart_puts(" sdram  : 0x");
    uart_puthex(SDRAM_BASE, 8);
    uart_puts(" + ");
    uart_putdec(SDRAM_SIZE / (1024u * 1024u));
    uart_puts(" MB\n");
    uart_puts(" misa   : 0x");
    uart_puthex(csr_read(misa), 8);
    uart_puts("  (RV32 + I + M + A + S + U)\n");
    /* The boot mode is a compile-time choice; say which one this build is. */
    uart_puts(" boot   : ");
#ifdef BOOT_FROM_SD
    uart_puts("SD card, " BOOT_DESC_FILE);
#elif defined(BOOT_ENTRY)
    uart_puts("hand off to a preloaded image");
#else
    uart_puts("self tests then the LED demo (no SD boot in this build)");
#endif
    uart_puts("\n");
    uart_puts(" hartid : ");
    uart_putdec(csr_read(mhartid));
    uart_puts("\n");
    uart_puts("================================================\n");
}

/* Print a 64-bit value in decimal, for the SDRAM test's cycle counts. The
 * 64-bit divide comes from libgcc (-lgcc). */
#ifndef BOOT_ENTRY
static void put_u64(uint64_t v)
{
    char buf[21];
    int n = 0;

    if (v == 0) {
        uart_putc('0');
        return;
    }
    while (v > 0) {
        buf[n++] = (char)('0' + (uint32_t)(v % 10u));
        v /= 10u;
    }
    while (n-- > 0)
        uart_putc(buf[n]);
}
#endif

/* ------------------------------------------------------------------------ */
/* CPU, CSR and trap self tests                                              */
/* ------------------------------------------------------------------------ */

/* Counters must be monotonic, and instret can never exceed cycle. */
static int csr_selftest(void)
{
    uint64_t c0, c1, i0, i1, t0, t1;
    int errors = 0;

    uart_puts("CSR self test\n");

    uart_puts("  counters    ");
    c0 = read_cycle64();  i0 = read_instret64();  t0 = read_time64();
    c1 = read_cycle64();  i1 = read_instret64();  t1 = read_time64();
    if (c1 <= c0 || i1 <= i0 || t1 <= t0) {
        uart_puts("FAILED (not monotonic)\n"); errors++;
    } else if (i1 > c1) {
        uart_puts("FAILED (instret exceeds cycle)\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  read/write  ");
    csr_write(mscratch, 0xA5A50F0Fu);
    if (csr_read(mscratch) != 0xA5A50F0Fu) {
        uart_puts("FAILED\n"); errors++;
    } else {
        csr_set(mscratch, 0x0000F0F0u);
        csr_clear(mscratch, 0xA5A50000u);
        if (csr_read(mscratch) != 0x0000FFFFu) {
            uart_puts("FAILED\n"); errors++;
        } else uart_puts("ok\n");
    }

    return errors;
}

/* ALU and RV32M, before they are trusted to run the memory test. */
static int cpu_selftest(void)
{
    volatile int32_t  a = -1234;
    volatile int32_t  b = 5678;
    volatile uint32_t u = 0xFFFFFFFFu;
    volatile int32_t  z = 0;          /* volatile so the divide is really emitted */
    int errors = 0;

    uart_puts("CPU self test\n");

    uart_puts("  rv32i alu   ");
    if (((a + b) != 4444) || ((b - a) != 6912) ||
        ((u >> 28) != 0xFu) || ((a >> 4) != -78) || ((0xF0F0u & 0x0FF0u) != 0x00F0u)) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  rv32m mul   ");
    if (((a * b) != -7006652) || ((int32_t)(((int64_t)a * b) >> 32) != -1)) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  rv32m div   ");
    /* Division truncates towards zero and the remainder takes the dividend's
     * sign. Division by zero returns all ones and remainder = dividend. */
    if ((a / b) != 0 || (a % b) != -1234 ||
        (b / 100) != 56 || (b % 100) != 78 ||
        (a / z) != -1 || (a % z) != a) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    return errors;
}

/*
 * Exceptions, through the handler crt0.S installed. The faulting instructions
 * are written in assembly: a misaligned access through a C pointer is
 * undefined behaviour, and the compiler may remove it.
 */
static int trap_selftest(void)
{
    uint32_t before;
    int errors = 0;

    uart_puts("Trap handling\n");

    uart_puts("  ecall       ");
    before = trap_count;
    __asm__ volatile ("ecall");
    if (trap_count != before + 1u || last_cause != 11u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  illegal     ");
    before = trap_count;
    /* ld (RV64 only): a valid opcode with a funct3 RV32 does not have. */
    __asm__ volatile (".word 0x00033283");
    if (trap_count != before + 1u || last_cause != 2u ||
        last_tval != 0x00033283u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  misaligned  ");
    before = trap_count;
    __asm__ volatile ("li   t0, 0x102\n\t"
                      "lw   t1, 0(t0)"     /* address 2 mod 4: cause 4 */
                      ::: "t0", "t1");
    if (trap_count != before + 1u || last_cause != 4u ||
        last_tval != 0x102u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  store misal ");
    before = trap_count;
    __asm__ volatile ("li   t0, 0x101\n\t"
                      "sh   t1, 0(t0)"     /* odd address for a halfword: cause 6 */
                      ::: "t0");
    if (trap_count != before + 1u || last_cause != 6u ||
        last_tval != 0x101u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    /*
     * Ten traps in a row from an absent CSR (pmpcfg0; the core has no PMP), the
     * way OpenSBI probes for optional CSRs at boot.
     */
    uart_puts("  probe x10   ");
    before = trap_count;
    for (int i = 0; i < 10; i++)
        __asm__ volatile ("csrr t0, 0x3A0" ::: "t0");
    if (trap_count != before + 10u || last_cause != 2u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    return errors;
}

/* ------------------------------------------------------------------------ */
/* Interrupts: CLINT timer and PLIC                                          */
/* ------------------------------------------------------------------------ */

static int timer_selftest(void)
{
    uint64_t t0, t1;
    uint32_t ticks0;
    int errors = 0;
    volatile uint32_t spin;

    uart_puts("CLINT\n");

    uart_puts("  mtime runs  ");
    t0 = clint_mtime();
    for (spin = 0; spin < 2000u; spin++)
        ;
    t1 = clint_mtime();
    if (t1 <= t0) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    /* Zicntr: the time CSR reads the CLINT's mtime. */
    uart_puts("  time = mtime ");
    {
        uint64_t c = read_time64();
        uint64_t m = clint_mtime();
        if (m < c || (m - c) > 64u) {
            uart_puts("FAILED\n"); errors++;
        } else uart_puts("ok\n");
    }

    uart_puts("  masked      ");
    ticks0 = timer_ticks;
    clint_next_tick(100u);                 /* due in 100 us, but MTIE is off */
    for (spin = 0; spin < 4000u; spin++)
        ;
    if (timer_ticks != ticks0) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  enabled     ");
    ticks0 = timer_ticks;
    timer_period_us = 1000u;               /* 1 kHz while testing */
    clint_next_tick(timer_period_us);
    csr_set(mie, 1u << 7);                 /* MTIE */
    csr_set(mstatus, 1u << 3);             /* MIE */
    for (spin = 0; spin < 40000u && timer_ticks < ticks0 + 3u; spin++)
        ;
    if (timer_ticks < ticks0 + 3u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    /* A handler that failed to move mtimecmp would re-enter continuously and
     * the count here would be enormous. */
    uart_puts("  rate sane   ");
    ticks0 = timer_ticks;
    for (spin = 0; spin < 20000u; spin++)
        ;
    {
        uint32_t got = timer_ticks - ticks0;
        if (got > 200u) {
            uart_puts("FAILED (runaway)\n"); errors++;
        } else uart_puts("ok\n");
    }

    csr_clear(mstatus, 1u << 3);           /* interrupts off for the memtest */
    return errors;
}

/*
 * PLIC: first with a software-driven source, to test priority, threshold and
 * claim/complete in isolation; then with the UART's interrupt line, to check
 * that the device is wired to the source number the drivers expect.
 */
static int plic_selftest(void)
{
    int errors = 0;
    volatile uint32_t spin;
    uint32_t n0;

    uart_puts("PLIC\n");

    uart_puts("  registers   ");
    plic_set_priority(PLIC_SRC_SW(0), 5u);
    plic_set_threshold(PLIC_CTX_M0, 3u);
    plic_enable(PLIC_CTX_M0, PLIC_SRC_SW(0), 1);
    if (mmio_r32(PLIC_PRIORITY(PLIC_SRC_SW(0))) != 5u ||
        mmio_r32(PLIC_THRESHOLD(PLIC_CTX_M0))   != 3u ||
        mmio_r32(PLIC_ENABLE(PLIC_CTX_M0))      != (1u << PLIC_SRC_SW(0))) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    uart_puts("  claim empty ");
    if (plic_claim(PLIC_CTX_M0) != 0u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    /* Priority equal to the threshold is masked: the pending bit is set but
     * mip.MEIP stays clear until the threshold drops. */
    uart_puts("  threshold   ");
    plic_set_threshold(PLIC_CTX_M0, 5u);
    plic_swirq_set(1u << 0);
    for (spin = 0; spin < 20u; spin++)
        ;
    if (!(plic_pending() & (1u << PLIC_SRC_SW(0)))) {
        uart_puts("FAILED (not pending)\n"); errors++;
    } else if (csr_read(mip) & (1u << 11)) {
        uart_puts("FAILED (not masked)\n"); errors++;
    } else {
        plic_set_threshold(PLIC_CTX_M0, 0u);
        for (spin = 0; spin < 20u; spin++)
            ;
        if (!(csr_read(mip) & (1u << 11))) {
            uart_puts("FAILED (still masked)\n"); errors++;
        } else uart_puts("ok\n");
    }

    uart_puts("  interrupt   ");
    n0 = plic_irq_count;
    csr_set(mie, 1u << 11);                /* MEIE */
    csr_set(mstatus, 1u << 3);             /* MIE  */
    for (spin = 0; spin < 4000u && plic_irq_count == n0; spin++)
        ;
    if (plic_irq_count == n0) {
        uart_puts("FAILED (never fired)\n"); errors++;
    } else if (last_plic_id != PLIC_SRC_SW(0)) {
        uart_puts("FAILED (wrong source ");
        uart_putdec(last_plic_id);
        uart_puts(")\n"); errors++;
    } else uart_puts("ok\n");

    /* The handler cleared the source, so no further interrupts may arrive. */
    uart_puts("  settles     ");
    n0 = plic_irq_count;
    for (spin = 0; spin < 20000u; spin++)
        ;
    if (plic_irq_count != n0) {
        uart_puts("FAILED (runaway)\n"); errors++;
    } else uart_puts("ok\n");

    /* IER.ETBEI raises the UART's level interrupt at once, since the
     * transmitter is idle; the handler masks it again. */
    uart_puts("  uart source ");
    uart_flush();
    plic_set_priority(PLIC_SRC_UART, 4u);
    plic_enable(PLIC_CTX_M0, PLIC_SRC_UART, 1);
    n0 = plic_irq_count;
    mmio_w8(UART_BASE + UART_IER, IER_THR_E);
    for (spin = 0; spin < 4000u && plic_irq_count == n0; spin++)
        ;
    if (plic_irq_count == n0) {
        uart_puts("FAILED (never fired)\n"); errors++;
    } else if (last_plic_id != PLIC_SRC_UART) {
        uart_puts("FAILED (source ");
        uart_putdec(last_plic_id);
        uart_puts(", expected ");
        uart_putdec(PLIC_SRC_UART);
        uart_puts(")\n"); errors++;
    } else uart_puts("ok\n");

    csr_clear(mstatus, 1u << 3);
    csr_clear(mie, 1u << 11);
    mmio_w8(UART_BASE + UART_IER, 0u);
    plic_disable_source(PLIC_SRC_UART);
    plic_disable_source(PLIC_SRC_SW(0));
    plic_swirq_set(0u);
    return errors;
}

/* ------------------------------------------------------------------------ */
/* RV32A atomics                                                             */
/* ------------------------------------------------------------------------ */

/*
 * Each AMO returns the old value and stores the result, LR/SC pair up, and a
 * second SC fails. Run once in boot RAM with the CPU tests and once in SDRAM
 * after the memory test, so an SDRAM-only failure points at the long-latency
 * path rather than the instructions. One hart, so this does not test mutual
 * exclusion.
 */
static int atomic_selftest_at(const char *where, volatile uint32_t *mem)
{
    int errors = 0;

    uart_puts("  ");
    uart_puts(where);

    mem[0] = 100u;
    if (amo_add(&mem[0], 23u) != 100u || mem[0] != 123u) errors++;

    mem[0] = 0xAAAA5555u;
    if (amo_swap(&mem[0], 0x12345678u) != 0xAAAA5555u ||
        mem[0] != 0x12345678u) errors++;

    /* Bitwise, and an unsigned compare across the sign boundary. */
    mem[0] = 0xFF00FF00u;
    if (amo_and(&mem[0], 0x0FF00FF0u) != 0xFF00FF00u ||
        mem[0] != 0x0F000F00u) errors++;
    mem[0] = 0xFF00FF00u;
    if (amo_or(&mem[0], 0x0FF00FF0u) != 0xFF00FF00u ||
        mem[0] != 0xFFF0FFF0u) errors++;
    mem[0] = 0xFFFFFFFFu;
    if (amo_maxu(&mem[0], 1u) != 0xFFFFFFFFu || mem[0] != 0xFFFFFFFFu) errors++;

    /* An AMO touches one word only. */
    mem[0] = 0x11111111u;
    mem[1] = 0x22222222u;
    mem[2] = 0x33333333u;
    (void)amo_add(&mem[1], 1u);
    if (mem[0] != 0x11111111u || mem[1] != 0x22222223u ||
        mem[2] != 0x33333333u) errors++;

    /* LR/SC succeeds once; a second SC has no reservation and must not store. */
    mem[0] = 0x600Du;
    if (lr_w(&mem[0]) != 0x600Du)            errors++;
    if (sc_w(&mem[0], 0xBEEFu) != 0u)        errors++;
    if (mem[0] != 0xBEEFu)                   errors++;
    if (sc_w(&mem[0], 0xDEADu) == 0u)        errors++;
    if (mem[0] != 0xBEEFu)                   errors++;

    mem[0] = 40u;
    if (!cas(&mem[0], 40u, 41u) || mem[0] != 41u) errors++;
    if (cas(&mem[0], 999u, 7u)  || mem[0] != 41u) errors++;

    mem[3] = 0u;
    lock_acquire(&mem[3]);
    if (mem[3] != 1u) errors++;
    lock_release(&mem[3]);
    if (mem[3] != 0u) errors++;

    /* Back-to-back AMOs: a sequencer that repeated one would miscount. */
    mem[0] = 0u;
    for (int i = 0; i < 64; i++)
        (void)amo_add(&mem[0], 1u);
    if (mem[0] != 64u) errors++;

    if (errors) {
        uart_puts(" FAILED (");
        uart_putdec((uint32_t)errors);
        uart_puts(")\n");
    } else uart_puts(" ok\n");

    return errors;
}

static int atomic_selftest(void)
{
    /* Above the BIOS's data, below its stack. */
    volatile uint32_t *bram = (volatile uint32_t *)(BOOT_BASE + 0x6000u);

    uart_puts("RV32A atomics\n");
    return atomic_selftest_at("boot ram   ", bram);
}

/* ------------------------------------------------------------------------ */
/* Bus                                                                       */
/* ------------------------------------------------------------------------ */

/* The interconnect's error responder must terminate an access to an unmapped
 * address; without it this read never completes. */
static void bus_error_check(void)
{
    volatile uint32_t v;

    uart_puts("Bus decode\n");
    uart_puts("  unmapped read at 0x");
    uart_puthex(UNMAPPED, 8);
    uart_puts(" ");
    v = mmio_r32(UNMAPPED);
    (void)v;
    uart_puts("answered, no hang: ok\n");
}

/* ------------------------------------------------------------------------ */
/* SDRAM tests. They overwrite SDRAM, so BOOT_ENTRY builds leave them out.   */
/* ------------------------------------------------------------------------ */
#ifndef BOOT_ENTRY

/* Run the memory test and report its cycle count, instruction count and CPI. */
static int sdram_test(void)
{
    uint32_t stride = MEMTEST_STRIDE;
    uint64_t c0, i0, dc, di;
    int errors;

    uart_puts("\nSDRAM test, ");
    uart_putdec(SDRAM_SIZE / (1024u * 1024u));
    uart_puts(" MB, stride ");
    uart_putdec(stride);
    uart_puts(" word(s)\n");

    c0 = read_cycle64();
    i0 = read_instret64();

    errors = memtest_run(stride);

    dc = read_cycle64()   - c0;
    di = read_instret64() - i0;

    uart_puts("\n  cycles       : ");
    put_u64(dc);
    uart_puts("\n  instructions : ");
    put_u64(di);
    if (di > 0) {
        /* CPI to two decimal places, in integer arithmetic. */
        uint32_t cpi100 = (uint32_t)((dc * 100u) / di);
        uart_puts("\n  CPI          : ");
        uart_putdec(cpi100 / 100u);
        uart_putc('.');
        if ((cpi100 % 100u) < 10u) uart_putc('0');
        uart_putdec(cpi100 % 100u);
    }
    uart_puts("\n");

    return errors;
}

static int atomic_selftest_sdram(void)
{
    volatile uint32_t *sdram = (volatile uint32_t *)SDRAM_SCRATCH;

    uart_puts("\nRV32A atomics over SDRAM\n");
    return atomic_selftest_at("sdram      ", sdram);
}

/*
 * Zifencei through both caches: store an instruction to SDRAM through the data
 * cache, execute fence.i, then call it through the instruction cache. The
 * rewrite of the same address checks that fence.i also invalidates the stale
 * line in the instruction cache. This is what a loader does before jumping to
 * a freshly loaded image.
 */
static int fence_i_selftest(void)
{
    volatile uint32_t *code = (volatile uint32_t *)(SDRAM_SCRATCH + 0x2000u);
    int (*fn)(void) = (int (*)(void))(SDRAM_SCRATCH + 0x2000u);
    int errors = 0;
    int got;

    uart_puts("Zifencei\n");

    /* addi a0, x0, imm ; jalr x0, 0(ra)  -  "return imm" */
    uart_puts("  write+call  ");
    code[0] = 0x00000513u | (0x111u << 20);
    code[1] = 0x00008067u;
    __asm__ volatile ("fence.i" ::: "memory");
    got = fn();
    if (got != 0x111) {
        uart_puts("FAILED (got 0x"); uart_puthex((uint32_t)got, 8); uart_puts(")\n");
        errors++;
    } else uart_puts("ok\n");

    uart_puts("  rewrite     ");
    code[0] = 0x00000513u | (0x222u << 20);
    __asm__ volatile ("fence.i" ::: "memory");
    got = fn();
    if (got != 0x222) {
        uart_puts("FAILED (got 0x"); uart_puthex((uint32_t)got, 8);
        uart_puts(", stale code)\n");
        errors++;
    } else uart_puts("ok\n");

    uart_puts("  again       ");
    code[0] = 0x00000513u | (0x333u << 20);
    __asm__ volatile ("fence.i" ::: "memory");
    got = fn();
    if (got != 0x333) {
        uart_puts("FAILED (got 0x"); uart_puthex((uint32_t)got, 8); uart_puts(")\n");
        errors++;
    } else uart_puts("ok\n");

    return errors;
}

/*
 * Sv32 translation on the hardware itself (tests/rv32i/16_mmu.S covers it in
 * simulation).
 *
 * A page table in SDRAM maps every device region and both SDRAM megapages
 * identically, plus an alias VA_ALIAS -> second SDRAM megapage, and leaves
 * VA_NOMAP unmapped. The data side is tested from M-mode with mstatus.MPRV
 * (MPP = S); fetch is not affected by MPRV, so the instruction side enters
 * S-mode. Devices must be mapped because, while MPRV is set, the trap handler's
 * own loads and stores are translated too.
 */
#define PT_BASE     (SDRAM_SCRATCH + 0x10000u)   /* 4 KB aligned */
#define VA_ALIAS    0x20000000u                  /* -> PA SDRAM_SCRATCH region */
#define VA_NOMAP    0x24000000u                  /* deliberately absent        */

/* V | R | W | X | A | D, a supervisor page */
#define PTE_FLAGS   0xCFu

/* An identity megapage for the 4 MiB region whose vpn1 is n. */
#define ID_PTE(n)   (((uint32_t)(n) << 20) | PTE_FLAGS)

static int mmu_selftest(void)
{
    volatile uint32_t *pt = (volatile uint32_t *)PT_BASE;
    volatile uint32_t *phys = (volatile uint32_t *)(SDRAM_SCRATCH + 0x100u);
    uint32_t satp_on = 0x80000000u | (PT_BASE >> 12);
    uint32_t saved_mie;
    uint32_t got, before;
    int errors = 0;
    int i;

    uart_puts("Sv32 translation\n");

    /* No interrupts while MPRV may be set. */
    saved_mie = csr_read(mstatus) & (1u << 3);
    csr_clear(mstatus, 1u << 3);

    for (i = 0; i < 1024; i++)
        pt[i] = 0;

    pt[0]   = ID_PTE(0);      /* boot RAM: code, stack, .data          */
    pt[8]   = ID_PTE(8);      /* CLINT                                 */
    pt[48]  = ID_PTE(48);     /* PLIC                                  */
    pt[64]  = ID_PTE(64);     /* UART                                  */
    pt[68]  = ID_PTE(68);     /* LEDs                                  */
    pt[72]  = ID_PTE(72);     /* SD card                               */
    pt[512] = ID_PTE(512);    /* SDRAM, first 4 MiB                    */
    pt[513] = ID_PTE(513);    /* SDRAM, second 4 MiB - holds the table */

    /* The alias: VA 0x2000_0000 onto the same physical 4 MiB as vpn1 513. */
    pt[128] = ID_PTE(513);

    csr_write(satp, satp_on);          /* also flushes both TLBs */

    /* --- data side, through MPRV --------------------------------------- */
    uart_puts("  alias       ");
    *phys = 0xABCD1234u;

    /* MPP = S, so an MPRV access translates as a supervisor access. */
    csr_clear(mstatus, 3u << 11);
    csr_set(mstatus, 1u << 11);

    /* MPRV is set for exactly one access, in assembly so that the compiler
     * cannot place another memory access inside the window. */
    __asm__ volatile (
        "csrs mstatus, %1\n"
        "lw   %0, 0(%2)\n"
        "csrc mstatus, %1\n"
        : "=&r" (got)
        : "r" (1u << 17), "r" (VA_ALIAS + 0x100u)
        : "memory");

    if (got != 0xABCD1234u) {
        uart_puts("FAILED (read 0x"); uart_puthex(got, 8);
        uart_puts(" through the alias)\n");
        errors++;
    } else uart_puts("ok\n");

    /* A store through the alias must land in the physical word. */
    uart_puts("  writeback   ");
    __asm__ volatile (
        "csrs mstatus, %0\n"
        "sw   %2, 0(%1)\n"
        "csrc mstatus, %0\n"
        :
        : "r" (1u << 17), "r" (VA_ALIAS + 0x100u), "r" (0x5A5A9999u)
        : "memory");
    if (*phys != 0x5A5A9999u) {
        uart_puts("FAILED (physical word holds 0x");
        uart_puthex(*phys, 8); uart_puts(")\n");
        errors++;
    } else uart_puts("ok\n");

    /* --- data page faults ---------------------------------------------- */
    uart_puts("  load fault  ");
    before = trap_count;
    __asm__ volatile (
        "csrs mstatus, %0\n"
        "lw   x0, 0(%1)\n"
        "csrc mstatus, %0\n"
        :
        : "r" (1u << 17), "r" (VA_NOMAP)
        : "memory");
    if (trap_count != before + 1u || last_cause != 13u) {
        uart_puts("FAILED (traps +"); uart_putdec(trap_count - before);
        uart_puts(", cause "); uart_putdec(last_cause); uart_puts(")\n");
        errors++;
    } else uart_puts("ok, cause 13\n");

    uart_puts("  store fault ");
    before = trap_count;
    __asm__ volatile (
        "csrs mstatus, %0\n"
        "sw   x0, 0(%1)\n"
        "csrc mstatus, %0\n"
        :
        : "r" (1u << 17), "r" (VA_NOMAP)
        : "memory");
    if (trap_count != before + 1u || last_cause != 15u) {
        uart_puts("FAILED (cause "); uart_putdec(last_cause); uart_puts(")\n");
        errors++;
    } else uart_puts("ok, cause 15\n");

    csr_clear(mstatus, 1u << 17);       /* MPRV off */

    /* --- instruction side, in S-mode ----------------------------------- */
    /*
     * mret into S-mode at label 0, set a marker, then ecall. The handler
     * resumes at label 1 (trap_resume) back in M-mode.
     */
    uart_puts("  s-mode fetch ");
    got = 0;
    __asm__ volatile (
        "la    t0, 1f\n"
        "sw    t0, 0(%1)\n"             /* trap_resume = after the ecall   */
        "la    t0, 0f\n"
        "csrw  mepc, t0\n"
        "li    t0, 3 << 11\n"
        "csrc  mstatus, t0\n"
        "li    t0, 1 << 11\n"
        "csrs  mstatus, t0\n"           /* MPP = S                         */
        "mret\n"
    "0:  li    %0, 0xA5\n"              /* running translated, in S-mode   */
        "ecall\n"
    "1:  nop\n"
        : "=r" (got)
        : "r" (&trap_resume)
        : "t0", "memory");

    if (got != 0xA5u) {
        uart_puts("FAILED (S-mode marker not set)\n");
        errors++;
    } else uart_puts("ok\n");

    /* mret into an unmapped page: instruction page fault (cause 12) with
     * mepc = the address that could not be fetched. */
    uart_puts("  fetch fault ");
    before = trap_count;
    __asm__ volatile (
        "la    t0, 1f\n"
        "sw    t0, 0(%0)\n"             /* trap_resume                     */
        "li    t0, %2\n"
        "csrw  mepc, t0\n"
        "li    t0, 3 << 11\n"
        "csrc  mstatus, t0\n"
        "li    t0, 1 << 11\n"
        "csrs  mstatus, t0\n"
        "mret\n"                        /* jump into an unmapped page      */
    "1:  nop\n"
        :
        : "r" (&trap_resume), "i" (0), "i" (VA_NOMAP)
        : "t0", "memory");

    if (trap_count != before + 1u || last_cause != 12u ||
        last_epc != VA_NOMAP) {
        uart_puts("FAILED (cause "); uart_putdec(last_cause);
        uart_puts(", epc 0x"); uart_puthex(last_epc, 8); uart_puts(")\n");
        errors++;
    } else uart_puts("ok, cause 12\n");

    /* --- back to bare mode --------------------------------------------- */
    csr_write(satp, 0);
    if (csr_read(satp) != 0) {
        uart_puts("  satp did not clear\n");
        errors++;
    }
    csr_set(mstatus, saved_mie);

    return errors;
}

#endif /* !BOOT_ENTRY */

/* ------------------------------------------------------------------------ */
/* SD card probe                                                             */
/* ------------------------------------------------------------------------ */

static void hexdump(const uint8_t *b, uint32_t n)
{
    uint32_t i, j;

    for (i = 0; i < n; i += 16) {
        uart_puts("    ");
        uart_puthex(i, 4);
        uart_puts("  ");
        for (j = 0; j < 16; j++) {
            if (i + j < n) uart_puthex(b[i + j], 2);
            else           uart_puts("  ");
            uart_putc(' ');
        }
        uart_puts(" |");
        for (j = 0; j < 16 && i + j < n; j++) {
            uint8_t c = b[i + j];
            uart_putc((c >= 0x20 && c < 0x7F) ? (char)c : '.');
        }
        uart_puts("|\n");
    }
}

/* Files longer than this are truncated when printed. */
static uint8_t file_buf[1024];

/* Print a file from the card: as text if it is printable, else as a hex dump
 * of its first 128 bytes. */
static void print_file(const char *name)
{
    fat32_dirent_t f;
    int32_t        n;
    int32_t        i;
    int            printable = 1;

    uart_puts("  ");
    uart_puts(name);
    uart_puts("  ");

    if (fat32_find(name, &f) != 0) {
        uart_puts("not found\n");
        return;
    }

    uart_putdec(f.size);
    uart_puts(" bytes, cluster ");
    uart_putdec(f.first_cluster);
    uart_puts("\n");

    n = fat32_read(&f, file_buf, sizeof(file_buf));
    if (n < 0) {
        uart_puts("    read failed: ");
        uart_puts(fat32_error_text());
        uart_puts("\n");
        return;
    }

    if (f.size > sizeof(file_buf))
        uart_puts("    (truncated to the BIOS buffer)\n");

    for (i = 0; i < n; i++) {
        uint8_t c = file_buf[i];
        if (c < 0x09 || (c > 0x0D && c < 0x20) || c >= 0x7F) {
            printable = 0;
            break;
        }
    }

    if (printable) {
        uart_puts("    ----------------------------------------\n    ");
        for (i = 0; i < n; i++) {
            uart_putc((char)file_buf[i]);
            if (file_buf[i] == '\n')
                uart_puts("    ");
        }
        uart_puts("\n    ----------------------------------------\n");
    } else {
        hexdump(file_buf, (uint32_t)((n > 128) ? 128 : n));
        if (n > 128) uart_puts("    ...\n");
    }
}

/*
 * Report what is on the card: initialise it, mount it, list the root directory
 * and print SD_PROBE_FILE. Read only and non-fatal - a missing or unreadable
 * card is reported and the boot carries on - so it is safe in every build.
 */
static void sd_probe(void)
{
    fat32_dirent_t  e;
    uint32_t        idx = 0;
    int             count = 0;
    int             ok = 0;
    int             i;

    uart_puts("\nSD card\n");

    uart_puts("  init        ");
    for (i = 0; i < SD_INIT_ATTEMPTS && !ok; i++)
        ok = (sd_init() == 0);
    /* One more initialisation follows the attempts. It only decides the
     * outcome if they all failed; after a success it re-initialises a card
     * that is already working. */
    if (sd_init() != 0 && !ok) {
        uart_puts("skipped: ");
        uart_puts(sd_error_text());
        uart_puts("  (status 0x");
        uart_puthex(sd_last_status(), 8);
        uart_puts(")\n");
        return;
    }
    uart_puts("ok, ");
    uart_puts(sd_is_hc() ? "high capacity (block addressed)"
                         : "standard capacity (byte addressed)");
    uart_puts("\n");

    uart_puts("  mount       ");
    if (fat32_mount() != 0) {
        uart_puts("failed: ");
        uart_puts(fat32_error_text());
        uart_puts("\n");
        return;
    }
    uart_puts("FAT32, volume \"");
    uart_puts(fat32_label());
    uart_puts("\"\n");

    uart_puts("  root directory\n");
    while (fat32_readdir(&idx, &e)) {
        uart_puts("    ");
        uart_puts(e.is_dir ? "<dir>  " : "       ");
        uart_puts(e.name);
        if (!e.is_dir) {
            uart_puts("   ");
            uart_putdec(e.size);
            uart_puts(" bytes");
        }
        uart_puts("\n");
        if (++count > 32) {
            uart_puts("    ...\n");
            break;
        }
    }
    if (count == 0)
        uart_puts("    (empty)\n");

    print_file(SD_PROBE_FILE);
}

/* ------------------------------------------------------------------------ */
/* Handoff to images preloaded by the simulator                              */
/* ------------------------------------------------------------------------ */
#ifdef BOOT_ENTRY
/*
 * Same handoff as an SD boot, with the addresses fixed at build time:
 * BOOT_ENTRY (the SBI firmware), BOOT_DTB and BOOT_NEXT_ADDR (the kernel).
 */
static void boot_preloaded(void)
{
    boot_plan_t plan = { 0 };

    plan.sbi_addr    = (uint32_t)BOOT_ENTRY;
    plan.dtb_addr    = (uint32_t)BOOT_DTB;
    plan.kernel_addr = (uint32_t)BOOT_NEXT_ADDR;
    plan.have_sbi    = 1;
    plan.have_dtb    = 1;
    plan.have_kernel = 1;
    boot_handoff(&plan);
}
#endif

/* ------------------------------------------------------------------------ */

/* Busy-wait, uncalibrated: about 10 cycles per iteration at 24 MHz, which is
 * accurate to within a factor of two. */
static void delay_roughly_ms(uint32_t ms)
{
    volatile uint32_t i;
    for (i = 0; i < ms * 2400u; i++)
        ;
}

/* Write a distinct duty value to every LED channel and read it back. */
static int led_selftest(void)
{
    unsigned ch;
    int bad = 0;

    uart_puts("\nLED device\n  readback   ");
    for (ch = 0; ch < LED_COUNT; ch++)
        led_set(ch, (uint8_t)(0x11u * (ch + 1u)));
    for (ch = 0; ch < LED_COUNT; ch++)
        if (led_get(ch) != (uint8_t)(0x11u * (ch + 1u)))
            bad = 1;
    for (ch = 0; ch < LED_COUNT; ch++)
        led_set(ch, 0);
    if (bad) {
        uart_puts("FAILED\n");
        return 1;
    }
    uart_puts("ok\n");
    return 0;
}

int main(void)
{
    int errors = 0;

    uart_init();

    if (STARTUP_DELAY_MS)
        delay_roughly_ms(STARTUP_DELAY_MS);

    banner();

    errors += cpu_selftest();
    errors += csr_selftest();
    errors += trap_selftest();
    errors += timer_selftest();
    errors += plic_selftest();
    errors += atomic_selftest();

    uart_puts("\nHello world from the RV32IMA core!\n\n");

    bus_error_check();

#ifdef BOOT_ENTRY
    uart_puts("\nSDRAM test skipped: this build carries a next-stage image\n");
#else
    errors += sdram_test();
    errors += atomic_selftest_sdram();
    errors += fence_i_selftest();
    errors += mmu_selftest();
#endif

    sd_probe();

#ifdef BOOT_FROM_SD
    if (errors == 0) {
        boot_plan_t plan;
        if (boot_load_from_sd(&plan) == 0)
            boot_handoff(&plan);
        uart_puts("\nNothing booted; carrying on\n");
    }
#endif

#ifdef BOOT_ENTRY
    if (errors == 0) {
        boot_preloaded();
    } else {
        uart_puts("\nNot handing off: ");
        uart_putdec((uint32_t)errors);
        uart_puts(" self test failure(s)\n");
    }
#endif

    /* LED demo: from here on the animation runs entirely in the timer
     * interrupt handler. */
    errors += led_selftest();

    uart_puts("\nLED demo: 5 channels dimmed from the timer interrupt\n");
    uart_puts("  timer      : 100 Hz\n");
    uart_puts("  pwm        : hardware, 8-bit, ~105 kHz\n");
    uart_puts("  led[0]     : hardware heartbeat, untouched by software\n");
    timer_period_us = 10000u;              /* 100 Hz */
    led_animate = 1;
    clint_next_tick(timer_period_us);
    csr_set(mstatus, 1u << 3);

    uart_puts("\n================================================\n");
    if (errors == 0) {
        uart_puts(" ALL TESTS PASSED\n");
    } else {
        uart_puts(" FAILURES: ");
        uart_putdec((uint32_t)errors);
        uart_puts("\n");
    }
    uart_puts("================================================\n");
    uart_puts(" traps taken : ");
    uart_putdec(trap_count);
    uart_puts("\n timer ticks : ");
    uart_putdec(timer_ticks);
    uart_puts("\n plic irqs   : ");
    uart_putdec(plic_irq_count);
    uart_puts("\n");
    uart_puts("================================================\n");
    uart_flush();

#ifndef SIMULATION
    /* On hardware, idle here while the timer interrupt animates the LEDs. The
     * core implements wfi as a no-op, so this is a busy loop in practice. */
    for (;;)
        __asm__ volatile ("wfi");
#endif

    return errors;
}
