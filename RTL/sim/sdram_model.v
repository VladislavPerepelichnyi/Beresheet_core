// =============================================================================
// Behavioural model of the GW2AR-18 embedded SDRAM (64 Mbit, 32-bit wide).
//
// Organisation: 2K rows x 256 columns x 4 banks x 32 bits = 8 MB.
//
// This exists to validate the controller, and specifically the masked word
// write added in sdram_core.v. It decodes commands the way a real part does and
// complains loudly about protocol violations rather than quietly tolerating
// them, so a mistake in the controller shows up here instead of on the board.
//
// Checked: mode register set before any access, row activated before a
// read/write to that bank, CAS latency honoured, DQM masking on writes, auto
// precharge, and refresh interval. Not modelled: absolute ns timings (the
// controller's parameters handle those), power-up sequencing beyond the mode
// register, or burst lengths other than 1.
// =============================================================================
`timescale 1ns / 1ps

module sdram_model #(
    parameter ROW_WIDTH  = 11,
    parameter COL_WIDTH  = 8,
    parameter BANK_WIDTH = 2,
    parameter CAS_LATENCY = 2,
    // Refresh watchdog. The real part needs 4096 refreshes per 64 ms; a row
    // left un-refreshed longer than this would decay on hardware.
    parameter REFRESH_LIMIT_NS = 64_000_000 / 4096 * 8
)(
    inout  wire [31:0] SDRAM_DQ,
    input  wire [ROW_WIDTH-1:0]  SDRAM_A,
    input  wire [BANK_WIDTH-1:0] SDRAM_BA,
    input  wire        SDRAM_nCS,
    input  wire        SDRAM_nWE,
    input  wire        SDRAM_nRAS,
    input  wire        SDRAM_nCAS,
    input  wire        SDRAM_CLK,
    input  wire        SDRAM_CKE,
    input  wire [3:0]  SDRAM_DQM
);

    localparam BANKS     = 1 << BANK_WIDTH;
    localparam ROWS      = 1 << ROW_WIDTH;
    localparam COLS      = 1 << COL_WIDTH;
    localparam WORDS     = BANKS * ROWS * COLS;
    localparam IDX_WIDTH = BANK_WIDTH + ROW_WIDTH + COL_WIDTH;   // 21 bits

    // Command encoding, {nRAS, nCAS, nWE}
    localparam CMD_SET_MODE  = 3'b000;
    localparam CMD_REFRESH   = 3'b001;
    localparam CMD_PRECHARGE = 3'b010;
    localparam CMD_ACTIVATE  = 3'b011;
    localparam CMD_WRITE     = 3'b100;
    localparam CMD_READ      = 3'b101;
    // Handled by the default arm below; listed for completeness of the encoding.
    /* verilator lint_off UNUSEDPARAM */
    localparam CMD_BURST_END = 3'b110;
    localparam CMD_NOP       = 3'b111;
    /* verilator lint_on UNUSEDPARAM */

    reg [31:0] mem [0:WORDS-1];

    reg                  row_active [0:BANKS-1];
    reg [ROW_WIDTH-1:0]  active_row [0:BANKS-1];

    reg        configured;
    reg [2:0]  mode_cas;
    integer    errors;
    integer    reads, writes, refreshes;
    real       last_refresh_ns;

    // Read pipeline: a read scheduled now returns data CAS_LATENCY cycles later
    reg [31:0] rd_pipe_data [0:7];
    reg [7:0]  rd_pipe_valid;
    reg [31:0] dq_drive;
    reg        dq_driving;

    assign SDRAM_DQ = dq_driving ? dq_drive : 32'bz;

    wire [2:0] cmd = {SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE};

    // Bank, row and column are disjoint fields of the word index, so a
    // concatenation says exactly what the arithmetic said and is the right width
    // by construction.
    function [IDX_WIDTH-1:0] flat_addr(input [BANK_WIDTH-1:0] b,
                                       input [ROW_WIDTH-1:0]  r,
                                       input [COL_WIDTH-1:0]  c);
        flat_addr = {b, r, c};
    endfunction

    task complain(input [8*64-1:0] msg);
        begin
            errors = errors + 1;
            $display("SDRAM-MODEL ERROR @%0t: %0s", $time, msg);
        end
    endtask

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1) mem[i] = 32'hDEAD_BEEF;  // poison
        for (i = 0; i < BANKS; i = i + 1) begin
            row_active[i] = 1'b0;
            active_row[i] = 0;
        end
        configured      = 1'b0;
        mode_cas        = 3'd0;
        errors          = 0;
        reads           = 0;
        writes          = 0;
        refreshes       = 0;
        last_refresh_ns = 0.0;
        rd_pipe_valid   = 8'd0;
        dq_driving      = 1'b0;
        dq_drive        = 32'd0;
    end

    // ------------------------------------------------------------------------
    // Command decode, on the SDRAM clock
    // ------------------------------------------------------------------------
    always @(posedge SDRAM_CLK) begin
        if (SDRAM_CKE && !SDRAM_nCS) begin
            case (cmd)
                CMD_SET_MODE: begin
                    mode_cas   = SDRAM_A[6:4];
                    configured = 1'b1;
                    if (SDRAM_A[2:0] != 3'b000)
                        complain("burst length other than 1 not modelled");
                    if (mode_cas != CAS_LATENCY)
                        complain("mode register CAS does not match model CAS_LATENCY");
                end

                CMD_ACTIVATE: begin
                    if (!configured) complain("ACTIVATE before mode register set");
                    row_active[SDRAM_BA] = 1'b1;
                    active_row[SDRAM_BA] = SDRAM_A;
                end

                CMD_PRECHARGE: begin
                    if (SDRAM_A[10]) begin
                        for (i = 0; i < BANKS; i = i + 1) row_active[i] = 1'b0;
                    end
                    else begin
                        row_active[SDRAM_BA] = 1'b0;
                    end
                end

                CMD_REFRESH: begin
                    // The JEDEC power-up sequence is precharge-all, then two or
                    // more auto refreshes, then the mode register set, so a
                    // refresh before configuration is correct here.
                    for (i = 0; i < BANKS; i = i + 1)
                        if (row_active[i]) complain("REFRESH with a row still open");
                    refreshes       = refreshes + 1;
                    last_refresh_ns = $realtime;
                end

                CMD_WRITE: begin
                    if (!row_active[SDRAM_BA]) complain("WRITE with no row activated");
                    else begin
                        // DQM is an active-high byte mask
                        if (!SDRAM_DQM[0]) mem[flat_addr(SDRAM_BA, active_row[SDRAM_BA], SDRAM_A[COL_WIDTH-1:0])][7:0]   = SDRAM_DQ[7:0];
                        if (!SDRAM_DQM[1]) mem[flat_addr(SDRAM_BA, active_row[SDRAM_BA], SDRAM_A[COL_WIDTH-1:0])][15:8]  = SDRAM_DQ[15:8];
                        if (!SDRAM_DQM[2]) mem[flat_addr(SDRAM_BA, active_row[SDRAM_BA], SDRAM_A[COL_WIDTH-1:0])][23:16] = SDRAM_DQ[23:16];
                        if (!SDRAM_DQM[3]) mem[flat_addr(SDRAM_BA, active_row[SDRAM_BA], SDRAM_A[COL_WIDTH-1:0])][31:24] = SDRAM_DQ[31:24];
                        if (SDRAM_DQM == 4'b1111)
                            complain("WRITE with every byte masked off");
                        writes = writes + 1;
                    end
                    if (SDRAM_A[10]) row_active[SDRAM_BA] = 1'b0;   // auto precharge
                end

                CMD_READ: begin
                    if (!row_active[SDRAM_BA]) complain("READ with no row activated");
                    else begin
                        rd_pipe_data[CAS_LATENCY] =
                            mem[flat_addr(SDRAM_BA, active_row[SDRAM_BA], SDRAM_A[COL_WIDTH-1:0])];
                        rd_pipe_valid[CAS_LATENCY] = 1'b1;
                        reads = reads + 1;
                    end
                    if (SDRAM_A[10]) row_active[SDRAM_BA] = 1'b0;   // auto precharge
                end

                default: ;   // NOP, burst terminate
            endcase
        end

        // Advance the read pipeline
        dq_driving = rd_pipe_valid[0];
        dq_drive   = rd_pipe_data[0];
        for (i = 0; i < 7; i = i + 1) begin
            rd_pipe_valid[i] = rd_pipe_valid[i+1];
            rd_pipe_data[i]  = rd_pipe_data[i+1];
        end
        rd_pipe_valid[7] = 1'b0;

        // Retention watchdog
        if (configured && ($realtime - last_refresh_ns) > REFRESH_LIMIT_NS) begin
            complain("refresh interval exceeded, real hardware would lose data");
            last_refresh_ns = $realtime;   // report once per window
        end
    end

    task report;
        begin
            $display("SDRAM model: %0d reads, %0d writes, %0d refreshes, %0d errors",
                     reads, writes, refreshes, errors);
        end
    endtask

endmodule
