// Structural invariants checked on every cycle of a bare-metal run.
//
// Ported from the old core testbench (tb_rv32i.v). Each one guards a property
// that the final architectural state cannot reveal, because the visible result
// is the same whether or not the property held:
//
//   RV32M stall       nothing retires while a multiply/divide holds stage 2
//                     (after the first stall cycle), or the instruction in
//                     Mem/Writeback would commit more than once.
//   Zicsr atomicity   the old value captured at the start of a multi-cycle
//                     CSR access does not move before the access commits, and
//                     there is exactly one commit per retired CSR instruction.
//   RV32A sequencing  one read phase and one write phase per retired AMO, and
//                     nothing retires during a read phase. A doubled amoadd
//                     changes the result; a doubled amoswap of a constant does
//                     not, which is why this is checked structurally.
//   Delegated traps   a trap taken into S-mode leaves mcause, mepc, mtval and
//                     mstatus.MPP/MPIE untouched. Software cannot check this:
//                     returning to M-mode to look takes a trap, which
//                     overwrites the very registers being checked.
//   Privilege         the privilege register never holds the reserved 2'b10.
//
// sample() is called once per cycle with the model settled, i.e. with the
// values the flops will capture at the next rising edge - the same instant the
// Verilog testbench sampled them.
#pragma once

#include <cstdarg>
#include <cstdint>
#include <cstdio>

#include "Vfast_sim_top.h"

class InvariantChecks {
public:
    uint64_t muldiv_cycles = 0;
    uint64_t csr_commits = 0, csr_retired = 0;
    uint64_t amo_reads = 0, amo_writes = 0, amo_retired = 0;
    bool     resv_held = false;

    unsigned muldiv_errors = 0, csr_errors = 0, amo_errors = 0, deleg_errors = 0;

    void sample(const Vfast_sim_top &t, uint64_t cycle) {
        const bool retire = t.retire_valid;
        const uint32_t insn = t.retire_instruction;

        // --- RV32M ---
        if (t.dbg_muldiv_stall) ++muldiv_cycles;
        if (t.dbg_muldiv_stall && muldiv_prev_ && retire)
            report(muldiv_errors, cycle, "instruction retired during an RV32M stall, pc=%08x",
                   t.retire_pc);
        muldiv_prev_ = t.dbg_muldiv_stall;

        // --- Zicsr. dbg_csr_old is a register, so it holds the captured value
        // from the cycle after dbg_csr_capture; hence the one-cycle delay. ---
        if (capture_d_) {
            csr_seen_ = t.dbg_csr_old;
            csr_active_ = !t.dbg_csr_commit;    // nothing to watch if it commits at once
        } else if (csr_active_) {
            if (t.dbg_csr_old != csr_seen_)
                report(csr_errors, cycle, "CSR capture moved mid-access: %08x -> %08x",
                       csr_seen_, t.dbg_csr_old);
            if (t.dbg_csr_commit) csr_active_ = false;
        }
        capture_d_ = t.dbg_csr_capture;
        if (t.dbg_csr_commit) ++csr_commits;
        if (retire && (insn & 0x7F) == 0x73 && ((insn >> 12) & 7) != 0) ++csr_retired;

        // --- RV32A ---
        if (t.dbg_amo_read && !amo_read_prev_) ++amo_reads;
        if (t.dbg_amo_write && !amo_write_prev_) ++amo_writes;
        if (retire && (insn & 0x7F) == 0x2F) {
            const unsigned f5 = insn >> 27;
            if (f5 != 0x02 && f5 != 0x03) ++amo_retired;    // not LR.W / SC.W
        }
        if (retire && t.dbg_amo_read)
            report(amo_errors, cycle, "instruction retired during an RMW read phase, pc=%08x",
                   t.retire_pc);
        amo_read_prev_ = t.dbg_amo_read;
        amo_write_prev_ = t.dbg_amo_write;
        resv_held = t.dbg_resv_valid;

        // --- Delegated traps: compare against the values from before the edge
        // on which the trap was taken. ---
        if (deleg_d_) {
            if (t.dbg_mcause != mcause_ || t.dbg_mepc != mepc_ || t.dbg_mtval != mtval_)
                report(deleg_errors, cycle, "a delegated trap wrote the machine trap registers");
            else if (t.dbg_mpp != mpp_ || t.dbg_mpie != mpie_)
                report(deleg_errors, cycle, "a delegated trap wrote mstatus.MPP or MPIE");
        }
        deleg_d_ = t.dbg_trap_deleg;
        mcause_ = t.dbg_mcause;
        mepc_ = t.dbg_mepc;
        mtval_ = t.dbg_mtval;
        mpp_ = t.dbg_mpp;
        mpie_ = t.dbg_mpie;

        if (t.dbg_priv == 2)
            report(deleg_errors, cycle, "privilege mode is the reserved value 2'b10");
    }

    bool ok() const {
        return !muldiv_errors && !csr_errors && !amo_errors && !deleg_errors &&
               csr_commits == csr_retired && amo_reads == amo_retired &&
               amo_writes == amo_retired;
    }

    void print_summary(FILE *f) const {
        if (muldiv_cycles)
            fprintf(f, "  RV32M stall     %llu cycles\n", (unsigned long long)muldiv_cycles);
        if (csr_commits || csr_retired) {
            fprintf(f, "  CSR accesses    %llu committed, %llu retired\n",
                    (unsigned long long)csr_commits, (unsigned long long)csr_retired);
            if (csr_commits != csr_retired)
                fprintf(f, "  INVARIANT FAIL  CSR commits do not match retirements\n");
        }
        if (amo_reads || amo_retired) {
            fprintf(f, "  RV32A atomics   %llu RMW read, %llu RMW write, %llu retired\n",
                    (unsigned long long)amo_reads, (unsigned long long)amo_writes,
                    (unsigned long long)amo_retired);
            if (amo_reads != amo_retired || amo_writes != amo_retired)
                fprintf(f, "  INVARIANT FAIL  RMW phases do not match retirements\n");
            if (resv_held)
                fprintf(f, "  note            a load reservation is still held\n");
        }
        if (muldiv_errors)
            fprintf(f, "  INVARIANT FAIL  %u retire-during-stall violations\n", muldiv_errors);
        if (csr_errors)
            fprintf(f, "  INVARIANT FAIL  %u CSR atomicity violations\n", csr_errors);
        if (amo_errors)
            fprintf(f, "  INVARIANT FAIL  %u RMW atomicity violations\n", amo_errors);
        if (deleg_errors)
            fprintf(f, "  INVARIANT FAIL  %u delegated-trap / privilege violations\n",
                    deleg_errors);
    }

private:
    // Prints the first five violations of each kind; counts all of them.
    __attribute__((format(printf, 3, 4)))
    static void report(unsigned &count, uint64_t cycle, const char *fmt, ...) {
        if (++count > 5) return;
        fprintf(stderr, "fast_sim: INVARIANT cycle %llu: ", (unsigned long long)cycle);
        va_list ap;
        va_start(ap, fmt);
        vfprintf(stderr, fmt, ap);
        va_end(ap);
        fputc('\n', stderr);
    }

    bool muldiv_prev_ = false;
    bool capture_d_ = false, csr_active_ = false;
    uint32_t csr_seen_ = 0;
    bool amo_read_prev_ = false, amo_write_prev_ = false;
    bool deleg_d_ = false;
    uint32_t mcause_ = 0, mepc_ = 0, mtval_ = 0;
    uint8_t mpp_ = 0;
    bool mpie_ = false;
};
