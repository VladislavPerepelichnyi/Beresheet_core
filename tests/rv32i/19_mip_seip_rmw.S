/*
 * 19_mip_seip_rmw - a read-modify-write of mip must not capture the PLIC's SEIP.
 *
 * SoC only (`make run-soc TEST=19_mip_seip_rmw`): needs the PLIC and GPIO.
 *
 * mip.SEIP reads as (software-writable bit) | (PLIC supervisor context). That
 * OR is right for the value returned in rd, and wrong as the starting point of
 * a CSRRS/CSRRC: the privileged spec has the modify act on the software bit
 * alone. The core used the OR, so any `csrs/csrc mip, <anything>` taken while
 * the supervisor context was asserted wrote the PLIC's 1 into the software
 * bit. SEIP then stayed set after the device was serviced.
 *
 * Linux found it. OpenSBI runs `csrs mip, STIP` / `csrc mip, STIP` on every
 * timer tick; the first time one landed while the UART's interrupt was pending
 * (inside serial8250_do_startup), SEIP latched, plic_handle_irq claimed 0 and
 * returned, and the hart took the same interrupt forever. In simulation it
 * looked like a silent hang just before `Run /init`.
 *
 * No program can aim a timer tick at that window on purpose, but it can make
 * the window permanent: hold a GPIO software interrupt asserted on PLIC
 * context 1, do the RMW, then release, claim and complete it.
 *
 * Everything runs in M-mode with interrupts disabled, so nothing traps; the
 * test is about the value of mip, not about delivery.
 */

#include "test_macros.h"

#define PLIC_BASE       0x0C000000
#define PLIC_PRIO       (PLIC_BASE + 0x000000)      /* + 4*id       */
#define PLIC_ENABLE1    (PLIC_BASE + 0x002080)      /* context 1    */
#define PLIC_THRESH1    (PLIC_BASE + 0x201000)
#define PLIC_CLAIM1     (PLIC_BASE + 0x201004)

#define GPIO_SWIRQ      0x11000020
#define SRC_A           2                   /* SWIRQ bit 0 */

#define MIP_SSIP        (1 << 1)
#define MIP_STIP        (1 << 5)
#define MIP_SEIP        (1 << 9)

.macro SETTLE
        nop
        nop
        nop
        nop
.endm

TEST_ENTRY

        li      sp, 0x3F00
        csrw    mie, x0
        csrw    mip, x0                 # software SEIP, STIP, SSIP all clear

        # --- PLIC: source A at priority 1, enabled for context 1 only -----
        li      t0, PLIC_PRIO + 4*SRC_A
        li      t1, 1
        sw      t1, 0(t0)
        li      t0, PLIC_ENABLE1
        li      t1, (1 << SRC_A)
        sw      t1, 0(t0)
        li      t0, PLIC_THRESH1
        sw      x0, 0(t0)

        # 1: nothing pending yet, SEIP reads 0
        csrr    t2, mip
        li      t3, MIP_SEIP
        and     t2, t2, t3
        CHECK   t2, 0, 1

        # --- Raise source A: the supervisor context asserts -------------
        li      t0, GPIO_SWIRQ
        li      t1, 1
        sw      t1, 0(t0)
        SETTLE

        # 2: SEIP now reads 1, from the PLIC
        csrr    t2, mip
        li      t3, MIP_SEIP
        and     t2, t2, t3
        CHECK   t2, MIP_SEIP, 2

        # --- The read-modify-writes OpenSBI does on every timer tick -----
        li      t1, MIP_STIP
        csrs    mip, t1
        csrc    mip, t1
        # ...and the immediate forms, which take the same path.
        csrsi   mip, MIP_SSIP
        csrci   mip, MIP_SSIP

        # 3: rd of a CSRRS still sees the OR (the spec wants that)
        csrrs   t2, mip, x0
        li      t3, MIP_SEIP
        and     t2, t2, t3
        CHECK   t2, MIP_SEIP, 3

        # --- Service the source: release, claim, complete ----------------
        li      t0, GPIO_SWIRQ
        sw      x0, 0(t0)
        SETTLE
        li      t0, PLIC_CLAIM1
        lw      t2, 0(t0)
        # 4: the claim names source A
        CHECK   t2, SRC_A, 4
        sw      t2, 0(t0)               # complete
        SETTLE

        # 5: THE BUG. Nothing is pending any more, so SEIP must read 0. With
        #    the RMW capturing the PLIC's bit it stays 1 here, forever.
        csrr    t2, mip
        li      t3, MIP_SEIP
        and     t2, t2, t3
        CHECK   t2, 0, 5

        # 6: and a claim now returns 0 - the state Linux spun in
        li      t0, PLIC_CLAIM1
        lw      t2, 0(t0)
        CHECK   t2, 0, 6

        # --- The software bit itself still works -------------------------
        li      t1, MIP_SEIP
        csrs    mip, t1
        csrr    t2, mip
        and     t2, t2, t1
        # 7: set by software, with no PLIC involvement
        CHECK   t2, MIP_SEIP, 7
        csrc    mip, t1
        csrr    t2, mip
        and     t2, t2, t1
        # 8: and cleared by software
        CHECK   t2, 0, 8

        # 9: STIP and SSIP were put back by their csrc's
        csrr    t2, mip
        andi    t2, t2, (MIP_STIP | MIP_SSIP)
        CHECK   t2, 0, 9

TEST_END
