/*
 * 11_plic - the Platform-Level Interrupt Controller.
 *
 * SoC only (`make run-soc TEST=11_plic`): the PLIC is a bus slave, so against
 * the bare core there is nothing at 0x0C00_0000.
 *
 * The interrupt sources used here are the GPIO block's SWIRQ bits, wired
 * straight to PLIC sources 2..5. They are level sensitive and software drives
 * them directly, which is what makes the interesting cases reachable: two
 * sources pending at once, a source still asserted after it has been claimed,
 * a claim with no completion.
 *
 * What each section is actually checking, since several of these look alike:
 *
 *   1  register storage, and the WARL/read-only edges
 *   2  source 0 does not exist
 *   3  the gateway latches a request, and priority 0 means disabled
 *   4  threshold masks, and it masks the *notification*, not the pending bit
 *   5  claim clears pending; the gateway stays shut until completion
 *   6  a repeat of 5 after a completion has already happened - this is the one
 *      that catches a completion register that latches instead of pulsing
 *   7  arbitration: higher priority first, lower ID breaks a tie
 *   8  the whole path through the core: mip.MEIP, a trap, claim, complete
 *
 * Reserved: s8 mcause, s9 trap count, s10 last claimed id, s11 scratch
 */

#include "test_macros.h"

#define PLIC_BASE       0x0C000000
#define PLIC_PRIO       (PLIC_BASE + 0x000000)      /* + 4*id     */
#define PLIC_PENDING    (PLIC_BASE + 0x001000)
#define PLIC_ENABLE     (PLIC_BASE + 0x002000)      /* + 0x80*ctx */
#define PLIC_THRESH     (PLIC_BASE + 0x200000)      /* + 0x1000*ctx */
#define PLIC_CLAIM      (PLIC_BASE + 0x200004)

#define GPIO_SWIRQ      0x11000020

#define SRC_A           2                   /* SWIRQ bit 0 */
#define SRC_B           3                   /* SWIRQ bit 1 */
#define SRC_C           4                   /* SWIRQ bit 2 */

#define MIE_MEIE        (1 << 11)
#define MSTATUS_MIE     (1 << 3)

/* Give a level change time to propagate through the gateway and the bus. */
.macro SETTLE
        nop
        nop
        nop
        nop
.endm

