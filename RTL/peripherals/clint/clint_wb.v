`include "wb_defines.vh"

// =============================================================================
// CLINT - Core Local Interruptor. A Wishbone slave.
//
// Memory mapped, not CSRs, and that is not an implementation preference: the
// RISC-V ACLINT specification (doc/riscv-aclint/) defines MSIP, MTIMECMP and
// MTIME as memory-mapped registers, and there is deliberately no `mtime` CSR at
// all. OpenSBI's timer driver writes MTIMECMP through an address it learns from
// the device tree, so anything else is unreachable by real firmware.
//
// The register offsets below are fixed by that spec and are what every existing
// driver expects. The base address is ours to choose, because it comes from the
// device tree.
//
//   +0x0000  MSIP0      software interrupt for hart 0, bit 0 only
//   +0x4000  MTIMECMP0  64-bit compare, low word then high word
//   +0xBFF8  MTIME      64-bit monotonic counter, low word then high word
//
// Two outputs go to the core as interrupt pins:
//   msip  -> mip.MSIP    set directly by software writing MSIP0
//   mtip  -> mip.MTIP    set while mtime >= mtimecmp
//
// mtip is a *comparison*, not a latch, which is why mip.MTIP is read-only in the
// core: the only way to clear a timer interrupt is to move mtimecmp forward.
// That is the whole protocol, and it is why a handler that forgets to write
// mtimecmp re-enters immediately.
// =============================================================================
module clint_wb #(
    // mtime is specified as a fixed-frequency counter, independent of the CPU
    // clock. Dividing the core clock is the usual way to get one on a small SoC.
    // At 24 MHz a divider of 24 gives a 1 MHz tick, so mtime counts whole
    // microseconds - which is what the device tree's timebase-frequency claims,
    // and the reason 24 MHz was chosen over 23.625 when the clock came down.
    parameter CPU_HZ    = `SOC_CLK_HZ,
    parameter TICK_HZ   = 1_000_000,
    parameter DIVIDER   = CPU_HZ / TICK_HZ
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
    output wire [63:0] mtime_o         // to the core's `time` CSR
);

    localparam OFF_MSIP     = 16'h0000;
    localparam OFF_MTIMECMP = 16'h4000;
    localparam OFF_MTIME    = 16'hBFF8;

    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg        msip_r;

    // Prescaler, so mtime ticks at a fixed rate rather than at the CPU clock.
    localparam DIV_W = 16;
    reg [DIV_W-1:0] divider;
    wire            tick = (divider == DIVIDER[DIV_W-1:0] - 1);

    assign msip    = msip_r;
    assign mtime_o = mtime;

    // Unsigned compare across the full 64 bits. A firmware that sets mtimecmp
    // to all-ones is asking for "never", and this gives it that.
    assign mtip = (mtime >= mtimecmp);

    wire [15:0] off = wb_adr_i[15:0];
    wire        sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mtime    <= 64'd0;
            // All ones means "no timer interrupt pending", which is the right
            // state to come out of reset in: mtip would otherwise be asserted
            // from cycle one, before any handler exists.
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
                        OFF_MSIP:         msip_r            <= wb_dat_i[0];
                        OFF_MTIMECMP:     mtimecmp[31:0]    <= wb_dat_i;
                        OFF_MTIMECMP + 4: mtimecmp[63:32]   <= wb_dat_i;
                        // mtime is writable so firmware can zero the time base
                        OFF_MTIME:        mtime[31:0]       <= wb_dat_i;
                        OFF_MTIME + 4:    mtime[63:32]      <= wb_dat_i;
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

    /* verilator lint_off UNUSEDSIGNAL */
    // Byte-granular access to these registers is not meaningful, so SEL is
    // accepted and ignored; every access is a whole word.
    wire unused_sel = |wb_sel_i;
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
