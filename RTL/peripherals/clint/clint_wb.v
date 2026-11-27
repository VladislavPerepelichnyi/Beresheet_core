`include "wb_defines.vh"

// =============================================================================
// CLINT (Core-Local Interruptor), Wishbone slave, one hart.
//
// Register layout per the RISC-V ACLINT specification (MSWI + MTIMER), which
// is what OpenSBI and Linux drivers expect:
//
//   +0x0000  MSIP0      bit 0 drives mip.MSIP
//   +0x4000  MTIMECMP0  64-bit, low word at +0, high word at +4
//   +0xBFF8  MTIME      64-bit, low word at +0, high word at +4
//
// mtip is the comparison mtime >= mtimecmp, not a latch: software clears the
// timer interrupt by moving mtimecmp forward. mtime ticks at TICK_HZ from a
// prescaler on the system clock and also feeds the core's `time` CSR.
// =============================================================================
module clint_wb #(
    parameter CPU_HZ  = `SOC_CLK_HZ,
    parameter TICK_HZ = 1_000_000,          // device tree timebase-frequency
    parameter DIVIDER = CPU_HZ / TICK_HZ    // must divide exactly
)(
    input  wire clk,
    input  wire rst,

    input  wire [`WB_ADDR_WIDTH-1:0] wb_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] wb_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  wb_sel_i,
    input  wire                      wb_we_i,
    input  wire                      wb_stb_i,
    input  wire                      wb_cyc_i,
    output reg  [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output reg                       wb_ack_o,

    output wire        msip,           // to mip.MSIP
    output wire        mtip,           // to mip.MTIP
    output wire [63:0] mtime_o         // to the `time` CSR
);

    localparam OFF_MSIP     = 16'h0000;
    localparam OFF_MTIMECMP = 16'h4000;
    localparam OFF_MTIME    = 16'hBFF8;

    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg        msip_r;

    localparam DIV_W = 16;
    reg [DIV_W-1:0] divider;
    wire            tick = (divider == DIVIDER[DIV_W-1:0] - 1);

    assign msip    = msip_r;
    assign mtime_o = mtime;
    assign mtip    = (mtime >= mtimecmp);   // unsigned, full 64 bits

    wire [15:0] off = wb_adr_i[15:0];
    wire        sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mtime    <= 64'd0;
            // All ones: no timer interrupt until software programs one
            mtimecmp <= {64{1'b1}};
            msip_r   <= 1'b0;
            divider  <= {DIV_W{1'b0}};
            wb_ack_o <= 1'b0;
            wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
        end
        else begin
            // --- time base ---
            if (tick) begin
                divider <= {DIV_W{1'b0}};
                mtime   <= mtime + 64'd1;
            end
            else begin
                divider <= divider + {{(DIV_W-1){1'b0}}, 1'b1};
            end

            // --- bus ---
            wb_ack_o <= sel;

            if (sel) begin
                if (wb_we_i) begin
                    case (off)
                        OFF_MSIP:         msip_r          <= wb_dat_i[0];
                        OFF_MTIMECMP:     mtimecmp[31:0]  <= wb_dat_i;
                        OFF_MTIMECMP + 4: mtimecmp[63:32] <= wb_dat_i;
                        OFF_MTIME:        mtime[31:0]     <= wb_dat_i;
                        OFF_MTIME + 4:    mtime[63:32]    <= wb_dat_i;
                        default: ;
                    endcase
                end

                case (off)
                    OFF_MSIP:         wb_dat_o <= {31'd0, msip_r};
                    OFF_MTIMECMP:     wb_dat_o <= mtimecmp[31:0];
                    OFF_MTIMECMP + 4: wb_dat_o <= mtimecmp[63:32];
                    OFF_MTIME:        wb_dat_o <= mtime[31:0];
                    OFF_MTIME + 4:    wb_dat_o <= mtime[63:32];
                    default:          wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
                endcase
            end
        end
    end

    // Registers are accessed as whole words; the region is decoded upstream.
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_sel = |wb_sel_i;
    wire unused_adr = |wb_adr_i[31:16];
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
