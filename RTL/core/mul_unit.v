`include "definitions.vh"

// =============================================================================
// 32x32 -> 64 multiplier, two register stages.
//
// All four RV32M multiply variants come out of a single signed 33x33 multiply:
// each operand is widened to 33 bits, sign-extended for the signed variants and
// zero-extended for the unsigned ones. The low 64 bits of that product are then
// the correct two's-complement result in every case, including MULHSU - the
// worst-case signed-by-unsigned product is -2^31 * (2^32-1), which still fits in
// a signed 64-bit value.
//
// The two stages exist for timing, not for throughput: stage A registers the
// widened operands and stage B registers the product, which is exactly the
// input-register / output-register arrangement a DSP48-style block wants. On a
// target without hard multipliers this infers a combinational array multiplier
// between the two registers; if that array is too large, swap this module for a
// sequential shift-add version - the handshake is what muldiv.v depends on, not
// the internals.
//
// Latency: `done` rises 2 cycles after `start`.
// =============================================================================
module mul_unit (
    input  wire clk,
    input  wire rst,

    input  wire        start,
    input  wire        a_signed,      // treat rs1 as signed
    input  wire        b_signed,      // treat rs2 as signed
    input  wire        take_high,     // return the upper 32 bits
    input  wire [`BUS_WIDTH-1:0] a,
    input  wire [`BUS_WIDTH-1:0] b,

    output wire [`BUS_WIDTH-1:0] result,
    output wire                  done
);

    // Widen to 33 bits according to the signedness of each operand
    wire signed [32:0] a_wide = {a_signed & a[`BUS_WIDTH-1], a};
    wire signed [32:0] b_wide = {b_signed & b[`BUS_WIDTH-1], b};

    reg signed [32:0] a_q, b_q;
    reg               high_q;
    reg  [63:0]       product_q;
    reg  [1:0]        valid_q;         // shift register: stage A, stage B

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_q       <= 33'sd0;
            b_q       <= 33'sd0;
            high_q    <= 1'b0;
            product_q <= 64'd0;
            valid_q   <= 2'b00;
        end
        else begin
            // Stage A: capture the operands
            if (start) begin
                a_q    <= a_wide;
                b_q    <= b_wide;
                high_q <= take_high;
            end

            // Stage B: multiply and register the product
            if (valid_q[0])
                product_q <= a_q * b_q;

            valid_q <= {valid_q[0], start};
        end
    end

    assign done   = valid_q[1];
    assign result = high_q ? product_q[63:32] : product_q[31:0];

endmodule
