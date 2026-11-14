`include "wb_defines.vh"

// =============================================================================
// Wishbone slave wrapping a block RAM. Used as the boot memory holding the
// BIOS, and as a stand-in for SDRAM in simulation.
//
// Single cycle: ACK is asserted on the same edge the data appears, so a hit
// costs the master nothing beyond the bus handshake itself. That means ACK must
// be registered off STB, and read data must be registered from the same edge,
// so the two line up.
//
// Byte strobes come straight from SEL, so byte and halfword stores work without
// a read-modify-write.
//
// INIT_FILE is a word-oriented image, one 32-bit hex value per line, produced by
// scripts/bin_to_wordhex.py. That form is what lets the same module be both the
// simulation memory and a synthesis-initialised block RAM holding the BIOS.
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

    // One 32-bit array with byte-slice writes. Gowin, Vivado and Verilator all
    // infer a byte-write-enabled block RAM from this shape, and it can be
    // initialised from a single word-oriented $readmemh image - which four
    // separate byte-lane arrays cannot.
    reg [31:0] mem [0:WORDS-1];

    wire [IDX_WIDTH-1:0] idx = wb_adr_i[IDX_WIDTH+1:2];

    // One access per ACK: withholding sel while ACK is high guarantees a single
    // response per strobe even when a master holds STB continuously, as the
    // instruction fetch port does.
    wire sel = wb_stb_i & wb_cyc_i & ~wb_ack_o;

    // $readmemh is the only initialiser, and the image is padded to the full
    // depth by scripts/bin_to_wordhex.py. An explicit zeroing loop would be
    // nicer to read but synthesis will not unroll it: Gowin caps loops at 2000
    // iterations and this memory is 8192 words deep.
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
                // Read-first: a write returns the old contents, which the
                // master ignores. Keeps this inferrable as a block RAM.
                wb_dat_o <= mem[idx];
            end
        end
    end

endmodule
