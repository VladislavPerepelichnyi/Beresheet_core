`include "definitions.vh"

// =============================================================================
// RV32I testbench.
//
// Runs a program image until the core halts, then applies the pass/fail
// convention used by the assembly tests in tests/rv32i:
//
//   EBREAK with a0 == 0    -> PASS
//   EBREAK with a0 != 0    -> FAIL, a0 holds the id of the failing check
//   illegal / misaligned   -> FAIL, trap_cause holds the mcause code
//   no halt before TIMEOUT -> FAIL
//
// Plusargs:
//   +hex=<file>      program image in $readmemh format (required)
//   +vcd=<file>      write a waveform dump
//   +timeout=<n>     cycle limit, default 200000
//   +trace           print every retired instruction
//   +expect_trap=<n> invert the verdict: the run passes only if the core traps
//                    with mcause == n (used by the negative tests)
// =============================================================================
module tb_rv32i;

    localparam MEM_BYTES = `INSTRUCTION_ROM_SIZE;

    reg clk = 1'b0;
    reg rst = 1'b1;

    wire        halted, trap_error, ebreak_halt;
    wire [3:0]  trap_cause;
    wire        retire_valid;
    wire [31:0] retire_pc, retire_instruction;
    wire [31:0] stage2_pc, stage2_instruction;
    wire        muldiv_stall;
    wire        csr_capture, csr_commit;
    wire [31:0] csr_old_dbg;
    reg         csr_active = 1'b0;
    reg         csr_capture_d = 1'b0;
    reg  [31:0] csr_seen = 32'd0;
    integer     csr_ops = 0;
    integer     csr_retired = 0;
    integer     csr_invariant_errors = 0;

    reg  [`REG_ADDR_WIDTH-1:0] dbg_reg_addr = 5'd10;   // a0
    wire [31:0]                dbg_reg_data;

    integer                 timeout = 200000;
    integer                 cycles  = 0;
    integer                 retired = 0;
    integer                 expect_trap = -1;
    integer                 muldiv_cycles = 0;
    integer                 invariant_errors = 0;
    reg                     muldiv_stall_prev = 1'b0;
    // RV32A observation. An atomic is a multi-cycle read-modify-write whose
    // intermediate state never reaches a register, so the only way to see that
    // it happens exactly once is to watch the sequencer.
    wire        amo_read, amo_write, resv_valid;
    reg         amo_read_prev  = 1'b0;
    reg         amo_write_prev = 1'b0;
    integer     amo_starts  = 0;
    integer     amo_writes  = 0;
    integer     amo_retires = 0;
    integer     amo_invariant_errors = 0;

    // ------------------------------------------------------------------------
    // Delegated-trap non-interference.
    //
    // When a trap is delegated to S-mode the spec is explicit that "the mcause,
    // mepc, and mtval registers and the MPP and MPIE fields of mstatus are not
    // written". Writing them anyway would quietly corrupt an outer M-mode
    // context that is still live - firmware would return to the wrong place,
    // and only under the exact interleaving that produced it.
    //
    // Software cannot check this, and the reason is instructive: getting back to
    // M-mode to look at mcause requires taking a trap, which overwrites mcause.
    // The observation destroys the thing being observed. So the testbench
    // watches the registers directly instead.
    // ------------------------------------------------------------------------
    reg         deleg_d = 1'b0;
    reg  [31:0] m_cause_before, m_epc_before, m_tval_before;
    reg  [1:0]  m_mpp_before;
    reg         m_mpie_before;
    integer     deleg_invariant_errors = 0;

    reg                     do_trace;
    reg [8*256-1:0]         hex_file;
    reg [8*256-1:0]         vcd_file;

    // ------------------------------------------------------------------------
    // Device under test. The image name is passed through a plusarg, so it is
    // forced into the memory arrays after elaboration rather than by parameter.
    // ------------------------------------------------------------------------
    soc_sim #(
        .MEM_BYTES (MEM_BYTES),
        .INIT_FILE ("")
    ) dut (
        .clk                (clk),
        .rst                (rst),
        .halted             (halted),
        .trap_error         (trap_error),
        .ebreak_halt        (ebreak_halt),
        .trap_cause         (trap_cause),
        .dbg_reg_addr       (dbg_reg_addr),
        .dbg_reg_data       (dbg_reg_data),
        .retire_valid       (retire_valid),
        .retire_pc          (retire_pc),
        .retire_instruction (retire_instruction),
        .dbg_stage2_pc          (stage2_pc),
        .dbg_stage2_instruction (stage2_instruction),
        .dbg_muldiv_stall       (muldiv_stall),
        .dbg_csr_capture        (csr_capture),
        .dbg_csr_commit         (csr_commit),
        .dbg_csr_old            (csr_old_dbg),
        .dbg_amo_read           (amo_read),
        .dbg_amo_write          (amo_write),
        .dbg_resv_valid         (resv_valid)
    );

    always #5 clk = ~clk;

    // ------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("hex=%s", hex_file)) begin
            $display("TB-ERROR: no program image. Pass +hex=<file>.");
            $finish;
        end

        $readmemh(hex_file, dut.irom.mem);
        $readmemh(hex_file, dut.dram.mem);

        if (!$value$plusargs("timeout=%d", timeout))
            timeout = 200000;

        do_trace = $test$plusargs("trace");

        if (!$value$plusargs("expect_trap=%d", expect_trap))
            expect_trap = -1;

        if ($value$plusargs("vcd=%s", vcd_file)) begin
            $dumpfile(vcd_file);
            $dumpvars(0, tb_rv32i);
        end

        $display("================================================================");
        $display(" RV32I core simulation");
        $display("   image   : %0s", hex_file);
        $display("   timeout : %0d cycles", timeout);
        if (expect_trap >= 0)
            $display("   expect  : trap with mcause = %0d", expect_trap);
        $display("================================================================");

        repeat (4) @(posedge clk);
        rst = 1'b0;
    end

    // ------------------------------------------------------------------------
    // Instruction trace and retirement counter
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst) begin
            cycles = cycles + 1;
            if (retire_valid) begin
                retired = retired + 1;
                if (do_trace)
                    $display("[%6d] pc=%08h  instr=%08h", cycles, retire_pc,
                             retire_instruction);
            end
            if (muldiv_stall) muldiv_cycles = muldiv_cycles + 1;

            // ------------------------------------------------------------
            // Structural invariant on the RV32M stall.
            //
            // While a multiply or divide is held in Decode/Execute, the
            // control unit bubbles Mem/Writeback rather than freezing it, so
            // the older instruction there commits exactly once. Holding it
            // instead would re-commit it every cycle: the program result is
            // unchanged because a repeated store or register write is
            // idempotent, but the retirement count is wrong and a repeated
            // write to an MMIO device would not be. Nothing about the program
            // state can reveal that, so check the structure directly.
            //
            // The first stall cycle is exempt: Mem/Writeback legitimately
            // still holds the instruction latched before the stall began.
            // ------------------------------------------------------------
            if (muldiv_stall && muldiv_stall_prev && retire_valid) begin
                invariant_errors = invariant_errors + 1;
                if (invariant_errors <= 5)
                    $display("TB-ERROR: instruction retired during an RV32M stall at cycle %0d, pc=%08h",
                             cycles, retire_pc);
            end

            // ------------------------------------------------------------
            // Zicsr atomicity invariant.
            //
            // A CSR access captures the old value on its first cycle and stores
            // the modified value on its last. The spec requires the whole thing
            // to be atomic, so the value handed to rd and the value the modify
            // was computed from must be the same snapshot.
            //
            // Nothing about the final register state can reveal a violation. If
            // the capture were re-read every cycle, rd and the stored value
            // would still agree with each other - they would simply both come
            // from a later cycle. On a static CSR that is indistinguishable, and
            // on a counter it differs only by however long the pipeline happened
            // to hold, which no test can pin down. So check the structure: once
            // captured, the held value must not move until it is committed.
            //
            // csr_capture is delayed by one cycle before sampling, because
            // csr_old is a register - it only holds the captured value from the
            // cycle after the capture.
            // ------------------------------------------------------------
            if (csr_capture_d) begin
                csr_seen   <= csr_old_dbg;
                // Nothing to watch if the access commits immediately
                csr_active <= ~csr_commit;
            end
            else if (csr_active) begin
                if (csr_old_dbg !== csr_seen) begin
                    csr_invariant_errors = csr_invariant_errors + 1;
                    if (csr_invariant_errors <= 5)
                        $display("TB-ERROR: CSR capture moved mid-access at cycle %0d: %08h -> %08h",
                                 cycles, csr_seen, csr_old_dbg);
                end
                if (csr_commit) csr_active <= 1'b0;
            end
            csr_capture_d <= csr_capture;
            if (csr_commit) csr_ops = csr_ops + 1;

            // Exactly one commit per CSR instruction. A commit is a CSR write,
            // and the spec allows writes to have side effects, so doing it twice
            // is wrong even when the value is identical - and for mcycle a
            // repeated write freezes the counter for as long as the repeat
            // lasts. Counting both sides is the cheapest way to notice.
            if (retire_valid && retire_instruction[6:0] == 7'b1110011 &&
                retire_instruction[14:12] != 3'b000)
                csr_retired = csr_retired + 1;

            // ------------------------------------------------------------
            // RV32A structural invariants.
            //
            // The sequencer returns to its read phase as soon as the write
            // completes, and that is only safe because completion is exactly
            // the cycle mem_stall falls - so EX/MEM advances or flushes on the
            // same edge and the next cycle holds a different instruction. If
            // that coupling ever breaks, the same AMO runs twice: it would read
            // the value it just wrote and apply the operation again, so an
            // amoadd would add twice. The program result is wrong but nothing
            // in the final state says why, and with an idempotent operation -
            // amoand of a mask, amoswap of a constant - it would not be wrong
            // at all, just doubled on the bus.
            //
            //   1. one read phase per retired AMO, counted by rising edges
            //   2. one write phase per read phase - a modify that never reaches
            //      memory is the other half of the same failure
            //   3. nothing retires while a read phase is in progress, which is
            //      what would happen if mem_stall released between the halves
            // ------------------------------------------------------------
            if (amo_read  && !amo_read_prev)  amo_starts = amo_starts + 1;
            if (amo_write && !amo_write_prev) amo_writes = amo_writes + 1;

            if (retire_valid && retire_instruction[6:0] == `OPC_AMO &&
                retire_instruction[31:27] != `F5_LR &&
                retire_instruction[31:27] != `F5_SC)
                amo_retires = amo_retires + 1;

            if (retire_valid && amo_read) begin
                amo_invariant_errors = amo_invariant_errors + 1;
                if (amo_invariant_errors <= 5)
                    $display("TB-ERROR: instruction retired during an RMW read phase at cycle %0d, pc=%08h",
                             cycles, retire_pc);
            end

            // ------------------------------------------------------------
            // Delegated traps must leave the machine trap registers alone.
            // ------------------------------------------------------------
            if (deleg_d) begin
                if (dut.core.decode_exec_inst.csr_inst.mcause !== m_cause_before ||
                    dut.core.decode_exec_inst.csr_inst.mepc   !== m_epc_before   ||
                    dut.core.decode_exec_inst.csr_inst.mtval  !== m_tval_before) begin
                    deleg_invariant_errors = deleg_invariant_errors + 1;
                    if (deleg_invariant_errors <= 5)
                        $display("TB-ERROR: a delegated trap wrote the machine trap registers at cycle %0d",
                                 cycles);
                end
                else if (dut.core.decode_exec_inst.csr_inst.mstatus_mpp  !== m_mpp_before ||
                         dut.core.decode_exec_inst.csr_inst.mstatus_mpie !== m_mpie_before) begin
                    deleg_invariant_errors = deleg_invariant_errors + 1;
                    if (deleg_invariant_errors <= 5)
                        $display("TB-ERROR: a delegated trap wrote mstatus.MPP or MPIE at cycle %0d",
                                 cycles);
                end
            end
            deleg_d        <= dut.core.trap_take & dut.core.trap_to_s;
            m_cause_before <= dut.core.decode_exec_inst.csr_inst.mcause;
            m_epc_before   <= dut.core.decode_exec_inst.csr_inst.mepc;
            m_tval_before  <= dut.core.decode_exec_inst.csr_inst.mtval;
            m_mpp_before   <= dut.core.decode_exec_inst.csr_inst.mstatus_mpp;
            m_mpie_before  <= dut.core.decode_exec_inst.csr_inst.mstatus_mpie;

            // The privilege register must never hold the reserved encoding 10.
            if (dut.core.decode_exec_inst.csr_inst.priv === 2'b10) begin
                deleg_invariant_errors = deleg_invariant_errors + 1;
                if (deleg_invariant_errors <= 5)
                    $display("TB-ERROR: privilege mode is the reserved value 10 at cycle %0d",
                             cycles);
            end

            amo_read_prev  <= amo_read;
            amo_write_prev <= amo_write;

            muldiv_stall_prev <= muldiv_stall;
        end
    end

    // ------------------------------------------------------------------------
    // End of test
    // ------------------------------------------------------------------------
    task report_and_exit(input pass);
        begin
            $display("----------------------------------------------------------------");
            $display(" cycles retired : %0d", cycles);
            $display(" instructions   : %0d", retired);
            if (retired > 0)
                $display(" CPI            : %0d.%02d", cycles / retired,
                         ((cycles * 100) / retired) % 100);
            if (muldiv_cycles > 0)
                $display(" RV32M stall    : %0d cycles (%0d%% of run)",
                         muldiv_cycles, (muldiv_cycles * 100) / cycles);
            if (csr_ops > 0 || csr_retired > 0) begin
                $display(" CSR accesses   : %0d committed, %0d retired",
                         csr_ops, csr_retired);
                if (csr_ops != csr_retired)
                    $display(" INVARIANT FAIL : CSR commits do not match retirements");
            end
            if (amo_starts > 0 || amo_retires > 0) begin
                $display(" RV32A atomics  : %0d RMW read, %0d RMW write, %0d retired",
                         amo_starts, amo_writes, amo_retires);
                if (amo_starts != amo_retires || amo_writes != amo_retires)
                    $display(" INVARIANT FAIL : RMW phases do not match retirements");
                // A reservation still held at exit is not an error, but it does
                // mean an LR went unpaired - usually a test that returned early.
                if (resv_valid)
                    $display(" note           : a load reservation is still held");
            end
            if (invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d retire-during-stall violations",
                         invariant_errors);
            if (csr_invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d CSR atomicity violations",
                         csr_invariant_errors);
            if (amo_invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d RMW atomicity violations",
                         amo_invariant_errors);
            if (deleg_invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d delegated-trap violations",
                         deleg_invariant_errors);
            $display(" a0             : 0x%08h (%0d)", dbg_reg_data, dbg_reg_data);
            $display("----------------------------------------------------------------");
            if (pass && invariant_errors == 0 && csr_invariant_errors == 0
                     && amo_invariant_errors == 0 && amo_starts == amo_retires
                     && amo_writes == amo_retires && deleg_invariant_errors == 0
                     && csr_ops == csr_retired)
                 $display("*** TEST PASSED ***");
            else      $display("*** TEST FAILED ***");
            $finish;
        end
    endtask

    always @(posedge clk) begin
        if (!rst && halted) begin
            // One extra edge so the last writeback is visible on the debug port
            @(posedge clk);
            if (trap_error) begin
                $display("HALT: trap, mcause=%0d at pc=%08h (instr=%08h)",
                         trap_cause, stage2_pc, stage2_instruction);
                case (trap_cause)
                    `CAUSE_INSTR_MISALIGNED: $display("      instruction address misaligned");
                    `CAUSE_ILLEGAL_INSTR:    $display("      illegal instruction");
                    `CAUSE_LOAD_MISALIGNED:  $display("      load address misaligned");
                    `CAUSE_STORE_MISALIGNED: $display("      store address misaligned");
                    default:                 $display("      unexpected cause");
                endcase
                report_and_exit(expect_trap == {28'd0, trap_cause});
            end
            else begin
                $display("HALT: %0s", (ebreak_halt &&
                         trap_cause == `CAUSE_BREAKPOINT) ? "ebreak" : "ecall");
                if (expect_trap >= 0) begin
                    $display("      expected a trap but the program ran to completion");
                    report_and_exit(0);
                end
                report_and_exit(dbg_reg_data == 32'd0);
            end
        end
    end

    always @(posedge clk) begin
        if (!rst && cycles >= timeout) begin
            $display("HALT: timeout after %0d cycles, pc=%08h", cycles, stage2_pc);
            report_and_exit(0);
        end
    end

endmodule
