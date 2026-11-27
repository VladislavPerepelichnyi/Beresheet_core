`include "wb_defines.vh"

// =============================================================================
// Wishbone slave wrapping a byte-writable block RAM; used as the boot memory.
//
// ACK and read data are registered on the same edge, one cycle after STB.
// Byte lanes are written directly from SEL. INIT_FILE is a word-oriented hex
// image (one 32-bit word per line, scripts/translate_bin_to_vmem.py), so the same
// file initialises the simulation memory and the synthesised block RAM.
// =============================================================================
module wb_ram #(
    parameter MEM_BYTES = `BOOT_RAM_BYTES,
    parameter INIT_FILE = ""
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
    output reg                       wb_ack_o
);

    localparam WORDS     = MEM_BYTES / 4;
    localparam IDX_WIDTH = $clog2(WORDS);

    // A single word array with byte-slice writes, the form that synthesis
    // tools (Gowin, Vivado) infer as byte-enabled block RAM.
    reg [31:0] mem [0:WORDS-1];

    wire [IDX_WIDTH-1:0] idx = wb_adr_i[IDX_WIDTH+1:2];

    // Masking with ACK gives one response per STB even when a master holds
    // STB across consecutive transfers.
    wire sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    // $readmemh only: the image is padded to full depth, and synthesis tools
    // will not unroll a zeroing loop this long.
    initial begin
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            wb_ack_o <= 1'b0;
            wb_dat_o <= {`WB_DATA_WIDTH{1'b0}};
        end
        else begin
            wb_ack_o <= sel;

            if (sel) begin
                if (wb_we_i) begin
                    if (wb_sel_i[0]) mem[idx][7:0]   <= wb_dat_i[7:0];
                    if (wb_sel_i[1]) mem[idx][15:8]  <= wb_dat_i[15:8];
                    if (wb_sel_i[2]) mem[idx][23:16] <= wb_dat_i[23:16];
                    if (wb_sel_i[3]) mem[idx][31:24] <= wb_dat_i[31:24];
                end
                // Read-first; a write returns the old word, which is ignored
                wb_dat_o <= mem[idx];
            end
        end
    end

    // The region is decoded upstream; bits 1:0 are always zero
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_adr = |{wb_adr_i[`WB_ADDR_WIDTH-1:IDX_WIDTH+2], wb_adr_i[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
