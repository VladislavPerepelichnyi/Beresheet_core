/*
 * Mini BIOS for the RV32IM SoC on Tang Nano 20K.
 *
 * Lives in the FPGA's block RAM at the reset vector, so it runs before anything
 * external is known to work. Job list, in order of what it can rely on:
 *
 *   1. bring up the UART, so everything after this is observable
 *   2. prove the CPU's own arithmetic, including RV32M
 *   3. prove the bus reports unmapped addresses instead of hanging
 *   4. test the 8 MB SDRAM
 *
 * Ordering is the point. If the UART were brought up after the memory test,
 * a memory fault would produce silence and no way to tell it apart from a dead
 * clock, a bad bitstream, or a mis-set baud rate.
 */
#include "soc.h"
#include "uart.h"
#include "memtest.h"
#include "csr.h"
#include "clint.h"
#include "leds.h"
#include "plic.h"
#include "atomic.h"
#include "sbi.h"
#include "trap.h"
#include "sdcard.h"
#include "fat32.h"
#include "boot.h"

/* Set by crt0.S from a linker symbol, so the banner can report the real size. */
extern char __bss_end[];
extern char __stack_top[];

static void banner(void)
{
    uart_puts("\n");
    uart_puts("================================================\n");
    uart_puts(" custom_riscv  RV32IM  Tang Nano 20K\n");
    uart_puts(" mini BIOS\n");
    uart_puts("================================================\n");
    /*
     * The clock matters to a reader for one specific reason: the BIOS transmits
     * at CPU_HZ/(16*BAUD), and OpenSBI then reprograms this same UART from
     * clock-frequency in the device tree. When the bitstream and the card's
     * device tree disagree, this banner is perfectly readable and every
     * character after it is noise - which reads as a kernel crash rather than
     * two files disagreeing about a number.
     */
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
    /*
     * Which build this is, said out loud.
     *
     * The boot mode is a compile-time flag, so from the outside a bitstream
     * gives no clue whether it will look for BOOT.TXT or run the LED demo. One
     * line here removes the guesswork - and it is the line you want when the
     * board appears to be running last week's firmware.
     */
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

/*
 * Print a 64-bit value in decimal. The counters are 64 bits, and by the end of
 * an 8 MB memory test the cycle count is well past what 32 bits holds, so this
 * is not decoration.
 */
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

/*
 * Check the CSRs before using them to measure anything. The counters must be
 * monotonic and instret must not run away from cycle - a machine cannot retire
 * more instructions than it has had clock edges.
 */
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

/*
 * Sanity-check the CPU before trusting it to test memory. If the multiplier is
 * wrong, a memory failure report is meaningless.
 */
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
    /* -1234 / 5678 truncates towards zero, and the remainder takes the sign of
     * the dividend. Division by zero must return all ones without trapping. */
    if ((a / b) != 0 || (a % b) != -1234 ||
        (b / 100) != 56 || (b % 100) != 78 ||
        (a / z) != -1 || (a % z) != a) {   /* Table 11: all ones, dividend */
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    return errors;
}

/*
 * Traps. The handler is already installed by crt0, so this only has to cause
 * faults and check that execution came back.
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
    /* An RV64-only load: a valid opcode with a funct3 this ISA does not have. */
    __asm__ volatile (".word 0x00033283");
    if (trap_count != before + 1u || last_cause != 2u ||
        last_tval != 0x00033283u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    /*
     * Written in assembly on purpose. A misaligned access through a C pointer
     * is undefined behaviour, so the compiler is entitled to assume it cannot
     * happen and emit whatever it likes - and with -Os it emitted nothing at
     * all, which showed up as a test that passed by not testing. When a test
     * needs one specific instruction, it has to say so.
     */
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
     * Repeatability. This is what OpenSBI's feature detection looks like: probe
     * an optional CSR, catch the illegal-instruction trap, move on. Ten in a
     * row, because one working trap proves much less than ten.
     *
     * pmpcfg0 rather than medeleg: medeleg became mandatory when S-mode landed,
     * and PMP is the thing still deliberately absent. OpenSBI probes both.
     */
    uart_puts("  probe x10   ");
    before = trap_count;
    for (int i = 0; i < 10; i++)
        __asm__ volatile ("csrr t0, 0x3A0" ::: "t0");   /* pmpcfg0: absent */
    if (trap_count != before + 10u || last_cause != 2u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    return errors;
}

/*
 * Timer interrupts from the CLINT.
 */
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

    /* `time` must be the same counter, per Zicntr. */
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
    clint_next_tick(100u);                 /* would fire in 100 us... */
    for (spin = 0; spin < 4000u; spin++)   /* ...but nothing is enabled yet */
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

    /*
     * mtip is a comparison, not a latch. If the handler had merely
     * acknowledged rather than moved mtimecmp forward, it would re-enter on
     * every cycle and this count would be enormous.
     */
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
 * RV32A atomics.
 *
 * Run twice: once in boot RAM and once in SDRAM. That is the whole point of
 * having this in the BIOS rather than only in the directed test. Boot RAM
 * answers in a couple of cycles; SDRAM takes a variable number, has a refresh
 * engine that can delay a transfer arbitrarily, and is on the far side of a
 * controller with its own busy handshake. A read-modify-write that only waits
 * for "a" response rather than the *right* response will pass against block RAM
 * and fail here.
 *
 * There is one hart, so none of this proves mutual exclusion. What it proves is
 * that each instruction does what it says: rd gets the pre-modify value, memory
 * gets the result, and an SC fails when and only when it should.
 */
static int atomic_selftest_at(const char *where, volatile uint32_t *mem)
{
    int errors = 0;

    uart_puts("  ");
    uart_puts(where);

    /* amoadd: rd is the old value, memory is the sum. */
    mem[0] = 100u;
    if (amo_add(&mem[0], 23u) != 100u || mem[0] != 123u) errors++;

    /* amoswap, including the rd == rs2 form a spinlock uses. */
    mem[0] = 0xAAAA5555u;
    if (amo_swap(&mem[0], 0x12345678u) != 0xAAAA5555u ||
        mem[0] != 0x12345678u) errors++;

    /* Bitwise, and the unsigned comparison across the sign boundary. */
    mem[0] = 0xFF00FF00u;
    if (amo_and(&mem[0], 0x0FF00FF0u) != 0xFF00FF00u ||
        mem[0] != 0x0F000F00u) errors++;
    mem[0] = 0xFF00FF00u;
    if (amo_or(&mem[0], 0x0FF00FF0u) != 0xFF00FF00u ||
        mem[0] != 0xFFF0FFF0u) errors++;
    mem[0] = 0xFFFFFFFFu;
    if (amo_maxu(&mem[0], 1u) != 0xFFFFFFFFu || mem[0] != 0xFFFFFFFFu) errors++;

    /* Neighbours must be untouched: an AMO is a word access. */
    mem[0] = 0x11111111u;
    mem[1] = 0x22222222u;
    mem[2] = 0x33333333u;
    (void)amo_add(&mem[1], 1u);
    if (mem[0] != 0x11111111u || mem[1] != 0x22222223u ||
        mem[2] != 0x33333333u) errors++;

    /* LR/SC: the pairing succeeds, and a second SC does not. */
    mem[0] = 0x600Du;
    if (lr_w(&mem[0]) != 0x600Du)            errors++;
    if (sc_w(&mem[0], 0xBEEFu) != 0u)        errors++;
    if (mem[0] != 0xBEEFu)                   errors++;
    if (sc_w(&mem[0], 0xDEADu) == 0u)        errors++;   /* no reservation */
    if (mem[0] != 0xBEEFu)                   errors++;   /* and no store */

    /* Compare-and-swap, both outcomes. */
    mem[0] = 40u;
    if (!cas(&mem[0], 40u, 41u) || mem[0] != 41u) errors++;
    if (cas(&mem[0], 999u, 7u)  || mem[0] != 41u) errors++;

    /* A spinlock, taken and released. Uncontended, but it must not deadlock. */
    mem[3] = 0u;
    lock_acquire(&mem[3]);
    if (mem[3] != 1u) errors++;
    lock_release(&mem[3]);
    if (mem[3] != 0u) errors++;

    /* A loop, so the sequencer runs many times back to back. A sequencer that
     * restarted once would double a count here and nowhere else. */
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

/*
 * The two halves run at different points in the boot, on purpose.
 *
 * Boot RAM goes with the other CPU self tests, because that is what it is
 * testing: the instructions. SDRAM waits until the memory test has proved the
 * memory itself, so that if the SDRAM half fails while the boot-RAM half passed,
 * the answer is unambiguous - the instructions are right and something about
 * long, variable latency is wrong. Running it first would let a dead SDRAM
 * present as an atomics bug.
 */
static int atomic_selftest(void)
{
    /* Well past the BIOS's own data and its stack. */
    volatile uint32_t *bram = (volatile uint32_t *)(BOOT_BASE + 0x6000u);

    uart_puts("RV32A atomics\n");
    return atomic_selftest_at("boot ram   ", bram);
}

static int atomic_selftest_sdram(void)
{
    volatile uint32_t *sdram = (volatile uint32_t *)SDRAM_SCRATCH;

    uart_puts("\nRV32A atomics over SDRAM\n");
    return atomic_selftest_at("sdram      ", sdram);
}

/*
 * PLIC: external interrupt routing.
 *
 * Two halves, and the second is the one that matters on hardware. The software
 * driven SWIRQ lines exercise the PLIC's own logic - priority, threshold, claim,
 * complete - with a source whose behaviour we control exactly. The UART half
 * then proves the thing no software-driven source can: that a real device's
 * interrupt pin is actually connected to the source number the driver believes
 * it is on.
 */
static int plic_selftest(void)
{
    int errors = 0;
    volatile uint32_t spin;
    uint32_t n0;

    uart_puts("PLIC\n");

    /* Registers first: if these are wrong nothing after them means anything. */
    uart_puts("  registers   ");
    plic_set_priority(PLIC_SRC_SW(0), 5u);
    plic_set_threshold(PLIC_CTX_M0, 3u);
    plic_enable(PLIC_CTX_M0, PLIC_SRC_SW(0), 1);
    if (mmio_r32(PLIC_PRIORITY(PLIC_SRC_SW(0))) != 5u ||
        mmio_r32(PLIC_THRESHOLD(PLIC_CTX_M0))   != 3u ||
        mmio_r32(PLIC_ENABLE(PLIC_CTX_M0))      != (1u << PLIC_SRC_SW(0))) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    /* Source 0 does not exist, so a claim can use 0 to mean "nothing". */
    uart_puts("  claim empty ");
    if (plic_claim(PLIC_CTX_M0) != 0u) {
        uart_puts("FAILED\n"); errors++;
    } else uart_puts("ok\n");

    /*
     * Threshold masks the notification, not the pending bit. Priority 5 against
     * threshold 5 is masked - the comparison is strictly greater.
     */
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

    /* Take it for real. Three gates: the PLIC's, mie.MEIE, mstatus.MIE. */
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

    /*
     * The handler claimed, quietened and completed, so this must settle. A
     * handler that claimed without completing would also settle - hence the
     * count check rather than just the absence of a hang.
     */
    uart_puts("  settles     ");
    n0 = plic_irq_count;
    for (spin = 0; spin < 20000u; spin++)
        ;
    if (plic_irq_count != n0) {
        uart_puts("FAILED (runaway)\n"); errors++;
    } else uart_puts("ok\n");

    /*
     * A real device. IER bit 1 asks the 16550 to interrupt while the transmit
     * holding register is empty, which it is, so the line goes high immediately
     * and stays there - a properly level-triggered device source. The handler
     * silences it by clearing IER.
     *
     * This is the check that would catch the UART being wired to the wrong PLIC
     * source, or to nothing at all.
     */
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

    /* Leave the PLIC quiet: the SDRAM test wants the bus to itself. */
    csr_clear(mstatus, 1u << 3);
    csr_clear(mie, 1u << 11);
    mmio_w8(UART_BASE + UART_IER, 0u);
    plic_disable_source(PLIC_SRC_UART);
    plic_disable_source(PLIC_SRC_SW(0));
    plic_swirq_set(0u);
    return errors;
}

/*
 * Read an address that belongs to no slave. The interconnect's error responder
 * must terminate it, which shows up as a zero read rather than a hang. Without
 * that responder this function never returns, so reaching the next line at all
 * is the result.
 */
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


/*
 * Hand control to a next-stage firmware.
 *
 * Two flavours, chosen at build time, because they answer different questions.
 *
 * BOOT_ENTRY alone is the plain SBI boot protocol: a0 = hart id, a1 = the
 * address of a flattened device tree, jump (do not call) to the entry point.
 * Everything the next stage needs to know about the machine it reads out of that
 * device tree - which is exactly why none of our base addresses had to be
 * conventional.
 *
 * BOOT_DYNAMIC additionally builds an OpenSBI fw_dynamic_info block and passes
 * it in a2. That is the interface a real first-stage loader uses, and here it is
 * needed for a specific reason:
 *
 *   OpenSBI picks one cold-boot hart by lottery, and only harts that support
 *   the *next* privilege mode may enter it (sbi_init.c: "Only the HART
 *   supporting privilege mode specified in the scratch->next_mode should be
 *   allowed to become the coldboot HART"). fw_payload defaults to next_mode =
 *   S, and this core has no S-mode, so no hart is eligible and the only hart
 *   there is waits forever on `coldboot_done`. That is not a bug in either
 *   piece - it is the machine honestly failing a requirement.
 *
 *   fw_dynamic lets the *loader* name the next mode. Asking for M-mode makes the
 *   lottery pass, so OpenSBI cold-boots, initialises, prints its banner, and
 *   hands off - which exercises everything except S-mode itself.
 *
 * Interrupts are disabled first, and mtvec is left alone rather than cleared:
 * the next stage installs its own before it enables anything, and until then
 * there must be no chance of vectoring into a handler belonging to firmware
 * that has just stopped existing.
 *
 * On hardware the loader will read the blobs off an SD card according to a boot
 * description file; in simulation the testbench preloads them into SDRAM. Both
 * end here.
 */
#ifdef BOOT_ENTRY

#ifdef BOOT_DYNAMIC
#define FW_DYNAMIC_MAGIC    0x4942534fu     /* "OSBI" */
#define FW_DYNAMIC_VERSION  2u
/*
 * Which privilege mode to ask OpenSBI to boot into.
 *
 * 3 = M, 1 = S, 0 = U. OpenSBI rejects M outright (sbi_domain.c: "We only allow
 * next mode to be S-mode or U-mode, so that we can protect M-mode context") and
 * requires misa to advertise whichever of S or U is asked for. So this core
 * cannot satisfy it today; the value is a build parameter because the moment a
 * mode below M exists, that is the only thing that has to change here.
 */
#ifndef BOOT_NEXT_MODE
#define BOOT_NEXT_MODE      3u      /* PRV_M */
#endif

/* Layout fixed by OpenSBI's include/sbi/fw_dynamic.h. Six longs, packed. */
struct fw_dynamic_info {
    unsigned long magic;
    unsigned long version;
    unsigned long next_addr;
    unsigned long next_mode;
    unsigned long options;
    unsigned long boot_hart;
};

static struct fw_dynamic_info dyninfo;

/*
 * Where OpenSBI hands control after it is done.
 *
 * This runs in whatever mode BOOT_NEXT_MODE asked for, and for S-mode that
 * changes what it is allowed to do. mstatus and mtvec are M-mode registers: a
 * payload that reads them faults, OpenSBI redirects the fault back into S-mode,
 * and the result is an endless loop of half-printed output. That was the first
 * version of this function, and it is exactly the mistake a real kernel port
 * makes once.
 *
 * So this reads sstatus, not mstatus, and it stops by spinning at a label the
 * simulation stops on rather than by clearing a vector it does not own.
 *
 * It also makes real SBI calls, which is the part worth having: an ECALL here
 * raises cause 9, OpenSBI catches it in M-mode, services it, and returns. That
 * round trip exercises the whole privilege mechanism end to end - delegation
 * left cause 9 with machine mode on purpose, and this is what that is for.
 */
static void __attribute__((noreturn)) sbi_payload(void)
{
    struct sbiret r;
    const char *msg = "printed by the payload, through OpenSBI's console\n";
    const char *p;

    uart_puts("\n================================================\n");
    uart_puts(" next stage running, handed over by OpenSBI\n");
    uart_puts(" sstatus : 0x");
    uart_puthex(csr_read(sstatus), 8);
    uart_puts("\n stvec   : 0x");
    uart_puthex(csr_read(stvec), 8);
    uart_puts("\n");

    /* Ask the firmware which SBI version it implements. */
    r = sbi_ecall(SBI_EXT_BASE, SBI_BASE_GET_SPEC, 0, 0, 0);
    uart_puts(" sbi spec: ");
    if (r.error) {
        uart_puts("call failed, error ");
        uart_putdec((uint32_t)(-r.error));
    } else {
        uart_putdec((uint32_t)((r.value >> 24) & 0x7F));
        uart_putc('.');
        uart_putdec((uint32_t)(r.value & 0xFFFFFF));
    }
    uart_puts("\n impl id : ");
    r = sbi_ecall(SBI_EXT_BASE, SBI_BASE_GET_IMPL, 0, 0, 0);
    uart_putdec((uint32_t)r.value);
    uart_puts("  (1 = OpenSBI)\n");

    /*
     * And print through the firmware rather than through our own UART driver.
     * If this text appears, an S-mode payload reached a device it never touched
     * directly, by asking machine mode to do it.
     */
    uart_puts(" via sbi : ");
    uart_flush();
    for (p = msg; *p; p++)
        (void)sbi_ecall(SBI_EXT_DBCN, SBI_DBCN_WRITE_BYTE,
                        (unsigned long)(unsigned char)*p, 0, 0);

    uart_puts("================================================\n");
    uart_flush();

    /*
     * Nothing left to do, and no way to stop from here: halting is an M-mode
     * act and this is S-mode. So spin at a label the simulation is told to stop
     * on - the address comes out of the ELF, so it cannot drift.
     */
    __asm__ volatile (".globl sbi_payload_done\nsbi_payload_done:");
    for (;;)
        ;
}

#endif /* BOOT_DYNAMIC */

static void boot_next_stage(void)
{
    uint32_t hartid = csr_read(mhartid);
    uint32_t arg2   = 0;

    csr_clear(mstatus, 1u << 3);           /* MIE off  */
    csr_write(mie, 0);                     /* and every source */
    led_animate = 0;

#ifdef BOOT_DYNAMIC
    dyninfo.magic     = FW_DYNAMIC_MAGIC;
    dyninfo.version   = FW_DYNAMIC_VERSION;
#ifdef BOOT_NEXT_ADDR
    /*
     * A real next stage - a Linux kernel - rather than the built-in payload.
     * OpenSBI does not care which it is: it reads next_addr out of this struct
     * and enters it in next_mode with a0 = hartid and a1 = the device tree,
     * which is exactly the protocol a kernel expects.
     */
    dyninfo.next_addr = (unsigned long)BOOT_NEXT_ADDR;
#else
    dyninfo.next_addr = (unsigned long)&sbi_payload;
#endif
    dyninfo.next_mode = BOOT_NEXT_MODE;
    dyninfo.options   = 0;
    dyninfo.boot_hart = hartid;
    arg2 = (uint32_t)&dyninfo;
#endif

    uart_puts("\nHanding off\n  entry  : 0x");
    uart_puthex((uint32_t)BOOT_ENTRY, 8);
    uart_puts("\n  dtb    : 0x");
    uart_puthex((uint32_t)BOOT_DTB, 8);
    uart_puts("\n  hartid : ");
    uart_putdec(hartid);
#ifdef BOOT_DYNAMIC
    uart_puts("\n  dyninfo: 0x");
    uart_puthex(arg2, 8);
    uart_puts("  (next mode ");
    uart_putdec(BOOT_NEXT_MODE);
    uart_puts(", next addr 0x");
    uart_puthex((uint32_t)dyninfo.next_addr, 8);
    uart_puts(")");
#endif
    uart_puts("\n\n");
    uart_flush();

    __asm__ volatile (
        "mv   a0, %0\n"
        "mv   a1, %1\n"
        "mv   a2, %2\n"
        "jr   %3\n"
        :
        : "r"(hartid), "r"((uint32_t)BOOT_DTB), "r"(arg2), "r"((uint32_t)BOOT_ENTRY)
        : "a0", "a1", "a2"
    );
    __builtin_unreachable();
}
#endif

/*
 * Rough busy-wait. Not calibrated: with every fetch going over the bus the
 * cycles-per-iteration depends on bus contention, so this is within a factor of
 * two and that is all it needs to be.
 */
static void delay_roughly_ms(uint32_t ms)
{
    volatile uint32_t i;
    /* ~10 cycles per iteration at 24 MHz, so 2400 iterations is about 1 ms */
    for (i = 0; i < ms * 2400u; i++)
        ;
}

/*
 * Zifencei, end to end.
 *
 * The assembly test can only prove FENCE.I terminates, because those tests run
 * from boot RAM and boot RAM is deliberately not cacheable. This is the other
 * half, and it needs two caches and a piece of memory that both of them will
 * hold: write an instruction into SDRAM through the *data* cache, then execute
 * it through the *instruction* cache.
 *
 * Without FENCE.I the two disagree in a specific and unhelpful way. The store
 * leaves the new instruction sitting dirty in the data cache, having never
 * reached SDRAM at all; the instruction cache then fetches the address and gets
 * whatever SDRAM happens to hold, which for a freshly powered board is not an
 * instruction. The second half of the test is the sharper one: by then the
 * instruction cache holds the *previous* version, so a machine with a working
 * write-back and a broken invalidate runs the old code and returns the old
 * answer - which looks exactly like a program that did not do anything.
 *
 * This is not a hypothetical. It is what an SD-card boot loader does: write a
 * kernel into SDRAM, then jump to it.
 */
static int fence_i_selftest(void)
{
    /* Well clear of anything a next-stage image occupies. */
    volatile uint32_t *code = (volatile uint32_t *)(SDRAM_SCRATCH + 0x2000u);
    int (*fn)(void) = (int (*)(void))(SDRAM_SCRATCH + 0x2000u);
    int errors = 0;
    int got;

    uart_puts("Zifencei\n");

    /*  addi a0, x0, imm   then   jalr x0, 0(x1)  - "return imm". */
    uart_puts("  write+call  ");
    code[0] = 0x00000513u | (0x111u << 20);
    code[1] = 0x00008067u;
    __asm__ volatile ("fence.i" ::: "memory");
    got = fn();
    if (got != 0x111) {
        uart_puts("FAILED (got 0x"); uart_puthex((uint32_t)got, 8); uart_puts(")\n");
        errors++;
    } else uart_puts("ok\n");

    /*
     * Same address, different instruction. This is the one that fails if the
     * instruction cache is written back but never invalidated.
     */
    uart_puts("  rewrite     ");   /* the sharp one: both caches must agree */
    code[0] = 0x00000513u | (0x222u << 20);
    __asm__ volatile ("fence.i" ::: "memory");
    got = fn();
    if (got != 0x222) {
        uart_puts("FAILED (got 0x"); uart_puthex((uint32_t)got, 8);
        uart_puts(", stale code)\n");
        errors++;
    } else uart_puts("ok\n");

    /* And once more, to catch an invalidate that only works the first time. */
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
 * Sv32 translation, on the board.
 *
 * 16_mmu.S covers this in simulation, and the MMU has a unit testbench for the
 * permission rules. Neither runs on hardware, and the difference has already
 * mattered twice this project: a signal that Verilator merged and Gowin left
 * undriven, and a register two always blocks both drove. So translation gets
 * exercised where it will actually be used.
 *
 * The method is the same as the simulation test - map a second virtual address
 * onto physical memory that is already reachable, and check the two are the
 * same memory - but the way in differs. MPRV is used for the data side, so an
 * M-mode load can translate without leaving M-mode; S-mode is entered properly
 * for the instruction side, because MPRV deliberately does not affect fetch.
 *
 * Every device region is mapped identically. That is not decoration: while MPRV
 * is set, *every* M-mode data access translates, including the trap handler's
 * own register saves and anything a timer interrupt touches. An unmapped CLINT
 * would fault inside the handler.
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

    /* Interrupts off for the whole test: a timer trap taken while MPRV is set
     * runs the handler under translation, and that is a complication with no
     * upside here. */
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

    /* --- the data side, through MPRV ------------------------------------ */
    uart_puts("  alias       ");
    *phys = 0xABCD1234u;

    /* MPP = S, so an MPRV access translates as a supervisor access. */
    csr_clear(mstatus, 3u << 11);
    csr_set(mstatus, 1u << 11);

    /* MPRV on for exactly one load. Nothing between the two CSR writes may
     * touch an unmapped address, which is why this is assembly. */
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

    /* And the other direction: a store through the alias must land in the
     * physical word. If the physical address were being dropped anywhere in
     * the pipeline, these would be two different places. */
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

    /* --- a data page fault ---------------------------------------------- */
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

    /* --- the instruction side, which needs real S-mode ------------------ */
    /*
     * MPRV does not affect fetch, by design, so this is the only way to get
     * instruction translation under test. Enter S-mode, execute one marker
     * instruction there, then ECALL; the handler returns to the label after it
     * with MPP forced back to M.
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

    /* A fetch that cannot be translated: cause 12, and mepc is the address
     * that could not be fetched. This is the path that needs the poisoned
     * IF/ID slot - there is no instruction to attribute the trap to. */
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


/*
 * SD card and FAT32.
 *
 * Read only, and deliberately non-fatal: an empty socket, an unformatted card
 * or a card that never leaves idle all report and carry on. This is a probe
 * that says what it found, not a boot requirement - the machine still boots
 * from block RAM with no card at all.
 */
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

/* One shared buffer. The BIOS has 32 KB of block RAM in total, so a file is
 * read in a chunk this size and anything longer is truncated with a note. */
static uint8_t file_buf[1024];

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

    /* Text gets printed, anything else gets dumped. Deciding by content rather
     * than by extension means a .bin full of ASCII still reads properly and a
     * .txt full of binary does not scribble over the terminal. */
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

static void sd_probe(void)
{
    fat32_dirent_t  e;
    uint32_t        idx = 0;
    int             count = 0;

    uart_puts("\nSD card\n");

    uart_puts("  init        ");
    // Custom : Try N times to init 
    const int N = 10;
    unsigned char not_error = 0;
    for(int i = 0 ; i < N ; i++) {
        //Try first time to init 
        if(!sd_init()) {
            not_error = 1;
            break ;
        }
    }
    // Try to init the SD card again if there is were not sucseed attemp
    if (sd_init() != 0 && !not_error) {
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

    print_file("CLAUDE.TXT");
}

int main(void)
{
    int errors = 0;
    uint32_t stride;

    uart_init();

    /*
     * Pause before saying anything. Programming the FPGA over JTAG re-opens the
     * FT2232 at the chip level, which resets the serial channel's line settings,
     * so a terminal attached before programming sees noise and one attached
     * after can miss the first lines. Starting a moment later means whatever is
     * watching catches the whole log either way.
     *
     * Zero in simulation, where the spin loop would cost more cycles than
     * everything else in the run put together.
     */
    if (STARTUP_DELAY_MS)
        delay_roughly_ms(STARTUP_DELAY_MS);

    banner();

    errors += cpu_selftest();
    errors += csr_selftest();
    errors += trap_selftest();
    errors += timer_selftest();
    errors += plic_selftest();
    errors += atomic_selftest();

    uart_puts("\nHello world from the RV32IM core!\n\n");

    bus_error_check();

    /*
     * Stride is chosen by the build: simulation cannot afford to touch two
     * million words, hardware can. MEMTEST_STRIDE comes from the Makefile.
     */
#ifdef BOOT_ENTRY
    /*
     * Skipped deliberately. The memory test writes patterns over the whole
     * region, and in this build the region already holds the firmware we are
     * about to jump to. The plain build tests the memory; this one carries the
     * image.
     */
    (void)stride;
    uart_puts("\nSDRAM test skipped: this build carries a next-stage image\n");
#else
    stride = MEMTEST_STRIDE;
    uart_puts("\nSDRAM test, ");
    uart_putdec(SDRAM_SIZE / (1024u * 1024u));
    uart_puts(" MB, stride ");
    uart_putdec(stride);
    uart_puts(" word(s)\n");

    {
        /*
         * Time the memory test with the counters. This is the first thing on
         * this machine that measures itself: cycles and retired instructions
         * come from the hardware, not from a simulator's bookkeeping, so the CPI
         * below is what the SoC really does over the Wishbone bus.
         */
        uint64_t c0 = read_cycle64();
        uint64_t i0 = read_instret64();

        errors += memtest_run(stride);

        {
            uint64_t dc = read_cycle64()   - c0;
            uint64_t di = read_instret64() - i0;

            uart_puts("\n  cycles       : ");
            put_u64(dc);
            uart_puts("\n  instructions : ");
            put_u64(di);
            if (di > 0) {
                /* CPI to two decimal places, without floating point */
                uint32_t cpi100 = (uint32_t)((dc * 100u) / di);
                uart_puts("\n  CPI          : ");
                uart_putdec(cpi100 / 100u);
                uart_putc('.');
                if ((cpi100 % 100u) < 10u) uart_putc('0');
                uart_putdec(cpi100 % 100u);
            }
            uart_puts("\n");
        }
    }

#endif  /* BOOT_ENTRY: no destructive memory test */

#ifdef BOOT_ENTRY
    /*
     * Skipped, for the same reason the memory test above is skipped - and the
     * comment that used to sit here claimed the opposite, which cost an hour.
     *
     * All three write to SDRAM_SCRATCH, which is SDRAM_BASE + 4 MiB =
     * 0x8040_0000. In a handoff build that is not scratch at all: RV32's
     * setup_vm needs a 4 MiB-aligned kernel, a 4 MB Image only fits at the base
     * of an 8 MB machine, so the next-stage firmware has nowhere to sit but
     * 0x8040_0000. The MMU test puts a page table at +0x10000 and the Zifencei
     * test writes instructions at +0x2000, both inside OpenSBI's text.
     *
     * The symptom was not a crash. OpenSBI's boot-hart lottery lives in .bss,
     * which a loaded .bin does not cover, so it read back whatever had been
     * written over it - non-zero - and hart 0 concluded it had lost a lottery
     * it was the only entrant in. It then sat in _wait_for_boot_hart retiring
     * millions of instructions and printing nothing at all.
     */
#else
    errors += atomic_selftest_sdram();
    errors += fence_i_selftest();
    errors += mmu_selftest();
#endif

    /* Read only, so it is safe in both builds and cannot disturb a loaded
     * image. Nothing below depends on it. */
    sd_probe();

#ifdef BOOT_FROM_SD
    /*
     * The LiteX-shaped path: everything about what to boot comes off the card,
     * so changing it is editing a text file rather than rebuilding this.
     */
    if (errors == 0) {
        boot_plan_t plan;
        if (boot_load_from_sd(&plan) == 0)
            boot_handoff(&plan);
        uart_puts("\nNothing booted; carrying on\n");
    }
#endif

#ifdef BOOT_ENTRY
    /*
     * Everything the next stage depends on has now been exercised: the CPU, the
     * CSRs, traps, the timer, the interrupt controller, the atomics, and every
     * word of the memory it is about to run from. Hand over.
     */
    if (errors == 0) {
        boot_next_stage();
    } else {
        uart_puts("\nNot handing off: ");
        uart_putdec((uint32_t)errors);
        uart_puts(" self test failure(s)\n");
    }
#endif

    /*
     * Hand the LEDs to the timer interrupt and leave it running. From here on
     * the CPU is idle in a loop and the animation is driven entirely by
     * interrupts - which is the whole point of the demonstration.
     */
    /*
     * Prove the LED device before handing it to the animation: write a distinct
     * value per channel and read it back. If the address or the decoder were
     * wrong this would fail here rather than looking like a dead LED.
     */
    uart_puts("\nLED device\n  readback   ");
    {
        unsigned ch;
        int bad = 0;
        for (ch = 0; ch < LED_COUNT; ch++)
            led_set(ch, (uint8_t)(0x11u * (ch + 1u)));
        for (ch = 0; ch < LED_COUNT; ch++)
            if (led_get(ch) != (uint8_t)(0x11u * (ch + 1u)))
                bad = 1;
        for (ch = 0; ch < LED_COUNT; ch++)
            led_set(ch, 0);
        if (bad) { uart_puts("FAILED\n"); errors++; }
        else       uart_puts("ok\n");
    }

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

    /*
     * On hardware, stay here so the LEDs keep breathing: every tick is an
     * interrupt, so the animation runs with the main loop doing nothing at all.
     * In simulation, fall through to the ebreak so the run terminates.
     */
#ifndef SIMULATION
    for (;;) {
        /*
         * WFI is a hint, and this core treats it as a no-op - it has no clock
         * gating to switch off, so there is nothing to save. It is still the
         * right instruction to write: it says "nothing to do until an interrupt"
         * to anyone reading the code, and on a core that does gate its clock the
         * same loop would idle properly. Every LED update happens in the
         * handler, so the loop really has nothing to do.
         */
        __asm__ volatile ("wfi");
    }
#endif

    /*
     * a0 carries the result out to the simulation testbench, which reads it at
     * the ebreak. On hardware the ebreak simply halts the pipeline and the
     * serial log is the record.
     */
    return errors;
}
