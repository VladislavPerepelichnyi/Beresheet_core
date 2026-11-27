`include "definitions.vh"

// =============================================================================
// Sequential 32-bit divider, one quotient bit per cycle.
//
// Restoring division on magnitudes: the dividend is shifted through the
// remainder register, and each cycle the remainder either keeps or drops a
// subtraction of the divisor. The shifted intermediate needs 33 bits, because
// 2*rem + 1 can exceed 32 bits, but the value that gets stored is always below
// the divisor and so always fits in 32. Signs are stripped on entry and
// reapplied on exit, following the spec: the quotient is negative when the
// operand signs differ, and a non-zero remainder always carries the sign of the
// dividend.
//
// The two special cases from Table 11 of the ISA manual bypass the loop and
// finish in a single cycle:
//   divide by zero      quotient = all ones, remainder = dividend
//   signed overflow     -2^31 / -1: quotient = -2^31 (the dividend), rem = 0
//
// div and rem are rare in real code - the Linux profile in instructions.md has
// them three orders of magnitude below mul - so one bit per cycle is the right
// area trade here. Latency: 34 cycles normally, 1 cycle for a special case.
// =============================================================================
module div_unit (
    input  wire clk,
    input  wire rst,

    input  wire        start,
    input  wire        is_signed,     // DIV / REM rather than DIVU / REMU
    input  wire        want_rem,      // return the remainder rather than the quotient
    input  wire [`BUS_WIDTH-1:0] a,   // dividend
    input  wire [`BUS_WIDTH-1:0] b,   // divisor

    output reg  [`BUS_WIDTH-1:0] result,
    output reg                   done
);

    localparam ST_IDLE   = 2'd0;
    localparam ST_DIVIDE = 2'd1;
    localparam ST_FINISH = 2'd2;

    reg [1:0]  state;
    reg [5:0]  bits_left;

    reg [31:0] rem;                   // always < divisor, so 32 bits suffice
    reg [31:0] quo;                   // dividend on entry, quotient on exit
    reg [31:0] divisor_mag;
    reg        quo_negate, rem_negate;
    reg        want_rem_q;

    // --- Operand classification, combinational on the incoming request ------
    wire a_neg = is_signed & a[`BUS_WIDTH-1];
    wire b_neg = is_signed & b[`BUS_WIDTH-1];

    wire [31:0] a_mag = a_neg ? (~a + 32'd1) : a;
    wire [31:0] b_mag = b_neg ? (~b + 32'd1) : b;

    wire div_by_zero = (b == 32'd0);
    wire overflow    = is_signed && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);

    // --- One restoring-division step ---------------------------------------
    // The comparison needs all 33 bits, the result never does. When the divisor
    // fits, the true difference is below the divisor and so below 2**32, so the
    // low 32 bits of the subtraction are the whole answer; when it does not fit,
    // rem_shifted is itself below the divisor and bit 32 is already zero.
    wire [32:0] rem_shifted = {rem, quo[31]};
    wire        step_fits   = (rem_shifted >= {1'b0, divisor_mag});
    wire [31:0] rem_next    = step_fits ? (rem_shifted[31:0] - divisor_mag)
                                        : rem_shifted[31:0];

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state  <= ST_IDLE;
            done   <= 1'b0;
            result <= 32'd0;
        end
        else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        if (div_by_zero) begin
                            // quotient all ones, remainder is the dividend
                            result <= want_rem ? a : 32'hFFFF_FFFF;
                            done   <= 1'b1;
                        end
                        else if (overflow) begin
                            result <= want_rem ? 32'd0 : 32'h8000_0000;
                            done   <= 1'b1;
                        end
                        else begin
                            rem         <= 32'd0;
                            quo         <= a_mag;
                            divisor_mag <= b_mag;
                            quo_negate  <= a_neg ^ b_neg;
                            rem_negate  <= a_neg;
                            want_rem_q  <= want_rem;
                            bits_left   <= 6'd32;
                            state       <= ST_DIVIDE;
                        end
                    end
                end

                ST_DIVIDE: begin
                    rem       <= rem_next;
                    quo       <= {quo[30:0], step_fits};
                    bits_left <= bits_left - 6'd1;
                    if (bits_left == 6'd1)
                        state <= ST_FINISH;
                end

                ST_FINISH: begin
                    if (want_rem_q)
                        result <= rem_negate ? (~rem + 32'd1) : rem;
                    else
                        result <= quo_negate ? (~quo + 32'd1) : quo;
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
