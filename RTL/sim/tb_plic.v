`include "wb_defines.vh"

// =============================================================================
// Unit testbench for plic_wb.
//
// The software test in tests/rv32i/11_plic.S covers everything a driver can
// reach. This one exists for what it cannot: properties that live in a single
// clock cycle. Over the bus, a load takes several cycles and the program has no
// way to place an event inside a chosen one, so an entire class of bug is
// invisible from software however many checks you write.
//
// The property at issue is claim atomicity. A claim returns a source ID and
// clears that source's pending bit, and they must be the same source. If the
// returned value came from a register while the clear used live logic, the two
// would disagree whenever a higher-priority source became pending in exactly
// the cycle between - the claim would report source A while clearing source B,
// and the handler would service A and complete A, leaving B pending with its
// gateway open and no interrupt outstanding. A device that had asserted would
// simply never be serviced, occasionally, under load.
//
// Driving the PLIC directly makes that cycle reachable: the test sweeps the
// phase between raising a higher-priority source and issuing a claim, so one
// pass of the sweep lands in the window.
// =============================================================================
module tb_plic;

    localparam NUM_SRCS = 8;
    localparam NUM_CTXS = 2;

    localparam PLIC_PRIO_0   = 32'h0C00_0000;
    localparam PLIC_PENDING  = 32'h0C00_1000;
    localparam PLIC_ENABLE_0 = 32'h0C00_2000;
    localparam PLIC_THRESH_0 = 32'h0C20_0000;
    localparam PLIC_CLAIM_0  = 32'h0C20_0004;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;               // 100 MHz; the period is arbitrary here

    reg [31:0] adr   = 32'd0;
    reg [31:0] dat_w = 32'd0;
    reg        we    = 1'b0;
    reg        stb   = 1'b0;
    reg        cyc   = 1'b0;
    reg [NUM_SRCS-1:0] src = {NUM_SRCS{1'b0}};

    wire [31:0]         dat_r;
    wire                ack;
    wire [NUM_CTXS-1:0] eip;

    plic_wb #(
        .NUM_SRCS (NUM_SRCS), .NUM_CTXS (NUM_CTXS), .MAX_PRIORITY (7)
    ) dut (
        .clk (clk), .rst (rst),
        .src_irq (src), .eip (eip),
        .wb_adr_i (adr), .wb_dat_i (dat_w), .wb_sel_i (4'b1111),
        .wb_we_i (we), .wb_stb_i (stb), .wb_cyc_i (cyc),
        .wb_dat_o (dat_r), .wb_ack_o (ack)
    );

    integer errors = 0;
    integer cycles = 0;

    task check_eq(input [8*40-1:0] what, input [31:0] got, input [31:0] want);
        begin
            if (got !== want) begin
                $display("FAIL %0s: got %0d (0x%08h), want %0d",
                         what, got, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Wishbone classic single cycle. Drive on the falling edge, sample on the
    // next one: the slave latches at the rising edge in between, so nothing is
    // sampled in the same instant it changes.
    // -----------------------------------------------------------------------
    task wb_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            adr = a; dat_w = d; we = 1'b1; stb = 1'b1; cyc = 1'b1;
            @(negedge clk);
            while (!ack) @(negedge clk);
            stb = 1'b0; cyc = 1'b0; we = 1'b0;
        end
    endtask

    task wb_read(input [31:0] a, output [31:0] q);
        begin
            @(negedge clk);
            adr = a; we = 1'b0; stb = 1'b1; cyc = 1'b1;
            @(negedge clk);
            while (!ack) @(negedge clk);
            q = dat_r;
            stb = 1'b0; cyc = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // The invariant, checked on every claim for the whole run.
    //
    // Latch the winner and the pending word as the claim is decoded; one cycle
    // later, when the read data has landed, compare both against that snapshot.
    // -----------------------------------------------------------------------
    reg                 claim_d    = 1'b0;
    reg [2:0]           claim_id   = 3'd0;
    reg [NUM_SRCS-1:0]  pend_before= {NUM_SRCS{1'b0}};
    reg [2:0]           winner_d   = 3'd0;   // the winner one cycle earlier
    integer             claims     = 0;
    integer             races      = 0;

    // claim_d must be cleared by reset. Without that, a claim in the last cycle
    // before a reset leaves it set, and the check then runs against a wiped
    // device and reports a violation that never happened.
    always @(posedge clk) begin
        if (rst) begin
            claim_d <= 1'b0;
        end
        else begin
            cycles = cycles + 1;

            if (claim_d) begin
                claims = claims + 1;
                if (dut.wb_dat_o !== {29'd0, claim_id}) begin
                    $display("FAIL claim atomicity: returned %0d, winner was %0d, cycle %0d",
                             dut.wb_dat_o, claim_id, cycles);
                    errors = errors + 1;
                end
                else if ((pend_before & ~dut.pending_r) !==
                         ((claim_id == 3'd0) ? {NUM_SRCS{1'b0}}
                                             : ({{(NUM_SRCS-1){1'b0}}, 1'b1} << claim_id))) begin
                    $display("FAIL claim cleared the wrong bit: id %0d, cleared %02h, cycle %0d",
                             claim_id, pend_before & ~dut.pending_r, cycles);
                    errors = errors + 1;
                end
            end

            // A claim decoded in the same cycle the winner changed is the case
            // the sweep is hunting for; count them so a sweep that never hits
            // the window is visible rather than silently passing.
            if (dut.claim_now && (dut.best_id[0] !== winner_d))
                races = races + 1;

            claim_d      <= dut.claim_now;
            claim_id     <= dut.best_id[0];
            pend_before  <= dut.pending_r;
            winner_d     <= dut.best_id[0];
        end
    end

    // -----------------------------------------------------------------------
    task do_reset;
        begin
            rst = 1'b1;
            src = {NUM_SRCS{1'b0}};
            repeat (3) @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
        end
    endtask

    integer d;
    reg [31:0] q;

    initial begin
        $display("================================================================");
        $display(" plic_wb unit test");
        $display("================================================================");

        do_reset;

        // --- registers ---------------------------------------------------
        wb_write(PLIC_PRIO_0 + 4*2, 32'd5);
        wb_read (PLIC_PRIO_0 + 4*2, q);  check_eq("priority[2]", q, 32'd5);
        wb_write(PLIC_THRESH_0,     32'd3);
        wb_read (PLIC_THRESH_0,     q);  check_eq("threshold[0]", q, 32'd3);
        wb_write(PLIC_ENABLE_0,     32'h0000_000C);
        wb_read (PLIC_ENABLE_0,     q);  check_eq("enable[0]", q, 32'h0000_000C);
        wb_write(PLIC_PENDING,      32'hFFFF_FFFF);
        wb_read (PLIC_PENDING,      q);  check_eq("pending is read-only", q, 32'd0);

        // --- eip tracks priority against threshold -----------------------
        wb_write(PLIC_THRESH_0, 32'd0);
        wb_write(PLIC_PRIO_0 + 4*2, 32'd1);
        src[2] = 1'b1;
        repeat (3) @(negedge clk);
        check_eq("eip asserted", {31'd0, eip[0]}, 32'd1);
        check_eq("eip[S] quiet", {31'd0, eip[1]}, 32'd0);
        wb_write(PLIC_THRESH_0, 32'd1);         // priority 1 <= threshold 1
        @(negedge clk);
        check_eq("eip masked by threshold", {31'd0, eip[0]}, 32'd0);
        wb_write(PLIC_THRESH_0, 32'd0);

        // --- the phase sweep ---------------------------------------------
        //
        // Source 2 is pending at priority 1. Source 3 has priority 5, so the
        // moment it becomes pending it takes over as the winner. Raise it at
        // every offset from the claim and check the claim stays self-consistent
        // at each one; the invariant above does the checking.
        for (d = 0; d < 6; d = d + 1) begin
            do_reset;
            wb_write(PLIC_THRESH_0,     32'd0);
            wb_write(PLIC_ENABLE_0,     32'h0000_000C);   // sources 2 and 3
            wb_write(PLIC_PRIO_0 + 4*2, 32'd1);
            wb_write(PLIC_PRIO_0 + 4*3, 32'd5);

            src[2] = 1'b1;                  // the low-priority source, pending
            repeat (3) @(negedge clk);
            wb_read(PLIC_PENDING, q);
            check_eq("source 2 pending", q, 32'h0000_0004);

            src[3] = 1'b1;                  // the winner changes...
            repeat (d) @(negedge clk);       // ...d cycles before the claim
            wb_read(PLIC_CLAIM_0, q);
            // The invariant checks the claim on the following cycle, so give it
            // one before tearing the state down.
            repeat (2) @(negedge clk);
            if (q !== 32'd2 && q !== 32'd3) begin
                $display("FAIL sweep d=%0d: claim returned %0d", d, q);
                errors = errors + 1;
            end
            src = {NUM_SRCS{1'b0}};
        end

        if (races == 0) begin
            $display("FAIL sweep never hit the race window - the test proves nothing");
            errors = errors + 1;
        end

        $display("----------------------------------------------------------------");
        $display(" claims observed : %0d", claims);
        $display(" races hit       : %0d", races);
        $display(" errors          : %0d", errors);
        $display("----------------------------------------------------------------");
        if (errors == 0) $display("*** PLIC UNIT TEST PASSED ***");
        else             $display("*** PLIC UNIT TEST FAILED ***");
        $finish;
    end

    initial begin
        #200000;
        $display("*** PLIC UNIT TEST TIMEOUT ***");
        $finish;
    end

endmodule
