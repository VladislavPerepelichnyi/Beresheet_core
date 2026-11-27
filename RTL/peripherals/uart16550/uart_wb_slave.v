`include "wb_defines.vh"

// =============================================================================
// Wishbone slave wrapper around the OpenCores uart16550.
//
// The UART is already a Wishbone slave, so this only ties off the modem
// handshake pins we have no wires for and narrows the address.
//
// Register addressing: the core runs in 32-bit mode, where uart_wb.v takes the
// low two bits of the register index from *which byte lane SEL selects*, not
// from the address. Combined with LITLE_ENDIAN (see this directory's README)
// that means a byte access at UART_BASE + N reaches register N:
//
//   +0  RBR / THR   read data / write data      (DLL when DLAB=1)
//   +1  IER         interrupt enable            (DLM when DLAB=1)
//   +2  IIR / FCR   interrupt id / FIFO control
//   +3  LCR         line control, bit 7 = DLAB
//   +4  MCR         modem control
//   +5  LSR         line status: bit 0 RX ready, bit 5 THR empty
//   +6  MSR         modem status
//   +7  SCR         scratch
//
// So firmware uses lb/sb, which is what a 16550 driver expects anyway.
// =============================================================================
module uart_wb_slave (
    input  wire clk,
    input  wire rst,

    input  wire [`WB_ADDR_WIDTH-1:0] wb_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] wb_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  wb_sel_i,
    input  wire                      wb_we_i,
    input  wire                      wb_stb_i,
    input  wire                      wb_cyc_i,
    output wire [`WB_DATA_WIDTH-1:0] wb_dat_o,
    output wire                      wb_ack_o,

    output wire                      irq,        // level, to PLIC source 1
    output wire                      uart_tx,
    input  wire                      uart_rx
);

    uart_top uart_i (
        .wb_clk_i   (clk),
        .wb_rst_i   (rst),
        .wb_adr_i   (wb_adr_i[4:0]),
        .wb_dat_i   (wb_dat_i),
        .wb_dat_o   (wb_dat_o),
        .wb_we_i    (wb_we_i),
        .wb_stb_i   (wb_stb_i),
        .wb_cyc_i   (wb_cyc_i),
        .wb_sel_i   (wb_sel_i),
        .wb_ack_o   (wb_ack_o),
        .int_o      (irq),

        .stx_pad_o  (uart_tx),
        .srx_pad_i  (uart_rx),

        // No modem wiring on this board. CTS and DSR are active low in the
        // 16550, so tying them low asserts "ready" and the transmitter never
        // waits on flow control.
        .rts_pad_o  (),
        .cts_pad_i  (1'b0),
        .dtr_pad_o  (),
        .dsr_pad_i  (1'b0),
        .ri_pad_i   (1'b1),      // no ring indicator
        .dcd_pad_i  (1'b0)       // carrier present
    );

endmodule
