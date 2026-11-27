/*
 * 03_jumps - JAL and JALR, link-register dependencies, computed targets.
 *
 * Points of interest for this pipeline:
 *   * the return address is not an ALU result, it travels to the writeback mux
 *     on its own path, so a JAL followed immediately by a use of ra is a RAW
 *     hazard on that path;
 *   * JALR takes its base from rs1, so a JALR whose rs1 was just written is a
 *     RAW hazard feeding the target adder rather than the ALU;
 *   * JALR must clear bit 0 of the computed target.
 */

#include "test_macros.h"

TEST_ENTRY

        li      sp, 0x3F00              # scratch stack, inside the 16K region

        # ---------------------------------------------------------------
        # JAL writes pc+4 into rd, and rd is consumed immediately
        # ---------------------------------------------------------------
        jal     ra, leaf_add            # ra = address of the next instruction
ret_point1:
        add     t0, ra, x0              # RAW on ra, one instruction after JAL
        la      t1, ret_point1
        CHECK_REG t0, t1, 1
        CHECK   a1, 30, 2               # leaf_add left its result in a1

        # JAL with rd = x0 is a plain goto and must not write anything
        li      ra, 0xABC
        jal     x0, skip1
        CHECK   x0, 1, 3
skip1:
        CHECK   ra, 0xABC, 4

        # ---------------------------------------------------------------
        # Nested calls, three deep, each level saving and restoring ra
        # ---------------------------------------------------------------
        li      a1, 1
        jal     ra, level1
        CHECK   a1, 8, 5                # 1 -> *2 -> *2 -> *2

        # ---------------------------------------------------------------
        # JALR through a register computed just beforehand
        # ---------------------------------------------------------------
        la      t2, jalr_target
        jalr    ra, 0(t2)               # rs1 written 1 instruction back
        CHECK   t3, 0x5555, 6

        # JALR with a non-zero offset; the target is base + imm.
        # Only single instructions sit between the landing points, so the
        # offsets stay independent of how the CHECK macro expands.
        la      t2, jalr_base
        jalr    x0, 8(t2)               # two instructions past jalr_base
        j       jalr_off_bad            # only reached if JALR did not jump
jalr_base:
        j       jalr_off_bad            # +0, must be skipped
        nop                             # +4, must be skipped
        j       jalr_off_ok             # +8, the landing point
jalr_off_bad:
        CHECK   x0, 1, 7
jalr_off_ok:

        # JALR must clear bit 0 of the computed address.
        # target+1 is odd; the core has to mask it back down.
        la      t2, jalr_masked
        addi    t2, t2, 1
        jalr    x0, 0(t2)
        CHECK   x0, 1, 10
jalr_masked:
        li      t4, 0x1234
        CHECK   t4, 0x1234, 11

        # ---------------------------------------------------------------
        # Jump table: JALR to an entry selected at run time
        # ---------------------------------------------------------------
        la      s0, jump_table
        li      s1, 2                   # pick entry 2
        slli    s2, s1, 2               # byte offset, RAW chain into the load
        add     s3, s0, s2
        lw      s4, 0(s3)               # target address, load-use into JALR
        jalr    x0, 0(s4)
        CHECK   x0, 1, 12
case0:  li      a2, 100
        j       jt_done
case1:  li      a2, 101
        j       jt_done
case2:  li      a2, 102
        j       jt_done
case3:  li      a2, 103
jt_done:
        CHECK   a2, 102, 13

        # ---------------------------------------------------------------
        # Call inside a loop. Every iteration mispredicts the JALR return
        # until the BTB learns it, then the loop branch competes for entries.
        # ---------------------------------------------------------------
        li      s5, 0                   # counter
        li      s6, 0                   # accumulator
        li      s7, 12                  # trip count
call_loop:
        addi    a1, s5, 1
        jal     ra, leaf_double         # a1 = a1 * 2
        add     s6, s6, a1              # RAW on the callee's result
        addi    s5, s5, 1
        blt     s5, s7, call_loop
        CHECK   s5, 12,  14
        CHECK   s6, 156, 15             # 2*(1+2+...+12) = 156

        # ---------------------------------------------------------------
        # AUIPC + JALR, the standard far-call pair
        # ---------------------------------------------------------------
        li      t5, 0
        call    leaf_mark               # assembler expands to auipc + jalr
        CHECK   t5, 0x7777, 16

TEST_END

# -------------------------------------------------------------------------
# Callees
# -------------------------------------------------------------------------
leaf_add:
        li      a1, 10
        li      a2, 20
        add     a1, a1, a2              # 30
        ret

leaf_double:
        add     a1, a1, a1
        ret

leaf_mark:
        li      t5, 0x7777
        ret

jalr_target:
        li      t3, 0x5555
        jr      ra                      # return through the saved ra

level1:
        addi    sp, sp, -4
        sw      ra, 0(sp)
        add     a1, a1, a1
        jal     ra, level2
        lw      ra, 0(sp)               # load-use straight into the return
        addi    sp, sp, 4
        ret

level2:
        addi    sp, sp, -4
        sw      ra, 0(sp)
        add     a1, a1, a1
        jal     ra, level3
        lw      ra, 0(sp)
        addi    sp, sp, 4
        ret

level3:
        add     a1, a1, a1
        ret

        .section .rodata
        .align  2
jump_table:
        .word   case0
        .word   case1
        .word   case2
        .word   case3