TEST_ENTRY

        li      sp, 0x3F00
        li      s9, 0                   # trap count
        li      s10, -1                 # last claimed id

        # ===============================================================
        # 1. Registers hold what is written, and refuse what they should.
        # ===============================================================
        li      t0, PLIC_PRIO
        li      t1, 5
        sw      t1, 4*SRC_A(t0)
        lw      t2, 4*SRC_A(t0)
        CHECK   t2, 5, 1

        # Priority is 3 bits wide here, so the top bits are not storage.
        li      t1, 0xFFFFFFFF
        sw      t1, 4*SRC_B(t0)
        lw      t2, 4*SRC_B(t0)
        CHECK   t2, 7, 2

        li      t0, PLIC_THRESH
        li      t1, 4
        sw      t1, 0(t0)
        lw      t2, 0(t0)
        CHECK   t2, 4, 3

        # Context 1 (S-mode) has its own threshold one 4 KB block further on,
        # and writing it must not disturb context 0's. The offset is past the
        # reach of a 12-bit immediate, so it needs its own base.
        li      t3, PLIC_THRESH + 0x1000
        li      t1, 2
        sw      t1, 0(t3)
        lw      t2, 0(t0)
        CHECK   t2, 4, 4
        lw      t2, 0(t3)
        CHECK   t2, 2, 5

        li      t0, PLIC_ENABLE
        li      t1, (1 << SRC_A) | (1 << SRC_B)
        sw      t1, 0(t0)
        lw      t2, 0(t0)
        CHECK   t2, ((1 << SRC_A) | (1 << SRC_B)), 6

        # Enables are per context, so context 1's are still clear.
        lw      t2, 0x80(t0)
        CHECK   t2, 0, 7

        # Pending is read-only: it is cleared by claiming, not by storing.
        li      t0, PLIC_PENDING
        li      t1, 0xFFFFFFFF
        sw      t1, 0(t0)
        lw      t2, 0(t0)
        CHECK   t2, 0, 8

        # ===============================================================
        # 2. Source 0 does not exist. Its priority is not storage and its
        #    pending bit is hardwired zero, so a claim can use ID 0 to mean
        #    "nothing pending" without ambiguity.
        # ===============================================================
        li      t0, PLIC_PRIO
        li      t1, 7
        sw      t1, 0(t0)
        lw      t2, 0(t0)
        CHECK   t2, 0, 9

        # ===============================================================
        # 3. A source asserting sets its pending bit. Enable and threshold do
        #    not gate that - they gate the notification, which is a separate
        #    thing and section 4 checks it.
        # ===============================================================
        li      t0, PLIC_THRESH
        sw      x0, 0(t0)               # threshold 0: allow everything
        li      t0, PLIC_PRIO
        li      t1, 3
        sw      t1, 4*SRC_A(t0)
        sw      x0, 4*SRC_B(t0)         # priority 0 disables source B
        sw      x0, 4*SRC_C(t0)

        li      t0, GPIO_SWIRQ
        li      t1, 0b011               # raise sources A and B together
        sw      t1, 0(t0)
        SETTLE

        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, ((1 << SRC_A) | (1 << SRC_B)), 10

        # B is pending but its priority is 0, so it can never be claimed and
        # can never notify. The claim must return A.
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_A, 11
        # Service A before completing it, as a handler does: a level source
        # still asserted at completion is re-forwarded (section 5, check 24).
        li      t3, GPIO_SWIRQ
        li      t1, 0b010               # A quiet, B still raised
        sw      t1, 0(t3)
        SETTLE
        sw      t2, 0(t0)               # complete A

        # B's pending bit survived A's claim: a claim clears one bit, not all.
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, (1 << SRC_B), 12

        # With nothing claimable left, a claim returns 0.
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, 0, 13

        # Clean up: give B a priority so it can be drained, then drop both.
        li      t0, PLIC_PRIO
        li      t1, 1
        sw      t1, 4*SRC_B(t0)
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_B, 14
        li      t3, GPIO_SWIRQ          # drop both lines, then complete B
        sw      x0, 0(t3)
        SETTLE
        sw      t2, 0(t0)
        SETTLE
        # Both gateways are released and both lines are low, so nothing is left.
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 15

        # ===============================================================
        # 4. Threshold masks by priority. The pending bit is untouched - the
        #    interrupt is simply not reported to this context, which is how one
        #    hart can be told to ignore low-priority devices while another
        #    still takes them.
        # ===============================================================
        li      t0, PLIC_PRIO
        li      t1, 3
        sw      t1, 4*SRC_A(t0)
        li      t0, PLIC_THRESH
        li      t1, 3                   # masks priority <= 3, so exactly A
        sw      t1, 0(t0)

        li      t0, GPIO_SWIRQ
        li      t1, 0b001
        sw      t1, 0(t0)
        SETTLE

        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, (1 << SRC_A), 16     # pending anyway

        csrr    t2, mip
        li      t3, (1 << 11)
        and     t2, t2, t3
        CHECK   t2, 0, 17               # but not reported: MEIP is clear

        # Threshold is strictly-less-than-priority to notify, so dropping it by
        # one is the boundary case that turns the notification on.
        li      t0, PLIC_THRESH
        li      t1, 2
        sw      t1, 0(t0)
        SETTLE
        csrr    t2, mip
        li      t3, (1 << 11)
        and     t2, t2, t3
        CHECK   t2, (1 << 11), 18

        # ===============================================================
        # 5. Claim and complete, with the source still asserted.
        #
        # This is the part that makes a level-triggered interrupt usable. The
        # claim clears pending, so MEIP drops and the handler can return even
        # though the device is still shouting. The gateway then refuses to
        # re-request until software says it is done.
        # ===============================================================
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_A, 19

        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 20               # cleared by the claim...

        csrr    t2, mip
        li      t3, (1 << 11)
        and     t2, t2, t3
        CHECK   t2, 0, 21               # ...so the notification went away

        # The line is still high. Without the gateway this would re-pend
        # immediately and the system would livelock.
        SETTLE
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 22

        # Toggling the line changes nothing either: the gateway is shut.
        li      t0, GPIO_SWIRQ
        sw      x0, 0(t0)
        SETTLE
        li      t1, 0b001
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 23

        # Completion reopens it, and the line is still high, so that is a new
        # request straight away. This is the level-sensitive rule from the
        # spec ("if the interrupt is level-triggered and the interrupt is still
        # asserted, a new interrupt request will be forwarded"): the device has
        # not been serviced, so it still needs to be.
        #
        # This check used to expect 0 - the gateway waited for the line to
        # fall first. Linux proved that wrong: a byte arriving at the UART
        # during the handler held its line through completion, the line could
        # only fall once the byte was read, the byte could only be read on an
        # interrupt, and the console never took another character.
        li      t0, PLIC_CLAIM
        li      t1, SRC_A
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, (1 << SRC_A), 24

        # Drop the line, raise it again: still pending - the re-forwarded
        # request has not been claimed, and the gateway is shut behind it.
        li      t0, GPIO_SWIRQ
        sw      x0, 0(t0)
        SETTLE
        li      t1, 0b001
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, (1 << SRC_A), 25

        # ===============================================================
        # 6. The same sequence again, now that source A has been completed
        #    once before.
        #
        # If completion were stored rather than pulsed, the stored ID would
        # still equal A and A's gateway would treat every later claim as
        # already completed. Check 27 would then find the line re-pended with
        # no completion in between. This is the only difference between this
        # section and section 5, and it is worth the duplication.
        # ===============================================================
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_A, 26

        li      t0, GPIO_SWIRQ
        sw      x0, 0(t0)
        SETTLE
        li      t1, 0b001
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 27               # no completion happened, so: shut

        li      t0, GPIO_SWIRQ          # service (line low), then complete
        sw      x0, 0(t0)
        SETTLE
        li      t0, PLIC_CLAIM
        li      t1, SRC_A
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 28

        # A completion is only honoured for a source that is *enabled in the
        # completing context*. That rule is what stops one context from
        # releasing another context's gateway, so it has to be checked with the
        # enable bit actually revoked - completing an ID that was simply never
        # raised proves nothing, because its gateway was already open.
        #
        # Sequence: claim C, revoke its enable, complete it (must be ignored),
        # restore the enable, then show the gateway is still shut.
        li      t0, PLIC_ENABLE
        li      t1, (1 << SRC_A) | (1 << SRC_B) | (1 << SRC_C)
        sw      t1, 0(t0)
        li      t0, PLIC_PRIO
        li      t1, 3
        sw      t1, 4*SRC_C(t0)

        li      t0, GPIO_SWIRQ
        li      t1, (1 << 2)            # raise C
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_C, 29

        li      t0, PLIC_ENABLE         # revoke C
        li      t1, (1 << SRC_A) | (1 << SRC_B)
        sw      t1, 0(t0)
        li      t0, PLIC_CLAIM
        li      t1, SRC_C
        sw      t1, 0(t0)               # ignored: C is not enabled here
        li      t0, PLIC_ENABLE         # restore
        li      t1, (1 << SRC_A) | (1 << SRC_B) | (1 << SRC_C)
        sw      t1, 0(t0)

        li      t0, GPIO_SWIRQ          # a full low/high cycle on the line
        sw      x0, 0(t0)
        SETTLE
        li      t1, (1 << 2)
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 30               # gateway still shut: the completion
                                        # really was ignored

        # Now complete it properly and the same cycle does re-request.
        li      t0, PLIC_CLAIM
        li      t1, SRC_C
        sw      t1, 0(t0)
        li      t0, GPIO_SWIRQ
        sw      x0, 0(t0)
        SETTLE
        li      t1, (1 << 2)
        sw      t1, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, (1 << SRC_C), 31

        # Drain C.
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_C, 32
        li      t3, GPIO_SWIRQ          # service (line low), then complete
        sw      x0, 0(t3)
        SETTLE
        sw      t2, 0(t0)
        SETTLE
        li      t0, PLIC_PENDING
        lw      t2, 0(t0)
        CHECK   t2, 0, 33

        # ===============================================================
        # 7. Arbitration.
        # ===============================================================
        li      t0, PLIC_ENABLE
        li      t1, (1 << SRC_A) | (1 << SRC_B) | (1 << SRC_C)
        sw      t1, 0(t0)
        li      t0, PLIC_THRESH
        sw      x0, 0(t0)

        # A = 2, B = 6, C = 4: strict ordering, so claims come back B, C, A.
        li      t0, PLIC_PRIO
        li      t1, 2
        sw      t1, 4*SRC_A(t0)
        li      t1, 6
        sw      t1, 4*SRC_B(t0)
        li      t1, 4
        sw      t1, 4*SRC_C(t0)

        li      t0, GPIO_SWIRQ
        li      t1, 0b111
        sw      t1, 0(t0)
        SETTLE

        # Claim all three before completing any. Completing a winner while
        # its line is still high re-forwards it (check 24), and it would win
        # again - the order is the point here, so the completions wait.
        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_B, 34
        lw      t2, 0(t0)
        CHECK   t2, SRC_C, 35
        lw      t2, 0(t0)
        CHECK   t2, SRC_A, 36

        # Service all three, then complete them.
        li      t3, GPIO_SWIRQ
        sw      x0, 0(t3)
        SETTLE
        li      t1, SRC_B
        sw      t1, 0(t0)
        li      t1, SRC_C
        sw      t1, 0(t0)
        li      t1, SRC_A
        sw      t1, 0(t0)
        SETTLE

        # Equal priorities: the lowest ID wins. Ties are not a corner case here,
        # they are what happens whenever a driver leaves everything at 1.
        li      t0, PLIC_PRIO
        li      t1, 4
        sw      t1, 4*SRC_A(t0)
        sw      t1, 4*SRC_B(t0)
        sw      t1, 4*SRC_C(t0)

        li      t0, GPIO_SWIRQ
        li      t1, 0b111
        sw      t1, 0(t0)
        SETTLE

        li      t0, PLIC_CLAIM
        lw      t2, 0(t0)
        CHECK   t2, SRC_A, 37
        lw      t2, 0(t0)
        CHECK   t2, SRC_B, 38
        lw      t2, 0(t0)
        CHECK   t2, SRC_C, 39

        li      t3, GPIO_SWIRQ
        sw      x0, 0(t3)
        SETTLE
        li      t1, SRC_A
        sw      t1, 0(t0)
        li      t1, SRC_B
        sw      t1, 0(t0)
        li      t1, SRC_C
        sw      t1, 0(t0)
        SETTLE

        # ===============================================================
        # 8. The whole path: a real trap driven by a device interrupt.
        #
        # Three gates in series, and all three have to be open: the PLIC's
        # own (priority > threshold), mie.MEIE, and mstatus.MIE.
        # ===============================================================
        la      t0, irq_handler
        csrw    mtvec, t0

        li      t0, MIE_MEIE
        csrs    mie, t0
        li      t0, MSTATUS_MIE
        csrs    mstatus, t0

        # Nothing pending yet, so nothing happens even fully enabled.
        SETTLE
        CHECK   s9, 0, 40

        li      t0, GPIO_SWIRQ
        li      t1, (1 << 1)            # source B only
        sw      t1, 0(t0)

        # The trap lands somewhere in the next few instructions.
        li      t4, 200
        li      t5, 0
