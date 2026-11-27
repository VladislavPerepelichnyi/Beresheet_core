`include "wb_defines.vh"

// =============================================================================
// Unit testbench for plic_wb, driven directly on its Wishbone port.
//
// Covers register access, eip against threshold, and claim atomicity: a claim
// must return a source ID and clear that same source's pending bit even when a
// higher-priority source becomes pending in the claim cycle. That window is a
// single clock cycle and cannot be targeted from software, so the test sweeps
// the offset between raising the higher-priority source and the claim, and
// checks every claim against a snapshot taken when it was decoded.
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
    always #5 clk = ~clk;

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
    // Wishbone classic single transfer. Inputs change on the falling edge and
    // are sampled by the slave on the rising edge. A slave that does not ACK
    // within ACK_LIMIT cycles is a test failure.
    // -----------------------------------------------------------------------
    localparam ACK_LIMIT = 16;
    integer    wait_n;

    task wb_wait_ack(input [31:0] a);
        begin
            wait_n = 0;
            @(negedge clk);
            while (!ack && wait_n < ACK_LIMIT) begin
                @(negedge clk);
                wait_n = wait_n + 1;
            end
            if (!ack) begin
                $display("FAIL no ACK from address 0x%08h", a);
                errors = errors + 1;
            end
        end
    endtask

    task wb_write(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk);
            adr = a; dat_w = d; we = 1'b1; stb = 1'b1; cyc = 1'b1;
            wb_wait_ack(a);
            stb = 1'b0; cyc = 1'b0; we = 1'b0;
        end
    endtask

    task wb_read(input [31:0] a, output [31:0] q);
        begin
            @(negedge clk);
            adr = a; we = 1'b0; stb = 1'b1; cyc = 1'b1;
            wb_wait_ack(a);
            q = dat_r;
            stb = 1'b0; cyc = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Claim invariant, checked on every claim: latch the winner and the
    // pending word when the claim is decoded, then compare the returned ID and
    // the bit that cleared against them one cycle later.
    // -----------------------------------------------------------------------
    reg                 claim_d    = 1'b0;
    reg [2:0]           claim_id   = 3'd0;
    reg [NUM_SRCS-1:0]  pend_before= {NUM_SRCS{1'b0}};
    reg [2:0]           winner_d   = 3'd0;   // the winner one cycle earlier
    integer             claims     = 0;
    integer             races      = 0;

    // Cleared by reset so a claim just before a reset is not checked against
    // the reset device
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

            // A claim in the cycle the winner changed is the case the sweep
            // targets; the test fails if it never occurs.
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

        // --- phase sweep -------------------------------------------------
        //
        // Source 2 is pending at priority 1; source 3 (priority 5) becomes the
        // winner as soon as it is pending. Raise it d cycles before the claim
        // for each d; the invariant above checks every claim.
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

            src[3] = 1'b1;
            repeat (d) @(negedge clk);
            wb_read(PLIC_CLAIM_0, q);
            repeat (2) @(negedge clk);      // let the invariant check run
            if (q !== 32'd2 && q !== 32'd3) begin
                $display("FAIL sweep d=%0d: claim returned %0d", d, q);
                errors = errors + 1;
            end
            src = {NUM_SRCS{1'b0}};
        end

        if (races == 0) begin
            $display("FAIL sweep never hit the race window");
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

endmodule
