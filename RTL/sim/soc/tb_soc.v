`include "definitions.vh"
`include "wb_defines.vh"

// =============================================================================
// SoC testbench: the whole system, against a behavioural SDRAM model.
//
// Its most useful feature is a serial receiver. It samples uart_tx at the
// configured baud rate and prints the characters, so firmware output appears in
// the simulation log exactly as it will on the terminal. That means the BIOS can
// be debugged here, where there is a waveform, rather than on the board where
// the only evidence is bytes on a wire.
//
// Plusargs:
//   +hex=<file>      boot RAM image (word oriented), required
//   +vcd=<file>      waveform dump
//   +timeout=<n>     cycle limit, default 20 million
//   +baud=<n>        expected baud rate, default 38400
//   +quiet           suppress the per-character echo
//   +trace           print every retired instruction (very verbose)
//   +uart_in=<file>  type the file into the console, one line per shell
//                    prompt ("# "); +uart_gap=<cycles> between characters
//   +stall=<n>       stop with the full halt dump if no instruction retires
//                    for n cycles - a hung pipeline, as opposed to a slow one
//   +pcsample=<n>    every n cycles, write the last retired PC, ra and sp to +pcfile=
//                    (default pcsample.txt). A statistical profile: run it
//                    through scripts/pcprofile.py with a System.map to see
//                    where a long silent stretch of a Linux boot is spent.
// =============================================================================
module tb_soc;

    localparam FREQ    = `SOC_CLK_HZ;
    localparam CLK_NS  = 1_000_000_000 / FREQ;    // 37 ns, close enough to 27 MHz

    reg clk = 1'b0;
    reg clk_sdram = 1'b1;                          // 180 degrees from clk
    reg rst = 1'b1;

    wire [31:0] SDRAM_DQ;
    wire [10:0] SDRAM_A;
    wire [1:0]  SDRAM_BA;
    wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS;
    wire        SDRAM_CLK, SDRAM_CKE;
    wire [3:0]  SDRAM_DQM;

    wire        uart_tx;
    reg         uart_rx = 1'b1;                    // idle high
    wire [5:0]  led_pwm;

    wire        halted, trap_error, ebreak_halt, bus_error, decode_miss;
    wire [3:0]  trap_cause;
    wire        retire_valid, dbg_muldiv_stall;
    wire        csr_capture, csr_commit;
    wire [31:0] csr_old_dbg;
    reg         csr_active = 1'b0;
    reg         csr_capture_d = 1'b0;
    reg  [31:0] csr_seen = 32'd0;
    integer     csr_ops = 0;
    integer     csr_retired = 0;
    integer     csr_invariant_errors = 0;

    // RV32A. Same reasoning as the PLIC and CSR invariants: a read-modify-write
    // is multi-cycle and its intermediate state never reaches a register, so
    // only the sequencer can be watched. Over the bus this matters more than on
    // the bare core, because here each half really does take several cycles.
    wire        amo_read, amo_write, resv_valid;
    reg         amo_read_prev  = 1'b0;
    reg         amo_write_prev = 1'b0;
    integer     amo_starts  = 0;
    integer     amo_writes  = 0;
    integer     amo_retires = 0;
    integer     amo_invariant_errors = 0;

    // PLIC claim atomicity, checked structurally - see the invariant below.
    reg         plic_claim_d = 1'b0;
    reg  [2:0]  plic_claim_id = 3'd0;
    reg  [7:0]  plic_pend_before = 8'd0;
    integer     plic_invariant_errors = 0;
    // A faulted fetch must not drive the data side. Its instruction bits are
    // stale bus data; letting them request a translation livelocked Linux on
    // its first sret into busybox (see dmem_op_d in riscv_core.v).
    integer     ifault_invariant_errors = 0;
    wire [31:0] retire_pc, retire_instruction, stage2_pc, stage2_instruction;
    reg  [4:0]  dbg_reg_addr = 5'd10;
    wire [31:0] dbg_reg_data;

    integer     timeout = 20_000_000;
    integer     baud    = 38400;
    integer     cycles  = 0;
    integer     retired = 0;
    integer     chars   = 0;
    reg         quiet, do_trace;
    reg [8*256-1:0] hex_file, vcd_file;

    // ------------------------------------------------------------------------
    // Retired-PC ring buffer.
    //
    // For bringing up firmware that is too big to trace. A full trace of an
    // OpenSBI boot is millions of lines; what is actually wanted when it stops
    // is the last few hundred instructions before it stopped. This keeps them
    // and prints them at the end, which turns "it hangs somewhere" into an
    // address that can be looked up in a disassembly.
    // ------------------------------------------------------------------------
    localparam HIST = 512;
    reg [31:0] hist_pc   [0:HIST-1];
    reg [31:0] hist_inst [0:HIST-1];
    integer    hist_wr = 0;
    integer    hist_n  = 0;
    reg        want_hist;
    // Stop the run when this PC retires. Without it the ring buffer of a hung
    // firmware contains nothing but the hang loop; with it, it contains how the
    // firmware got there.
    reg [31:0] stop_at, stop_at2;
    reg        have_stop, have_stop2;
    reg        stop_hit = 1'b0;
    reg [31:0] stop_which = 32'd0;      // the address that actually matched

    // Heartbeat. A firmware that runs for tens of millions of cycles with a long
    // silent stretch before its console exists is indistinguishable from a hang,
    // and guessing wrong in either direction wastes minutes.
    integer    progress_every = 0;
    integer    progress_next  = 0;

    // PC sampling. A heartbeat says the machine is alive; it does not say
    // where it is. Sampling the last retired PC at a fixed cycle interval is a
    // poor man's profiler for the parts of a boot that print nothing.
    integer    pcs_every = 0;
    integer    pcs_next  = 0;
    integer    pcs_fd    = 0;
    reg [31:0] pcs_last  = 32'd0;
    reg [8*256-1:0] pcs_file;

    // Stall watchdog. A heartbeat whose instruction count stops moving is a
    // pipeline that is stuck, not a kernel that is slow - but the timeout dump
    // that explains *why* only came at the end of a 2-billion-cycle budget,
    // hours later. This brings that dump forward to the moment it happens.
    // Off by default; an idle kernel at HZ=100 still retires every 240 k cycles.
    integer    stall_limit = 0;
    integer    last_retire = 0;
    // Optional SDRAM preloads, three slots. See load_sdram below.
    // Four preload slots: a Linux boot needs kernel, firmware, device tree and
    // initrd, and there is no point loading three of them and stopping.
    reg [8*256-1:0] sd_file [0:3];
    reg [31:0]      sd_at   [0:3];
    reg             sd_have [0:3];
    integer         pi;

    // SD card, SPI mode. The model answers from a sparse image built by
    // scripts/mksdimage.py; with no image loaded every sector reads as zeroes,
    // which the FAT32 parser correctly refuses to mount.
    wire sdc_cs_n, sdc_sck, sdc_mosi, sdc_miso;

    wire [31:0] dc_hits, dc_misses, dc_evictions, dc_uncached;
    wire [31:0] ic_hits, ic_misses, ic_uncached;
    wire [4:0]  dbg_flush;
    wire [31:0] dtlb_hits, dtlb_misses, dtlb_faults;
    wire [31:0] itlb_hits, itlb_misses, itlb_faults;

    sd_model sdcard (
        .clk (clk), .cs_n (sdc_cs_n), .sck (sdc_sck),
        .mosi (sdc_mosi), .miso (sdc_miso)
    );

    // Overridable from the build (-GDCACHE=0), so the same testbench measures
    // the machine with and without the cache. Comparing two numbers taken from
    // two different testbenches would compare the testbenches.
    parameter DCACHE = 1;
    parameter ICACHE = 1;

    soc_wb #(.FREQ (FREQ), .BOOT_INIT (""),
             .DCACHE (DCACHE), .ICACHE (ICACHE)) dut (
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
        .dbg_dc_hits (dc_hits), .dbg_dc_misses (dc_misses),
        .dbg_dc_evictions (dc_evictions), .dbg_dc_uncached (dc_uncached),
        .dbg_ic_hits (ic_hits), .dbg_ic_misses (ic_misses),
        .dbg_ic_uncached (ic_uncached), .dbg_flush (dbg_flush),
        .dbg_dtlb_hits (dtlb_hits), .dbg_dtlb_misses (dtlb_misses),
        .dbg_dtlb_faults (dtlb_faults),
        .dbg_itlb_hits (itlb_hits), .dbg_itlb_misses (itlb_misses),
        .dbg_itlb_faults (itlb_faults),
        .retire_valid (retire_valid), .retire_pc (retire_pc),
        .retire_instruction (retire_instruction),
        .dbg_stage2_pc (stage2_pc), .dbg_stage2_instruction (stage2_instruction),
        .dbg_muldiv_stall (dbg_muldiv_stall),
        .dbg_csr_capture (csr_capture),
        .dbg_csr_commit (csr_commit),
        .dbg_csr_old (csr_old_dbg),
        .dbg_amo_read (amo_read), .dbg_amo_write (amo_write),
        .dbg_resv_valid (resv_valid)
    );

    sdram_model sdram_chip (
        .SDRAM_DQ (SDRAM_DQ), .SDRAM_A (SDRAM_A), .SDRAM_BA (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS), .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS (SDRAM_nRAS), .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_CLK (SDRAM_CLK), .SDRAM_CKE (SDRAM_CKE), .SDRAM_DQM (SDRAM_DQM)
    );

    // Two anti-phase clocks, as the PLL provides on hardware
    always #(CLK_NS/2) clk       = ~clk;
    always #(CLK_NS/2) clk_sdram = ~clk_sdram;

    // ------------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------------
    initial begin
        if (!$value$plusargs("hex=%s", hex_file)) begin
            $display("TB-ERROR: no boot image. Pass +hex=<file>.");
            $finish;
        end
        if (!$value$plusargs("timeout=%d", timeout)) timeout = 20_000_000;
        /*
         * A cycle budget is an integer, which is 32 bits and signed. Asking for
         * three billion wraps negative and the run ends on its first cycle,
         * reporting a timeout at pc=0 - which looks exactly like a machine that
         * never started. Say so instead.
         */
        if (timeout <= 0) begin
            $display("+timeout=%0d is not a positive cycle count (max 2147483647)",
                     timeout);
            $finish;
        end
        // Optional SDRAM preloads. Three slots, because a real handoff needs
        // at least two blobs - firmware and device tree - and a kernel makes
        // three. This is the simulation stand-in for the SD card loader.
        for (pi = 0; pi < 4; pi = pi + 1) sd_have[pi] = 1'b0;
        if ($value$plusargs("sdram0=%s", sd_file[0])) sd_have[0] = 1'b1;
        if ($value$plusargs("sdram1=%s", sd_file[1])) sd_have[1] = 1'b1;
        if ($value$plusargs("sdram2=%s", sd_file[2])) sd_have[2] = 1'b1;
        if ($value$plusargs("sdram3=%s", sd_file[3])) sd_have[3] = 1'b1;
        if (!$value$plusargs("sdram0_at=%h", sd_at[0])) sd_at[0] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("sdram1_at=%h", sd_at[1])) sd_at[1] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("sdram2_at=%h", sd_at[2])) sd_at[2] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("sdram3_at=%h", sd_at[3])) sd_at[3] = `SDRAM_BASE_ADDR;
        if (!$value$plusargs("baud=%d", baud))       baud    = 38400;
        quiet     = $test$plusargs("quiet");
        do_trace  = $test$plusargs("trace");
        want_hist = $test$plusargs("hist");
        if ($value$plusargs("progress=%d", progress_every))
            progress_next = progress_every;
        if (!$value$plusargs("stall=%d", stall_limit)) stall_limit = 0;
        if ($value$plusargs("pcsample=%d", pcs_every) && pcs_every > 0) begin
            if (!$value$plusargs("pcfile=%s", pcs_file))
                pcs_file = "pcsample.txt";
            pcs_fd = $fopen(pcs_file, "w");
            pcs_next = pcs_every;
            $display("   pcsample: every %0d cycles -> %0s", pcs_every, pcs_file);
        end
        have_stop  = $value$plusargs("stopat=%h",  stop_at);
        have_stop2 = $value$plusargs("stopat2=%h", stop_at2);
        if (have_stop)  $display("   stop at : 0x%08h", stop_at);
        if (have_stop2) $display("   stop at : 0x%08h", stop_at2);

        if ($value$plusargs("vcd=%s", vcd_file)) begin
            $dumpfile(vcd_file);
            $dumpvars(0, tb_soc);
        end

        $display("================================================================");
        $display(" RV32IM SoC simulation");
        $display("   image   : %0s", hex_file);
        $display("   clock   : %0d Hz (%0d ns period)", FREQ, CLK_NS);
        $display("   baud    : %0d", baud);
        $display("================================================================");

        // Load the boot image only after every initial block has run. wb_ram
        // zeroes its arrays in its own initial block, and the relative order of
        // initial blocks is undefined, so loading at time zero can be silently
        // undone.
        repeat (4) @(posedge clk);
        load_boot(hex_file);
        for (pi = 0; pi < 4; pi = pi + 1)
            if (sd_have[pi]) load_sdram(sd_file[pi], sd_at[pi]);
        repeat (4) @(posedge clk);
        rst = 1'b0;
    end

    // ------------------------------------------------------------------------
    // SDRAM preload.
    //
    // The controller maps a byte address straight through: bank, row and column
    // are contiguous top-to-bottom slices of addr[22:2], so the model's flat
    // array index *is* the word offset into the region. That makes a preload a
    // plain $readmemh at an offset rather than anything that has to understand
    // banking.
    //
    // This exists because OpenSBI does not fit in 32 KB of block RAM - it has to
    // run from SDRAM, and something has to put it there. On hardware that will
    // be the SD card loader; in simulation it is this.
    // ------------------------------------------------------------------------
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

    // The image is word oriented, matching what the FPGA build loads into the
    // same module, so simulation and hardware run byte-identical memory content.
    task load_boot(input [8*256-1:0] fname);
        integer k;
        begin
            for (k = 0; k < `BOOT_RAM_BYTES/4; k = k + 1) dut.bootram.mem[k] = 32'h0;
            $readmemh(fname, dut.bootram.mem);
        end
    endtask

    // ------------------------------------------------------------------------
    // Serial receiver: 8N1, sampled mid-bit
    // ------------------------------------------------------------------------
    real bit_ns;
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
            #(bit_ns * 1.5);                       // into the middle of bit 0
            rx_byte = 8'h00;
            for (b = 0; b < 8; b = b + 1) begin
                rx_byte[b] = uart_tx;
                #(bit_ns);
            end
            chars = chars + 1;
            // A shell prompt ends in "# ". Counting them is what lets the
            // transmitter below type one line per prompt.
            if (rx_byte == 8'h20 && rx_prev == 8'h23) prompts = prompts + 1;
            rx_prev = rx_byte;
            if (!quiet) begin
                if (rx_byte == 8'h0A)      $write("\n");
                else if (rx_byte == 8'h0D) ;       // swallow CR
                else                       $write("%c", rx_byte);
                $fflush();
            end
        end
    end

    // ------------------------------------------------------------------------
    // Serial transmitter: something to type into the console.
    //
    // uart_rx was tied idle, so a simulated Linux could print but never be
    // spoken to. This sends +uart_in's lines, each one only after the next
    // shell prompt has arrived - the core runs ~1.5 MIPS, and characters
    // fired at line rate would overrun the 16-byte receive FIFO long before
    // the shell read them. The per-character gap is generous for the same
    // reason: one byte per +uart_gap cycles (default 24 000, ~1 ms).
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
                    #(CLK_NS * uin_gap);
                    // one 8N1 frame
                    uart_rx = 1'b0;
                    #(bit_ns);
                    for (tb_b = 0; tb_b < 8; tb_b = tb_b + 1) begin
                        uart_rx = uin_c[tb_b];
                        #(bit_ns);
                    end
                    uart_rx = 1'b1;
                    #(bit_ns);
                    if (uin_c == 8'h0A) uin_line = uin_line + 1;
                    uin_c = $fgetc(uin_fd);
                end
                $fclose(uin_fd);
            end
        end
    end

    // ------------------------------------------------------------------------
    // Accounting and end of test
    // ------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst) begin
            cycles = cycles + 1;

            if (progress_every > 0 && cycles >= progress_next) begin
                $display("   [%0d M cycles, %0d instructions, %0d uart chars]",
                         cycles / 1000000, retired, chars);
                // Flushed for the same reason the UART path is, and it matters
                // most in exactly the case this line exists to report. Guest
                // output above flushes per character, so when the guest goes
                // quiet the only thing still being written is this - and
                // without the flush it sits in stdio's buffer waiting for a
                // guest character that is never coming. A silent hang then
                // looks identical to a hang that produces no progress lines
                // either, which cost most of an afternoon to tell apart.
                $fflush();
                if (pcs_fd != 0) $fflush(pcs_fd);
                progress_next = progress_next + progress_every;
            end

            if (stall_limit > 0 && !retire_valid &&
                cycles - last_retire >= stall_limit && timeout > cycles + 1) begin
                $display("");
                $display("STALL: nothing retired for %0d cycles; last retired pc=%08h at cycle %0d",
                         stall_limit, pcs_last, last_retire);
                timeout = cycles + 1;           // reuse the timeout dump
            end

            if (pcs_fd != 0 && cycles >= pcs_next) begin
                // pc, ra, sp. ra names the caller of a leaf function; sp
                // names the thread, because every kernel stack is its own
                // 8 KiB-aligned block - so a sample can say not just where
                // the time went but on whose behalf.
                $fwrite(pcs_fd, "%08h %08h %08h\n", pcs_last,
                        dut.core.decode_exec_inst.reg_file_inst.reg_file[1],
                        dut.core.decode_exec_inst.reg_file_inst.reg_file[2]);
                pcs_next = pcs_next + pcs_every;
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

            // ------------------------------------------------------------
            // PLIC claim atomicity invariant.
            //
            // A claim does two things at once: it returns the winning source ID
            // and it clears that source's pending bit. They must be the same
            // source. Nothing in software can prove that - by the time the load
            // result is in a register, the winner has already changed, and the
            // handler would simply service and complete the ID it was given,
            // leaving the *other* source pending and looking for all the world
            // like a device that had not asserted yet.
            //
            // The failure needs a higher-priority source to arrive in the single
            // cycle between the two, which no program can arrange on purpose. So
            // check the structure instead: latch the winner and the pending word
            // as the claim is decoded, and one cycle later compare the returned
            // data and the bit that actually cleared against that snapshot.
            // ------------------------------------------------------------
            if (plic_claim_d) begin
                if (dut.plic.wb_dat_o !== {29'd0, plic_claim_id}) begin
                    plic_invariant_errors = plic_invariant_errors + 1;
                    if (plic_invariant_errors <= 5)
                        $display("TB-ERROR: PLIC claim returned %0d, winner was %0d, cycle %0d",
                                 dut.plic.wb_dat_o, plic_claim_id, cycles);
                end
                // Exactly the claimed source's bit may clear. Gateways only
                // ever set bits, so anything else going low is the claim
                // clearing the wrong one.
                else if ((plic_pend_before & ~dut.plic.pending_r) !==
                         ((plic_claim_id == 3'd0) ? 8'd0 : (8'd1 << plic_claim_id))) begin
                    plic_invariant_errors = plic_invariant_errors + 1;
                    if (plic_invariant_errors <= 5)
                        $display("TB-ERROR: PLIC claim %0d cleared %02h, cycle %0d",
                                 plic_claim_id,
                                 plic_pend_before & ~dut.plic.pending_r, cycles);
                end
            end
            // ------------------------------------------------------------
            // RV32A structural invariants. One read phase and one write phase
            // per retired AMO, and nothing retires mid-sequence. A sequencer
            // that restarted would read back the value it had just written and
            // apply the operation twice - an amoadd would add twice - and with
            // an idempotent operation it would not be visible in the final
            // state at all.
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

            if (dut.core.ifetch_fault_d && dut.core.valid_d &&
                dut.core.dmmu.req_valid) begin
                ifault_invariant_errors = ifault_invariant_errors + 1;
                if (ifault_invariant_errors <= 5)
                    $display("TB-ERROR: data MMU request from a faulted fetch at cycle %0d, pc=%08h",
                             cycles, stage2_pc);
            end

            amo_read_prev  <= amo_read;
            amo_write_prev <= amo_write;

            plic_claim_d     <= dut.plic.claim_now;
            // The context being claimed, not context 0. The BIOS only ever
            // claims as M-mode (context 0), so hardcoding it held until Linux
            // claimed as S-mode (context 1): M has nothing enabled, best_id[0]
            // is 0, and every correct S-mode claim of the UART was reported as
            // "returned 1, winner was 0".
            plic_claim_id    <= dut.plic.best_id[dut.plic.ctx_idx];
            plic_pend_before <= dut.plic.pending_r;

            // Exactly one commit per CSR instruction. A commit is a CSR write,
            // and the spec allows writes to have side effects, so doing it twice
            // is wrong even when the value is identical - and for mcycle a
            // repeated write freezes the counter for as long as the repeat
            // lasts. Counting both sides is the cheapest way to notice.
            if (retire_valid && retire_instruction[6:0] == 7'b1110011 &&
                retire_instruction[14:12] != 3'b000)
                csr_retired = csr_retired + 1;
            if (retire_valid && want_hist) begin
                hist_pc[hist_wr]   <= retire_pc;
                hist_inst[hist_wr] <= retire_instruction;
                hist_wr = (hist_wr + 1) % HIST;
                if (hist_n < HIST) hist_n = hist_n + 1;
            end
            // Record *which* address matched. Reporting the first one
            // regardless made a successful payload look like a firmware panic.
            if (retire_valid && have_stop && retire_pc == stop_at) begin
                stop_hit   <= 1'b1;
                stop_which <= stop_at;
            end
            else if (retire_valid && have_stop2 && retire_pc == stop_at2) begin
                stop_hit   <= 1'b1;
                stop_which <= stop_at2;
            end
            if (retire_valid) begin
                retired = retired + 1;
                pcs_last = retire_pc;
                last_retire = cycles;
                if (do_trace)
                    $display("[%8d] pc=%08h instr=%08h", cycles, retire_pc,
                             retire_instruction);
            end
        end
    end

    // Oldest first, so the tail of the list is where it stopped.
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

    task finish_up(input [8*32-1:0] why, input pass);
        begin
            finish_up_v(why, pass ? 2'd1 : 2'd0);
        end
    endtask

    task finish_up_v(input [8*32-1:0] why, input [1:0] verdict);
        begin
            if (want_hist) dump_history;
            $display("");
            $display("----------------------------------------------------------------");
            $display(" stopped        : %0s", why);
            $display(" cycles         : %0d", cycles);
            $display(" instructions   : %0d", retired);
            $display(" uart chars     : %0d", chars);
            // The BIOS deliberately reads an unmapped address to prove the
            // interconnect answers instead of hanging, so a latched bus error
            // is expected here and is reported rather than treated as a fault.
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
            if (bus_error)   $display(" bus error seen : yes (the BIOS probes an unmapped address)");
            if (decode_miss) $display(" DECODE MISS    : unmapped address on the bus now");
            sdram_chip.report;
            if (sdram_chip.errors != 0)
                $display(" SDRAM MODEL    : %0d protocol violations", sdram_chip.errors);
            $display(" a0             : 0x%08h (%0d)", dbg_reg_data, dbg_reg_data);
            $display("----------------------------------------------------------------");
            if (verdict == 2'd2)
                 $display("*** SoC RUN STOPPED AT A REQUESTED ADDRESS ***");
            else if (verdict == 2'd1 && sdram_chip.errors == 0
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

    always @(posedge clk) begin
        if (!rst && stop_hit) begin
            $display("");
            $display("STOP: reached the requested pc 0x%08h", stop_which);
            // Neutral: a run that stopped where it was told to has not passed or
            // failed the a0 convention, because nothing set a0 for it. Calling
            // it FAILED made every successful OpenSBI boot look like a defect.
            finish_up_v("stopat", 2'd2);
        end
    end

    always @(posedge clk) begin
        if (!rst && halted) begin
            @(posedge clk);
            if (trap_error) begin
                $display("");
                $display("HALT: trap mcause=%0d at pc=%08h instr=%08h",
                         trap_cause, stage2_pc, stage2_instruction);
                finish_up("trap", 1'b0);
            end
            else begin
                $display("");
                $display("HALT: ebreak at pc=%08h", stage2_pc);
                finish_up("ebreak", dbg_reg_data == 32'd0);
            end
        end
        if (!rst && cycles >= timeout) begin
            $display("");
            $display("HALT: timeout, pc=%08h", stage2_pc);
            /*
             * Why it stopped, not just where.
             *
             * A frozen instruction count means something is stalled forever,
             * and there are six things that can do it. Reading them off is a
             * few hierarchical references; working them out from a waveform is
             * an afternoon. Added while chasing a Linux boot that stalled with
             * a page table walk half finished.
             */
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
                     dut.g_dcache.dcache.state, dut.g_icache.icache.state);
            /*
             * The supervisor trap state. A machine looping on a fault it cannot
             * handle is almost always a trap vector pointing somewhere that
             * also faults, and these four values say so immediately.
             */
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
            /*
             * What the TLBs are actually holding. A page fault has two very
             * different causes - a walk that found nothing, or a resident entry
             * whose permissions refuse the access - and only the entry itself
             * tells them apart. Reading the page table out of SDRAM cannot: the
             * kernel's writes to it may still be dirty in the data cache.
             */
            begin : dump_tlbs
                integer k;
                $display(" dtlb entries (v vpn ppn mega flags):");
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
            end

            /*
             * Follow the walk for whatever address faulted, one level at a
             * time. This is the only thing that separates "our walker is wrong"
             * from "the kernel never mapped it", and guessing between those two
             * is how an afternoon disappears.
             */
            if (dut.core.satp_value[31]) begin : walk_stval
                integer root_w, l1_i, l0_i, l0_w;
                reg [31:0] l1_pte, l0_pte, va;
                va     = dut.core.decode_exec_inst.csr_inst.stval;
                root_w = (({dut.core.satp_value[19:0], 12'h000} - `SDRAM_BASE_ADDR) >> 2);
                l1_i   = va[31:22];
                l1_pte = sdram_chip.mem[root_w + l1_i];
                $display(" walk of stval 0x%08h:", va);
                $display("   L1[%0d] = 0x%08h  ppn 0x%05h flags 0x%02h  %0s",
                         l1_i, l1_pte, l1_pte[31:10], l1_pte[7:0],
                         !l1_pte[0]         ? "INVALID" :
                         (l1_pte[3]|l1_pte[1]) ? "leaf (megapage)" : "pointer");
                if (l1_pte[0] && !(l1_pte[3] | l1_pte[1])) begin
                    l0_w   = (({l1_pte[29:10], 12'h000} - `SDRAM_BASE_ADDR) >> 2);
                    l0_i   = va[21:12];
                    l0_pte = sdram_chip.mem[l0_w + l0_i];
                    $display("   L0[%0d] = 0x%08h  ppn 0x%05h flags 0x%02h  %0s",
                             l0_i, l0_pte, l0_pte[31:10], l0_pte[7:0],
                             !l0_pte[0] ? "INVALID - the kernel never mapped this page"
                                        : "valid");
                end
            end

            /*
             * The root page table itself, read out of the SDRAM model. When a
             * walk says "not mapped", the only way to tell a broken walker from
             * a page table that really is empty is to look at the memory.
             */
            if (dut.core.satp_value[31]) begin : dump_pt
                integer root_w;
                integer k;
                /* The model's array is indexed from the SDRAM base, not from
                 * zero, and a physical address is not a word index. */
                root_w = (({dut.core.satp_value[19:0], 12'h000} - `SDRAM_BASE_ADDR) >> 2);
                $display(" root page table at 0x%08h (word %0d), non-zero entries:",
                         {dut.core.satp_value[19:0], 12'h000}, root_w);
                for (k = 0; k < 1024; k = k + 1)
                    if (sdram_chip.mem[root_w + k] != 32'd0)
                        $display("   [%0d] va 0x%08h -> pte 0x%08h  ppn 0x%05h flags 0x%02h",
                                 k, k << 22, sdram_chip.mem[root_w + k],
                                 sdram_chip.mem[root_w + k][31:10],
                                 sdram_chip.mem[root_w + k][7:0]);
            end
            finish_up("timeout", 1'b0);
        end
    end

endmodule