irq_wait:
        addi    t5, t5, 1
        bnez    s9, irq_arrived
        blt     t5, t4, irq_wait
        CHECK   x0, 1, 41               # the interrupt never arrived
irq_arrived:
        CHECK   s8, 0x8000000B, 42      # mcause: interrupt + code 11 (MEI)
        CHECK   s10, SRC_B, 43          # and the handler claimed the right one

        # The handler dropped the line and completed, so this settles instead
        # of re-entering. A handler that claimed but never completed would
        # leave the gateway shut and also settle - which is why the count is
        # checked rather than just the absence of a hang.
        li      t4, 400
        li      t5, 0
settle_loop:
        addi    t5, t5, 1
        blt     t5, t4, settle_loop
        CHECK   s9, 1, 44

        # And the path still works a second time, which it would not if the
        # handler had left the gateway or the pending bit in a bad state.
        li      t0, GPIO_SWIRQ
        li      t1, (1 << 1)
        sw      t1, 0(t0)
        li      t4, 200
        li      t5, 0
irq_wait2:
        addi    t5, t5, 1
        li      t3, 2
        beq     s9, t3, irq_arrived2
        blt     t5, t4, irq_wait2
        CHECK   x0, 1, 45
irq_arrived2:
        CHECK   s10, SRC_B, 46

        li      t0, MSTATUS_MIE
        csrc    mstatus, t0

