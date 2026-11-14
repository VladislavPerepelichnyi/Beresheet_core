// =============================================================================
// Generic true dual-port RAM model.
//
// Not used by the RV32I testbench, which drives the split memories in soc_sim
// directly. It is kept as the behavioural model for the block RAM that the
// memory bus and the L1 caches will sit on (roadmap stages 3 and 12).
//
// Both ports are read-first: the read returns the value held before the write
// on the same edge, which is what an FPGA block RAM in READ_FIRST mode does.
// =============================================================================
module dual_port_ram #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 6,                      // depth = 2**ADDR_WIDTH
    parameter INIT_FILE  = ""
)(
    input  wire                  clk,

    // Port A
    input  wire                  we_a,
    input  wire [ADDR_WIDTH-1:0] addr_a,
    input  wire [DATA_WIDTH-1:0] din_a,
    output reg  [DATA_WIDTH-1:0] dout_a,

    // Port B
    input  wire                  we_b,
    input  wire [ADDR_WIDTH-1:0] addr_b,
    input  wire [DATA_WIDTH-1:0] din_b,
    output reg  [DATA_WIDTH-1:0] dout_b
);

    localparam RAM_DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] ram [0:RAM_DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < RAM_DEPTH; i = i + 1)
            ram[i] = {DATA_WIDTH{1'b0}};
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, ram);
    end

    always @(posedge clk) begin
        dout_a <= ram[addr_a];
        if (we_a) ram[addr_a] <= din_a;
    end

    always @(posedge clk) begin
        dout_b <= ram[addr_b];
        if (we_b) ram[addr_b] <= din_b;
    end

endmodule
