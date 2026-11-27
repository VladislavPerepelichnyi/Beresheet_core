`include "definitions.vh"

// =============================================================================
// RV32M execution unit: decodes funct3, drives the multiplier or the divider,
// and presents one stall/result handshake to the Decode/Execute stage.
//
// Protocol
//   `req`   is held high for as long as the M instruction sits in stage 2.
//   `stall` is high from the cycle the request appears until the cycle the
//           result is ready, so the control unit freezes the front of the
//           pipeline and keeps the instruction in place.
//   On the cycle `stall` falls, `result` is valid and the instruction advances
//           through the normal ALU-result path.
//
// funct3 encoding (RV32M). Bit 2 separates multiply from divide.
//   000 MUL     001 MULH    010 MULHSU  011 MULHU
//   100 DIV     101 DIVU    110 REM     111 REMU
// =============================================================================
module muldiv (
    input  wire clk,
    input  wire rst,

    input  wire                  req,
    input  wire [2:0]            funct3,
    input  wire [`BUS_WIDTH-1:0] rs1_data,
    input  wire [`BUS_WIDTH-1:0] rs2_data,

    // Higher-priority pipeline stall. Gates both ends of the operation:
    //  * the start, because operands must be final before they are latched
    //    (a load ahead still waiting on the bus has not written back yet);
    //  * the finish, so the result cycle is not lost while something else
    //    holds the instruction in Decode/Execute.
    input  wire                  hold,

    output wire                  stall,
    output wire [`BUS_WIDTH-1:0] result
);

    localparam ST_IDLE = 2'd0;
    localparam ST_BUSY = 2'd1;
    localparam ST_DONE = 2'd2;

    reg [1:0]             state;
    reg [`BUS_WIDTH-1:0]  result_q;

    // --- funct3 decode ------------------------------------------------------
    wire is_div = funct3[2];

    // MUL and MULH treat both operands as signed; MULHSU only rs1; MULHU neither
    wire mul_a_signed = (funct3 == `F3_MUL) || (funct3 == `F3_MULH) ||
                        (funct3 == `F3_MULHSU);
    wire mul_b_signed = (funct3 == `F3_MUL) || (funct3 == `F3_MULH);
    wire mul_high     = (funct3 != `F3_MUL);

    wire div_signed   = (funct3 == `F3_DIV) || (funct3 == `F3_REM);
    wire div_want_rem = (funct3 == `F3_REM) || (funct3 == `F3_REMU);

    // One start pulse, on the first cycle the request is seen unheld
    wire start     = (state == ST_IDLE) && req && !hold;
    wire start_mul = start && !is_div;
    wire start_div = start &&  is_div;

    wire [`BUS_WIDTH-1:0] mul_result, div_result;
    wire                  mul_done,   div_done;

    mul_unit mul_inst (
        .clk       (clk),
        .rst       (rst),
        .start     (start_mul),
        .a_signed  (mul_a_signed),
        .b_signed  (mul_b_signed),
        .take_high (mul_high),
        .a         (rs1_data),
        .b         (rs2_data),
        .result    (mul_result),
        .done      (mul_done)
    );

    div_unit div_inst (
        .clk       (clk),
        .rst       (rst),
        .start     (start_div),
        .is_signed (div_signed),
        .want_rem  (div_want_rem),
        .a         (rs1_data),
        .b         (rs2_data),
        .result    (div_result),
        .done      (div_done)
    );

    wire sub_done = mul_done | div_done;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state    <= ST_IDLE;
            result_q <= {`BUS_WIDTH{1'b0}};
        end
        else begin
            case (state)
                // Advance on `start`, not on `req`, so the state never moves
                // without the sub-unit having been started.
                ST_IDLE: if (start) state <= ST_BUSY;

                ST_BUSY: if (sub_done) begin
                    result_q <= mul_done ? mul_result : div_result;
                    state    <= ST_DONE;
                end

                // `stall` is low in ST_DONE, so the instruction leaves stage 2.
                // The state is held while another stall keeps it in place.
                ST_DONE: if (!hold) state <= ST_IDLE;

                default: state <= ST_IDLE;
            endcase
        end
    end

    assign stall  = req & (state != ST_DONE);
    assign result = result_q;

endmodule
