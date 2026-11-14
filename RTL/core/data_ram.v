`include "definitions.vh"

// =============================================================================
// Data memory for the load/store port.
//
// Byte-strobed writes on the clock edge, combinational reads. Single-cycle, so
// `ready` is tied high; when a real bus or cache replaces this module it lowers
// `ready` and the control unit's existing stall path takes over.
//
// The first draft stored a 32-bit value into an 8-bit array element, had no byte
// strobes, no load/store width handling, and was missing `endmodule`.
// =============================================================================
module data_ram #(
    parameter RAM_BYTES = `DATA_RAM_SIZE,
    parameter INIT_FILE = ""
)(
    input  wire clk,

    input  wire [`BUS_WIDTH-1:0] addr,          // word aligned
    input  wire [`BUS_WIDTH-1:0] wdata,         // already in its byte lane
    input  wire [3:0]            wstrb,
    input  wire                  we,
    input  wire                  re,
    output wire [`BUS_WIDTH-1:0] rdata,
    output wire                  ready
);

    localparam ADDR_BITS = $clog2(RAM_BYTES);

    reg [7:0] mem [0:RAM_BYTES-1];

    integer i;
    initial begin
        for (i = 0; i < RAM_BYTES; i = i + 1)
            mem[i] = 8'h00;
        // Loading the program image here too makes .rodata and initialised
        // .data readable by loads.
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    wire [ADDR_BITS-1:0] base     = {addr[ADDR_BITS-1:2], 2'b00};
    wire                 in_range = (addr < RAM_BYTES);

    assign rdata = (re && in_range) ? {mem[base+3], mem[base+2], mem[base+1], mem[base]}
                                    : {`BUS_WIDTH{1'b0}};
    assign ready = 1'b1;

    always @(posedge clk) begin
        if (we && in_range) begin
            if (wstrb[0]) mem[base]   <= wdata[7:0];
            if (wstrb[1]) mem[base+1] <= wdata[15:8];
            if (wstrb[2]) mem[base+2] <= wdata[23:16];
            if (wstrb[3]) mem[base+3] <= wdata[31:24];
        end
    end

endmodule
