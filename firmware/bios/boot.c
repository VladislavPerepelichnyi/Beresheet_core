/*
 * BOOT.TXT loader and fw_dynamic handoff; the descriptor format is in boot.h.
 */
#include "boot.h"
#include "fat32.h"
#include "sdcard.h"
#include "uart.h"
#include "csr.h"
#include "soc.h"

/* Privilege mode OpenSBI enters the next stage in: 1 = S-mode. */
#ifndef BOOT_NEXT_MODE
#define BOOT_NEXT_MODE 1u
#endif

/* BOOT.TXT must fit in this buffer, with room for a terminating NUL. */
static char desc[2048];

static int is_space(char c) { return c == ' ' || c == '\t'; }

/* Next whitespace-separated token of a NUL-terminated line, terminated in
 * place. Returns 0 at the end of the line. */
static char *next_tok(char **p)
{
    char *s = *p;
    char *t;

    while (is_space(*s)) s++;
    if (*s == '\0') { *p = s; return 0; }

    t = s;
    while (*s && !is_space(*s)) s++;
    if (*s) *s++ = '\0';
    *p = s;
    return t;
}

static int parse_hex(const char *s, uint32_t *out)
{
    uint32_t v = 0;
    int n = 0;

    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    for (; *s; s++, n++) {
        char c = *s;
        v <<= 4;
        if      (c >= '0' && c <= '9') v |= (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
        else return -1;
    }
    if (n == 0) return -1;
    *out = v;
    return 0;
}

static int streq(const char *a, const char *b)
{
    while (*a && *b) { if (*a != *b) return 0; a++; b++; }
    return *a == *b;
}

/* Only SDRAM is a valid destination: a load into boot RAM would overwrite the
 * running BIOS. Also rejects ranges that wrap around. */
static int addr_ok(uint32_t addr, uint32_t size)
{
    uint32_t end = addr + size;

    if (addr < SDRAM_BASE || end > SDRAM_BASE + SDRAM_SIZE || end < addr)
        return 0;
    return 1;
}

int boot_load_from_sd(boot_plan_t *plan)
{
    fat32_dirent_t f;
    int32_t  n;
    char    *p;
    uint32_t line = 0;

    plan->have_sbi = plan->have_kernel = plan->have_dtb = 0;
    plan->loaded = plan->errors = 0;

    uart_puts("Boot from SD\n");

    uart_puts("  card        ");
    if (sd_init() != 0) {
        uart_puts(sd_error_text()); uart_puts("\n");
        return -1;
    }
    uart_puts("ok\n");

    uart_puts("  filesystem  ");
    if (fat32_mount() != 0) {
        uart_puts(fat32_error_text()); uart_puts("\n");
        return -1;
    }
    uart_puts("FAT32 \""); uart_puts(fat32_label()); uart_puts("\"\n");

    uart_puts("  " BOOT_DESC_FILE "    ");
    if (fat32_find(BOOT_DESC_FILE, &f) != 0) {
        uart_puts("not found - nothing to boot\n");
        return -1;
    }
    if (f.size >= sizeof(desc)) {
        uart_puts("too large\n");
        return -1;
    }
    n = fat32_read(&f, (uint8_t *)desc, sizeof(desc) - 1);
    if (n < 0) {
        uart_puts("read failed\n");
        return -1;
    }
    desc[n] = '\0';
    uart_putdec((uint32_t)n);
    uart_puts(" bytes\n");

    /* One entry per line: role, file, address. */
    p = desc;
    while (*p) {
        char *lp, *end, *role, *name, *addr_s;
        char *l = p;
        uint32_t addr;

        /* Cut this line out of the buffer, then work inside it. */
        while (*p && *p != '\n') p++;
        if (*p) *p++ = '\0';

        /* A file written on a PC ends its lines with CR LF. */
        end = l;
        while (*end) end++;
        if (end > l && end[-1] == '\r') end[-1] = '\0';

        line++;
        lp = l;

        role = next_tok(&lp);
        if (!role || role[0] == '#')
            continue;                   /* blank or comment */

        name   = next_tok(&lp);
        addr_s = next_tok(&lp);

        if (!name || !addr_s || parse_hex(addr_s, &addr) != 0) {
            uart_puts("    line "); uart_putdec(line);
            uart_puts(": expected 'role file address'\n");
            plan->errors++;
            continue;
        }

        if (fat32_find(name, &f) != 0) {
            uart_puts("    "); uart_puts(name);
            uart_puts(": not on the card\n");
            plan->errors++;
            continue;
        }

        if (!addr_ok(addr, f.size)) {
            uart_puts("    "); uart_puts(name);
            uart_puts(": 0x"); uart_puthex(addr, 8);
            uart_puts(" + "); uart_putdec(f.size);
            uart_puts(" is not inside SDRAM\n");
            plan->errors++;
            continue;
        }

        uart_puts("    "); uart_puts(role);
        uart_puts(" "); uart_puts(name);
        uart_puts(" -> 0x"); uart_puthex(addr, 8);
        uart_puts(" ("); uart_putdec(f.size); uart_puts(" bytes) ");

        n = fat32_read(&f, (uint8_t *)addr, f.size);
        if (n < 0 || (uint32_t)n != f.size) {
            uart_puts("SHORT READ\n");
            plan->errors++;
            continue;
        }
        /* Print the first word read back from the destination, as a visible
         * check of where the file landed (a device tree starts d00dfeed). */
        uart_puts("ok  first word 0x");
        uart_puthex(*(volatile uint32_t *)addr, 8);
        uart_puts("\n");
        plan->loaded++;

        if      (streq(role, "sbi"))    { plan->sbi_addr = addr;    plan->have_sbi = 1; }
        else if (streq(role, "kernel")) { plan->kernel_addr = addr; plan->have_kernel = 1; }
        else if (streq(role, "dtb"))    { plan->dtb_addr = addr;    plan->have_dtb = 1; }
        else if (streq(role, "load"))   { /* just resident */ }
        else {
            uart_puts("    unknown role \""); uart_puts(role);
            uart_puts("\", loaded but not used\n");
        }
    }

    /* The sbi entry is the jump target, so it is the one required role. */
    if (!plan->have_sbi) {
        uart_puts("  no 'sbi' entry - nowhere to jump\n");
        return -1;
    }
    if (plan->errors) {
        uart_puts("  "); uart_putdec((uint32_t)plan->errors);
        uart_puts(" entr(y/ies) failed\n");
        return -1;
    }
    return 0;
}

/*
 * OpenSBI's struct fw_dynamic_info (include/sbi/fw_dynamic.h), version 2. It is
 * static so that it survives the jump; the SBI reads it from boot RAM.
 */
#define FW_DYNAMIC_MAGIC    0x4942534fu    /* "OSBI" */
#define FW_DYNAMIC_VERSION  2u

static struct {
    unsigned long magic;
    unsigned long version;
    unsigned long next_addr;
    unsigned long next_mode;
    unsigned long options;
    unsigned long boot_hart;
} dyn;

void boot_handoff(const boot_plan_t *plan)
{
    uint32_t hartid = csr_read(mhartid);

    /* Interrupts off: the next stage installs its own handlers first. */
    csr_clear(mstatus, 1u << 3);
    csr_write(mie, 0);

    dyn.magic     = FW_DYNAMIC_MAGIC;
    dyn.version   = FW_DYNAMIC_VERSION;
    dyn.next_addr = plan->have_kernel ? plan->kernel_addr : 0;
    dyn.next_mode = BOOT_NEXT_MODE;
    dyn.options   = 0;
    dyn.boot_hart = hartid;

    uart_puts("\nHanding off\n  sbi    : 0x");
    uart_puthex(plan->sbi_addr, 8);
    uart_puts("\n  kernel : 0x");
    uart_puthex(plan->kernel_addr, 8);
    uart_puts(plan->have_kernel ? "\n  dtb    : 0x" : " (none)\n  dtb    : 0x");
    uart_puthex(plan->dtb_addr, 8);
    uart_puts(plan->have_dtb ? "\n" : " (none)\n");
    uart_puts("\n");
    uart_flush();

    __asm__ volatile (
        "mv   a0, %0\n"
        "mv   a1, %1\n"
        "mv   a2, %2\n"
        "jr   %3\n"
        :
        : "r" (hartid), "r" (plan->dtb_addr), "r" (&dyn), "r" (plan->sbi_addr)
        : "a0", "a1", "a2"
    );
    __builtin_unreachable();
}