TEST_END

# =========================================================================
# External interrupt handler.
#
# The shape of this is the same for any PLIC system:
#
#   claim        -> which device, and stop it notifying
#   service it   -> here, drop the line the device is holding
#   complete     -> let that source interrupt again
#
# The order matters. Completing before the device is quiet re-arms the gateway
# against a line that is still high; it then waits for the fall, so the
# interrupt is not lost, just deferred until the device really is done.
# Quietening the source before completing, as here, is the ordering that leaves
# nothing outstanding.
# =========================================================================
        .align  2
irq_handler:
        csrr    s8, mcause
        addi    s9, s9, 1

        blt     s8, x0, plic_irq

        # An exception here means the test itself is broken; step over it.
        csrr    s11, mepc
        addi    s11, s11, 4
        csrw    mepc, s11
        mret

plic_irq:
        andi    s11, s8, 0x1F
        li      t0, 11
        bne     s11, t0, handler_done   # not external: nothing to do

        li      t0, PLIC_CLAIM
        lw      s10, 0(t0)              # claim
        beqz    s10, handler_done       # spurious: nothing to complete

        li      t0, GPIO_SWIRQ          # service: quiet the source
        sw      x0, 0(t0)

        li      t0, PLIC_CLAIM
        sw      s10, 0(t0)              # complete

handler_done:
        mret
