`include "definitions.vh"

// =============================================================================
// Instruction memory for the fetch port.
//
// Combinational (asynchronous) read: pc_gen already registers the address and
// if_id_reg registers the instruction, so adding a third register here would
// make the instruction arrive one cycle after its own PC. That off-by-one was
// present in the first draft, together with an "output wire" being driven from
// a clocked block.
//
// Backing store is a byte array so it can be loaded directly from the output of
// `objcopy -O verilog`, which emits one byte per record.
// =============================================================================
module instruction_rom #(
    parameter ROM_BYTES = `INSTRUCTION_ROM_SIZE,
    parameter INIT_FILE = ""
)(
    input  wire [`BUS_WIDTH-1:0] addr,
    output wire [`BUS_WIDTH-1:0] instruction
);

    localparam ADDR_BITS = $clog2(ROM_BYTES);

    reg [7:0] mem [0:ROM_BYTES-1];

    integer i;
    initial begin
        for (i = 0; i < ROM_BYTES; i = i + 1)
            mem[i] = 8'h00;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // Word-aligned byte index, truncated to the physical size of the array
    wire [ADDR_BITS-1:0] base = {addr[ADDR_BITS-1:2], 2'b00};
    wire                 in_range = (addr < ROM_BYTES);

    // Little-endian assembly of the 32-bit instruction word
    assign instruction = in_range ? {mem[base+3], mem[base+2], mem[base+1], mem[base]}
                                  : {`BUS_WIDTH{1'b0}};  // reads as an illegal instruction

endmodule
