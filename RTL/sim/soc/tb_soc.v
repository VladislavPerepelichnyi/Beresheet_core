`timescale 1ns / 1ps
`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// SoC testbench: soc_wb with behavioural SDRAM and SD card models.
//
// A UART receiver decodes uart_tx and prints it, an optional transmitter types
// a file into uart_rx, and structural checkers watch invariants that software
// cannot observe (CSR, PLIC claim and RV32A atomicity). The run ends on EBREAK
// (PASS when a0 == 0 and every invariant held), on a fatal trap, or on one of
// the optional stop conditions below. There is no default cycle limit.
//
// Plusargs:
//   +hex=<file>            boot RAM image, word-oriented hex (required)
//   +sdram<N>=<file>       preload SDRAM from a word-oriented hex, N = 0..3
//   +sdram<N>_at=<hex>     byte address of preload N (default 0x80000000)
//   +sd_lba=<file>         SD image sector list   (default build/sd/sd_lba.hex)
//   +sd_dat=<file>         SD image sector data   (default build/sd/sd_dat.hex)
//   +nosdcard              simulate an empty SD socket
//   +baud=<n>              UART bit rate the firmware uses (default 38400)
//   +uart_in=<file>        type <file> into the console, one line per "# "
//                          shell prompt; +uart_gap=<cycles> between characters
//                          (default 24000)
//   +quiet                 do not echo UART output
//   +trace                 print every retired instruction
//   +max_cycles=<n>        stop after n cycles (default 0 = no limit)
//   +stall=<n>             stop if nothing retires for n cycles
//   +stopat=<hex>          stop when this PC retires (neutral verdict)
//   +progress=<n>          print a progress line every n cycles
//   +hist                  print the last 512 retired instructions at the end
//
// A stop on +max_cycles or +stall prints pipeline, TLB and page-table state.
// =============================================================================
module tb_soc;

    localparam integer FREQ          = `SOC_CLK_HZ;
    localparam real    CLK_PERIOD_NS = 1.0e9 / FREQ;

    localparam [1:0] V_FAIL = 2'd0, V_PASS = 2'd1, V_STOPPED = 2'd2;

    reg clk       = 1'b0;
    reg clk_sdram = 1'b1;                          // 180 degrees from clk
    reg rst       = 1'b1;

    // ------------------------------------------------------------------------
    // DUT and models
    // ------------------------------------------------------------------------
    wire [31:0] SDRAM_DQ;
    wire [10:0] SDRAM_A;
    wire [1:0]  SDRAM_BA;
    wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CLK, SDRAM_CKE;
    wire [3:0]  SDRAM_DQM;

    wire        uart_tx;
    reg         uart_rx = 1'b1;                    // idle high
    wire [5:0]  led_pwm;
    wire        sdc_cs_n, sdc_sck, sdc_mosi, sdc_miso;

    wire        halted, trap_error, ebreak_halt, bus_error, decode_miss;
    wire [3:0]  trap_cause;
    wire        retire_valid, dbg_muldiv_stall;
    wire [31:0] retire_pc, retire_instruction, stage2_pc, stage2_instruction;
    reg  [4:0]  dbg_reg_addr = 5'd10;              // a0
    wire [31:0] dbg_reg_data;
    wire        csr_capture, csr_commit;
    wire [31:0] csr_old_dbg;
    wire        amo_read, amo_write, resv_valid;

    wire [31:0] dc_hits, dc_misses, dc_evictions, dc_uncached;
    wire [31:0] ic_hits, ic_misses, ic_uncached;
    wire [31:0] dtlb_hits, dtlb_misses, dtlb_faults;
    wire [31:0] itlb_hits, itlb_misses, itlb_faults;

    sd_model sdcard (
        .clk (clk), .cs_n (sdc_cs_n), .sck (sdc_sck),
        .mosi (sdc_mosi), .miso (sdc_miso)
    );

    soc_wb #(.FREQ (FREQ), .BOOT_INIT ("")) dut (
        .clk (clk), .clk_sdram (clk_sdram), .rst (rst),
        .SDRAM_DQ (SDRAM_DQ), .SDRAM_A (SDRAM_A), .SDRAM_BA (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS), .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS (SDRAM_nRAS), .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_CLK (SDRAM_CLK), .SDRAM_CKE (SDRAM_CKE), .SDRAM_DQM (SDRAM_DQM),
        .uart_tx (uart_tx), .uart_rx (uart_rx), .led_pwm (led_pwm),
        .sd_cs_n (sdc_cs_n), .sd_sck (sdc_sck),
        .sd_mosi (sdc_mosi), .sd_miso (sdc_miso),
        .halted (halted), .trap_error (trap_error), .ebreak_halt (ebreak_halt),
        .trap_cause (trap_cause), .bus_error (bus_error),
        .decode_miss (decode_miss),
        .dbg_reg_addr (dbg_reg_addr), .dbg_reg_data (dbg_reg_data),
        .retire_valid (retire_valid), .retire_pc (retire_pc),
        .retire_instruction (retire_instruction),
        .dbg_stage2_pc (stage2_pc), .dbg_stage2_instruction (stage2_instruction),
        .dbg_muldiv_stall (dbg_muldiv_stall),
        .dbg_csr_capture (csr_capture),
        .dbg_csr_commit (csr_commit),
        .dbg_csr_old (csr_old_dbg),
        .dbg_amo_read (amo_read), .dbg_amo_write (amo_write),
        .dbg_resv_valid (resv_valid),
        .dbg_dc_hits (dc_hits), .dbg_dc_misses (dc_misses),
        .dbg_dc_evictions (dc_evictions), .dbg_dc_uncached (dc_uncached),
        .dbg_ic_hits (ic_hits), .dbg_ic_misses (ic_misses),
        .dbg_ic_uncached (ic_uncached),
        .dbg_dtlb_hits (dtlb_hits), .dbg_dtlb_misses (dtlb_misses),
        .dbg_dtlb_faults (dtlb_faults),
        .dbg_itlb_hits (itlb_hits), .dbg_itlb_misses (itlb_misses),
        .dbg_itlb_faults (itlb_faults)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = |{led_pwm, ebreak_halt, dbg_muldiv_stall};
    /* verilator lint_on UNUSEDSIGNAL */

    sdram_model sdram_chip (
        .SDRAM_DQ (SDRAM_DQ), .SDRAM_A (SDRAM_A), .SDRAM_BA (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS), .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS (SDRAM_nRAS), .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_CLK (SDRAM_CLK), .SDRAM_CKE (SDRAM_CKE), .SDRAM_DQM (SDRAM_DQM)
    );

    // Two anti-phase clocks, as the PLL provides on hardware
    always #(CLK_PERIOD_NS / 2.0) clk       = ~clk;
    always #(CLK_PERIOD_NS / 2.0) clk_sdram = ~clk_sdram;

    // ------------------------------------------------------------------------
    // Run state and options
    // ------------------------------------------------------------------------
    reg  [63:0] cycles         = 64'd0;
    reg  [63:0] retired        = 64'd0;
    reg  [63:0] max_cycles     = 64'd0;           // 0 = no limit
    reg  [63:0] stall_limit    = 64'd0;           // 0 = off
    reg  [63:0] last_retire    = 64'd0;
    reg  [31:0] last_pc        = 32'd0;
    reg  [63:0] progress_every = 64'd0;           // 0 = off
    reg  [63:0] progress_next  = 64'd0;
    integer     chars   = 0;
    integer     baud    = 38400;
    reg         quiet, do_trace, want_hist;
    reg [8*256-1:0] hex_file;

    reg [31:0] stop_at;
    reg        have_stop;
    reg        stop_hit = 1'b0;

    // Retired-instruction ring buffer, printed oldest first with +hist
    localparam HIST = 512;
    reg [31:0] hist_pc   [0:HIST-1];
    reg [31:0] hist_inst [0:HIST-1];
    integer    hist_wr = 0;
    integer    hist_n  = 0;

    // SDRAM preload slots: kernel, firmware, device tree, initrd
    reg [8*256-1:0] sd_file [0:3];
    reg [31:0]      sd_at   [0:3];
    reg             sd_have [0:3];
    integer         pi;

    // ------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("hex=%s", hex_file)) begin
            $display("TB-ERROR: no boot image. Pass +hex=<file>.");
            $finish;
        end
        for (pi = 0; pi < 4; pi = pi + 1) sd_have[pi] = 1'b0;
        if ($value$plusargs("sdram0=%s", sd_file[0])) sd_have[0] = 1'b1;
        if ($value$plusargs("sdram1=%s", sd_file[1])) sd_have[1] = 1'b1;
        if ($value$plusargs("sdram2=%s", sd_file[2])) sd_have[2] = 1'b1;
        if ($value$plusargs("sdram3=%s", sd_file[3])) sd_have[3] = 1'b1;
        if (!$value$plusargs("sdram0_at=%h", sd_at[0])) sd_at[0] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("sdram1_at=%h", sd_at[1])) sd_at[1] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("sdram2_at=%h", sd_at[2])) sd_at[2] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("sdram3_at=%h", sd_at[3])) sd_at[3] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("baud=%d", baud)) baud = 38400;
        if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 64'd0;
        if (!$value$plusargs("stall=%d", stall_limit))     stall_limit = 64'd0;
        if ($value$plusargs("progress=%d", progress_every))
            progress_next = progress_every;
        quiet     = $test$plusargs("quiet");
        do_trace  = $test$plusargs("trace");
        want_hist = $test$plusargs("hist");
        have_stop = $value$plusargs("stopat=%h", stop_at);

        $display("================================================================");
        $display(" Beresheet SoC simulation");
        $display("   image   : %0s", hex_file);
        $display("   clock   : %0d Hz", FREQ);
        $display("   baud    : %0d", baud);
        if (max_cycles != 0) $display("   limit   : %0d cycles", max_cycles);
        if (have_stop)       $display("   stop at : 0x%08h", stop_at);
        $display("================================================================");

        // Load after time zero so that no initial block in the design or the
        // models can overwrite the images.
        repeat (4) @(posedge clk);
        load_boot(hex_file);
        for (pi = 0; pi < 4; pi = pi + 1)
            if (sd_have[pi]) load_sdram(sd_file[pi], sd_at[pi]);
        repeat (4) @(posedge clk);
        rst = 1'b0;
    end

    // Bank, row and column are contiguous slices of the byte address in the
    // controller, so the model's flat array index is the word offset into the
    // SDRAM region and a preload is a plain $readmemh at that offset.
    task load_sdram(input [8*256-1:0] fname, input [31:0] byte_addr);
        integer word_off;
        begin
            word_off = (byte_addr - `SDRAM_BASE_ADDR) >> 2;
            if (byte_addr < `SDRAM_BASE_ADDR ||
                byte_addr >= (`SDRAM_BASE_ADDR + `SDRAM_BYTES)) begin
                $display("TB-ERROR: sdram preload address %08h is outside the region",
                         byte_addr);
                $finish;
            end
            $display("   sdram   : %0s -> 0x%08h (word %0d)", fname, byte_addr, word_off);
            $readmemh(fname, sdram_chip.mem, word_off);
        end
    endtask

    // Same word-oriented image format the FPGA build loads into wb_ram
    task load_boot(input [8*256-1:0] fname);
        integer k;
        begin
            for (k = 0; k < `BOOT_RAM_BYTES/4; k = k + 1) dut.bootram.mem[k] = 32'h0;
            $readmemh(fname, dut.bootram.mem);
        end
    endtask

    // ------------------------------------------------------------------------
    // UART receiver: 8N1, sampled mid-bit
    // ------------------------------------------------------------------------
    real      bit_ns;
    reg [7:0] rx_byte;
    reg [7:0] rx_prev = 8'h00;
    integer   prompts = 0;
    integer   b;
    initial begin
        bit_ns = 0.0;
        @(negedge rst);
        bit_ns = 1.0e9 / baud;
        forever begin
            @(negedge uart_tx);                    // start bit
            #(bit_ns * 1.5);                       // middle of bit 0
            rx_byte = 8'h00;
            for (b = 0; b < 8; b = b + 1) begin
                rx_byte[b] = uart_tx;
                #(bit_ns);
            end
            chars = chars + 1;
            if (rx_byte == 8'h20 && rx_prev == 8'h23) prompts = prompts + 1;  // "# "
            rx_prev = rx_byte;
            if (!quiet) begin
                if (rx_byte == 8'h0A)      $write("\n");
                else if (rx_byte == 8'h0D) ;       // drop CR
                else                       $write("%c", rx_byte);
                $fflush();
            end
        end
    end

    // ------------------------------------------------------------------------
    // UART transmitter for +uart_in. Each line is sent only after the next
    // shell prompt, and characters are spaced by +uart_gap cycles, so input
    // never outruns the 16-byte receive FIFO.
    // ------------------------------------------------------------------------
    reg [8*256-1:0] uin_file;
    integer         uin_fd, uin_c, uin_line, uin_gap, tb_b;
    initial begin
        if ($value$plusargs("uart_in=%s", uin_file)) begin
            if (!$value$plusargs("uart_gap=%d", uin_gap)) uin_gap = 24000;
            uin_fd = $fopen(uin_file, "r");
            if (uin_fd == 0)
                $display("TB-ERROR: cannot open +uart_in file %0s", uin_file);
            else begin
                @(negedge rst);
                uin_line = 0;
                uin_c = $fgetc(uin_fd);
                while (uin_c != -1) begin
                    wait (prompts > uin_line);
                    #(CLK_PERIOD_NS * uin_gap);
                    uart_rx = 1'b0;                // start bit
                    #(bit_ns);
                    for (tb_b = 0; tb_b < 8; tb_b = tb_b + 1) begin
                        uart_rx = uin_c[tb_b];
                        #(bit_ns);
                    end
                    uart_rx = 1'b1;                // stop bit
                    #(bit_ns);
                    if (uin_c == 32'h0A) uin_line = uin_line + 1;
                    uin_c = $fgetc(uin_fd);
                end
                $fclose(uin_fd);
            end
        end
    end

    // ------------------------------------------------------------------------
    // Structural invariants
    //
    // CSR: an access captures the old value on its first cycle and writes the
    //   result on its last; the captured value must not change in between, or
    //   rd and the written value come from different snapshots. Also exactly
    //   one commit per retired CSR instruction, since CSR writes may have side
    //   effects. csr_old is registered, so capture is sampled one cycle late.
    // PLIC: a claim must return the winner of its cycle and clear exactly that
    //   source's pending bit. Checked one cycle after the claim is decoded,
    //   against a snapshot of the winner and the pending word.
    // RV32A: one read phase and one write phase per retired AMO, and nothing
    //   retires during a read phase; a restarted sequence would apply the
    //   operation twice.
    // Faulted fetch: an instruction whose fetch faulted must not issue a data
    //   MMU request; its instruction bits are not valid.
    // ------------------------------------------------------------------------
    reg         csr_active    = 1'b0;
    reg         csr_capture_d = 1'b0;
    reg  [31:0] csr_seen      = 32'd0;
    integer     csr_ops = 0, csr_retired = 0, csr_invariant_errors = 0;

    reg         plic_claim_d     = 1'b0;
    reg  [2:0]  plic_claim_id    = 3'd0;
    reg  [7:0]  plic_pend_before = 8'd0;
    integer     plic_invariant_errors = 0;

    reg         amo_read_prev  = 1'b0;
    reg         amo_write_prev = 1'b0;
    integer     amo_starts = 0, amo_writes = 0, amo_retires = 0;
    integer     amo_invariant_errors = 0;

    integer     ifault_invariant_errors = 0;

    always @(posedge clk) begin
        if (!rst) begin
            cycles = cycles + 64'd1;

            if (progress_every != 0 && cycles >= progress_next) begin
                $display("   [%0d M cycles, %0d instructions, %0d uart chars]",
                         cycles / 1000000, retired, chars);
                // Flush so the line appears even while the guest is silent
                $fflush();
                progress_next = progress_next + progress_every;
            end

            // --- CSR atomicity ---
            if (csr_capture_d) begin
                csr_seen   <= csr_old_dbg;
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
            if (retire_valid && retire_instruction[6:0] == 7'b1110011 &&
                retire_instruction[14:12] != 3'b000)
                csr_retired = csr_retired + 1;

            // --- PLIC claim atomicity ---
            if (plic_claim_d) begin
                if (dut.plic.wb_dat_o !== {29'd0, plic_claim_id}) begin
                    plic_invariant_errors = plic_invariant_errors + 1;
                    if (plic_invariant_errors <= 5)
                        $display("TB-ERROR: PLIC claim returned %0d, winner was %0d, cycle %0d",
                                 dut.plic.wb_dat_o, plic_claim_id, cycles);
                end
                // Gateways only set bits, so any bit that cleared was the claim
                else if ((plic_pend_before & ~dut.plic.pending_r) !==
                         ((plic_claim_id == 3'd0) ? 8'd0 : (8'd1 << plic_claim_id))) begin
                    plic_invariant_errors = plic_invariant_errors + 1;
                    if (plic_invariant_errors <= 5)
                        $display("TB-ERROR: PLIC claim %0d cleared %02h, cycle %0d",
                                 plic_claim_id,
                                 plic_pend_before & ~dut.plic.pending_r, cycles);
                end
            end
            plic_claim_d     <= dut.plic.claim_now;
            plic_claim_id    <= dut.plic.best_id[dut.plic.ctx_idx];   // claiming context
            plic_pend_before <= dut.plic.pending_r;

            // --- RV32A ---
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
            amo_read_prev  <= amo_read;
            amo_write_prev <= amo_write;

            // --- Faulted fetch ---
            if (dut.core.ifetch_fault_d && dut.core.valid_d &&
                dut.core.dmmu.req_valid) begin
                ifault_invariant_errors = ifault_invariant_errors + 1;
                if (ifault_invariant_errors <= 5)
                    $display("TB-ERROR: data MMU request from a faulted fetch at cycle %0d, pc=%08h",
                             cycles, stage2_pc);
            end

            // --- Retirement ---
            if (retire_valid) begin
                retired     = retired + 64'd1;
                last_retire = cycles;
                last_pc     = retire_pc;
                if (want_hist) begin
                    hist_pc[hist_wr]   = retire_pc;
                    hist_inst[hist_wr] = retire_instruction;
                    hist_wr = (hist_wr + 1) % HIST;
                    if (hist_n < HIST) hist_n = hist_n + 1;
                end
                if (have_stop && retire_pc == stop_at)
                    stop_hit <= 1'b1;
                if (do_trace)
                    $display("[%8d] pc=%08h instr=%08h", cycles, retire_pc,
                             retire_instruction);
            end
        end
    end

    // ------------------------------------------------------------------------
    // End of run
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst) begin
            if (stop_hit) begin
                $display("");
                $display("STOP: reached the requested pc 0x%08h", stop_at);
                finish_run("stopat", V_STOPPED);
            end

            if (halted) begin
                @(posedge clk);
                if (trap_error) begin
                    $display("");
                    $display("HALT: trap mcause=%0d at pc=%08h instr=%08h",
                             trap_cause, stage2_pc, stage2_instruction);
                    finish_run("trap", V_FAIL);
                end
                else begin
                    $display("");
                    $display("HALT: ebreak at pc=%08h", stage2_pc);
                    finish_run("ebreak", (dbg_reg_data == 32'd0) ? V_PASS : V_FAIL);
                end
            end

            if (stall_limit != 0 && !retire_valid &&
                cycles - last_retire >= stall_limit) begin
                $display("");
                $display("STALL: nothing retired for %0d cycles; last retired pc=%08h at cycle %0d",
                         stall_limit, last_pc, last_retire);
                dump_state;
                finish_run("stall", V_FAIL);
            end

            if (max_cycles != 0 && cycles >= max_cycles) begin
                $display("");
                $display("HALT: cycle limit reached, pc=%08h", stage2_pc);
                dump_state;
                finish_run("max_cycles", V_FAIL);
            end
        end
    end

    task dump_history;
        integer k, idx;
        begin
            $display("");
            $display(" last %0d retired instructions, oldest first:", hist_n);
            for (k = 0; k < hist_n; k = k + 1) begin
                idx = (hist_wr - hist_n + k + HIST) % HIST;
                $display("   pc=%08h  instr=%08h", hist_pc[idx], hist_inst[idx]);
            end
        end
    endtask

    task finish_run(input [8*32-1:0] why, input [1:0] verdict);
        begin
            if (want_hist) dump_history;
            $display("");
            $display("----------------------------------------------------------------");
            $display(" stopped        : %0s", why);
            $display(" cycles         : %0d", cycles);
            $display(" instructions   : %0d", retired);
            $display(" uart chars     : %0d", chars);
            if (csr_ops > 0 || csr_retired > 0) begin
                $display(" CSR accesses   : %0d committed, %0d retired",
                         csr_ops, csr_retired);
                if (csr_ops != csr_retired)
                    $display(" INVARIANT FAIL : CSR commits do not match retirements");
            end
            if (csr_invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d CSR atomicity violations",
                         csr_invariant_errors);
            if (plic_invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d PLIC claim atomicity violations",
                         plic_invariant_errors);
            if (ifault_invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d data MMU requests from faulted fetches",
                         ifault_invariant_errors);
            if (amo_starts > 0 || amo_retires > 0) begin
                $display(" RV32A atomics  : %0d RMW read, %0d RMW write, %0d retired",
                         amo_starts, amo_writes, amo_retires);
                if (amo_starts != amo_retires || amo_writes != amo_retires)
                    $display(" INVARIANT FAIL : RMW phases do not match retirements");
                if (resv_valid)
                    $display(" note           : a load reservation is still held");
            end
            if (amo_invariant_errors > 0)
                $display(" INVARIANT FAIL : %0d RMW atomicity violations",
                         amo_invariant_errors);
            if (dtlb_hits + dtlb_misses + itlb_hits + itlb_misses > 0) begin
                $display(" dtlb           : %0d hits, %0d misses, %0d faults",
                         dtlb_hits, dtlb_misses, dtlb_faults);
                $display(" itlb           : %0d hits, %0d misses, %0d faults",
                         itlb_hits, itlb_misses, itlb_faults);
            end
            if (ic_hits + ic_misses > 0) begin
                $display(" icache         : %0d hits, %0d misses, %0d uncached",
                         ic_hits, ic_misses, ic_uncached);
                $display("                  hit rate %0d%% of %0d cacheable fetches",
                         (ic_hits * 100) / (ic_hits + ic_misses),
                         ic_hits + ic_misses);
            end
            if (dc_hits + dc_misses > 0) begin
                $display(" dcache         : %0d hits, %0d misses, %0d evictions, %0d uncached",
                         dc_hits, dc_misses, dc_evictions, dc_uncached);
                $display("                  hit rate %0d%% of %0d cacheable accesses",
                         (dc_hits * 100) / (dc_hits + dc_misses),
                         dc_hits + dc_misses);
            end
            // The BIOS reads an unmapped address on purpose to test the error
            // slave, so a latched bus error is reported, not treated as a fault.
            if (bus_error)   $display(" bus error seen : yes");
            if (decode_miss) $display(" DECODE MISS    : unmapped address on the bus now");
            sdram_chip.report;
            if (sdram_chip.errors != 0)
                $display(" SDRAM MODEL    : %0d protocol violations", sdram_chip.errors);
            $display(" a0             : 0x%08h (%0d)", dbg_reg_data, dbg_reg_data);
            $display("----------------------------------------------------------------");
            if (verdict == V_STOPPED)
                 $display("*** SoC RUN STOPPED AT A REQUESTED ADDRESS ***");
            else if (verdict == V_PASS && sdram_chip.errors == 0
                     && csr_invariant_errors == 0
                     && plic_invariant_errors == 0 && amo_invariant_errors == 0
                     && ifault_invariant_errors == 0
                     && amo_starts == amo_retires && amo_writes == amo_retires
                     && csr_ops == csr_retired)
                 $display("*** SoC TEST PASSED ***");
            else $display("*** SoC TEST FAILED ***");
            $finish;
        end
    endtask

    // ------------------------------------------------------------------------
    // Diagnostic dump for a run that stopped without finishing: what is
    // stalling the pipeline, the trap CSRs, the TLB contents, and the Sv32
    // walk of stval read directly from the SDRAM model.
    // ------------------------------------------------------------------------
    task dump_state;
        integer k, root_w, l1_i, l0_i, l0_w;
        reg [31:0] l1_pte, l0_pte, va;
        begin
            $display(" stalled on   : mem=%0d fetch=%0d xlate=%0d fence=%0d csr=%0d muldiv=%0d",
                     dut.core.mem_stall,
                     dut.core.fetch_stall,
                     dut.core.dxlate_stall,
                     dut.core.control_unit_inst.fence_stall,
                     dut.core.control_unit_inst.csr_stall,
                     dut.core.muldiv_stall);
            $display(" dtlb         : ready=%0d fault=%0d ptw_re=%0d ptw_addr=%08h grant=%0d",
                     dut.core.dtlb_ready, dut.core.dtlb_fault,
                     dut.core.dptw_re, dut.core.dptw_addr, dut.core.dptw_grant);
            $display(" itlb         : ready=%0d fault=%0d ptw_re=%0d ptw_addr=%08h grant=%0d",
                     dut.core.itlb_ready, dut.core.itlb_fault,
                     dut.core.iptw_re, dut.core.iptw_addr, dut.core.iptw_grant);
            $display(" data port    : cpu_req=%0d addr=%08h ready=%0d  bus addr=%08h re=%0d we=%0d",
                     dut.core.cpu_dmem_req, dut.core.cpu_dmem_addr,
                     dut.core.cpu_dmem_ready,
                     dut.dmem_addr, dut.dmem_re, dut.dmem_we);
            $display(" satp         : %08h   priv=%0d",
                     dut.core.satp_value, dut.core.priv);
            $display(" dcache/icache state : %0d / %0d",
                     dut.dcache.state, dut.icache.state);
            $display(" stage2 instr : %08h   illegal=%0d csr_fault=%0d(miss=%0d ro=%0d priv=%0d tvm=%0d ctr=%0d)",
                     stage2_instruction,
                     dut.core.control_unit_inst.illegal_instruction,
                     dut.core.control_unit_inst.csr_fault,
                     dut.core.control_unit_inst.csr_fault_missing,
                     dut.core.control_unit_inst.csr_fault_ro,
                     dut.core.control_unit_inst.csr_fault_priv,
                     dut.core.control_unit_inst.csr_fault_tvm,
                     dut.core.control_unit_inst.csr_fault_ctr);
            $display(" ifetch_fault=%0d  trap_pending=%0d  inst_valid=%0d",
                     dut.core.ifetch_fault_d,
                     dut.core.control_unit_inst.trap_pending,
                     dut.core.valid_d);
            $display(" stvec=%08h sepc=%08h scause=%0d stval=%08h",
                     dut.core.decode_exec_inst.csr_inst.stvec,
                     dut.core.decode_exec_inst.csr_inst.sepc,
                     dut.core.decode_exec_inst.csr_inst.scause,
                     dut.core.decode_exec_inst.csr_inst.stval);
            $display(" mtvec=%08h mepc=%08h mcause=%0d medeleg=%08h",
                     dut.core.decode_exec_inst.csr_inst.mtvec,
                     dut.core.decode_exec_inst.csr_inst.mepc,
                     dut.core.decode_exec_inst.csr_inst.mcause,
                     dut.core.decode_exec_inst.csr_inst.medeleg);

            // Resident TLB entries. A page fault from a resident entry is a
            // permission problem; one from a walk is a missing mapping.
            $display(" dtlb entries:");
            for (k = 0; k < 4; k = k + 1)
                if (dut.core.dmmu.tlb_valid[k])
                    $display("   [%0d] va 0x%08h -> pa 0x%08h mega=%0d flags=0x%02h  R=%0d W=%0d X=%0d U=%0d A=%0d D=%0d",
                             k, {dut.core.dmmu.tlb_vpn[k], 12'h000},
                             {dut.core.dmmu.tlb_ppn[k], 12'h000},
                             dut.core.dmmu.tlb_mega[k],
                             dut.core.dmmu.tlb_flags[k],
                             dut.core.dmmu.tlb_flags[k][1],
                             dut.core.dmmu.tlb_flags[k][2],
                             dut.core.dmmu.tlb_flags[k][3],
                             dut.core.dmmu.tlb_flags[k][4],
                             dut.core.dmmu.tlb_flags[k][6],
                             dut.core.dmmu.tlb_flags[k][7]);
            $display(" itlb entries:");
            for (k = 0; k < 4; k = k + 1)
                if (dut.core.immu.tlb_valid[k])
                    $display("   [%0d] va 0x%08h -> pa 0x%08h mega=%0d flags=0x%02h",
                             k, {dut.core.immu.tlb_vpn[k], 12'h000},
                             {dut.core.immu.tlb_ppn[k], 12'h000},
                             dut.core.immu.tlb_mega[k],
                             dut.core.immu.tlb_flags[k]);

            // Software walk of stval and the non-zero root PTEs, from the SDRAM
            // model. Page-table writes still dirty in the D-cache are not seen.
            if (dut.core.satp_value[31]) begin
                va     = dut.core.decode_exec_inst.csr_inst.stval;
                root_w = (({dut.core.satp_value[19:0], 12'h000} - `SDRAM_BASE_ADDR) >> 2);
                l1_i   = {22'd0, va[31:22]};
                l1_pte = sdram_chip.mem[root_w + l1_i];
                $display(" walk of stval 0x%08h:", va);
                $display("   L1[%0d] = 0x%08h  ppn 0x%05h flags 0x%02h  %0s",
                         l1_i, l1_pte, l1_pte[31:10], l1_pte[7:0],
                         !l1_pte[0]            ? "INVALID" :
                         (l1_pte[3]|l1_pte[1]) ? "leaf (megapage)" : "pointer");
                if (l1_pte[0] && !(l1_pte[3] | l1_pte[1])) begin
                    l0_w   = (({l1_pte[29:10], 12'h000} - `SDRAM_BASE_ADDR) >> 2);
                    l0_i   = {22'd0, va[21:12]};
                    l0_pte = sdram_chip.mem[l0_w + l0_i];
                    $display("   L0[%0d] = 0x%08h  ppn 0x%05h flags 0x%02h  %0s",
                             l0_i, l0_pte, l0_pte[31:10], l0_pte[7:0],
                             !l0_pte[0] ? "INVALID" : "valid");
                end

                $display(" root page table at 0x%08h (word %0d), non-zero entries:",
                         {dut.core.satp_value[19:0], 12'h000}, root_w);
                for (k = 0; k < 1024; k = k + 1)
                    if (sdram_chip.mem[root_w + k] != 32'd0)
                        $display("   [%0d] va 0x%08h -> pte 0x%08h  ppn 0x%05h flags 0x%02h",
                                 k, k << 22, sdram_chip.mem[root_w + k],
                                 sdram_chip.mem[root_w + k][31:10],
                                 sdram_chip.mem[root_w + k][7:0]);
            end
        end
    endtask

endmodule
