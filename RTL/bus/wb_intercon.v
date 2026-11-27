`include "wb_defines.vh"

// =============================================================================
// Wishbone interconnect: address decoder, return multiplexer and error slave.
//
// Address, write data, WE, SEL and CYC are broadcast to every slave; only STB
// is decoded, on addr[31:24] (see the map in wb_defines.vh). The selected
// slave's DAT/ACK are returned to the master.
//
// The spec requires a response to every STB (2.2.3), so an address that
// matches no region is routed to an internal error slave that asserts ERR for
// one cycle. Adding a slave means one strobe and one return-mux term here.
// =============================================================================
module wb_intercon (
    input  wire clk,
    input  wire rst,

    // --- From the arbiter ---
    input  wire [`WB_ADDR_WIDTH-1:0] m_adr_i,
    input  wire [`WB_DATA_WIDTH-1:0] m_dat_i,
    input  wire [`WB_SEL_WIDTH-1:0]  m_sel_i,
    input  wire                      m_we_i,
    input  wire                      m_stb_i,
    input  wire                      m_cyc_i,
    output wire [`WB_DATA_WIDTH-1:0] m_dat_o,
    output wire                      m_ack_o,
    output wire                      m_err_o,

    // --- Broadcast to all slaves ---
    output wire [`WB_ADDR_WIDTH-1:0] s_adr_o,
    output wire [`WB_DATA_WIDTH-1:0] s_dat_o,
    output wire [`WB_SEL_WIDTH-1:0]  s_sel_o,
    output wire                      s_we_o,
    output wire                      s_cyc_o,

    // --- Per-slave strobe and response ---
    output wire                      boot_stb_o,
    input  wire [`WB_DATA_WIDTH-1:0] boot_dat_i,
    input  wire                      boot_ack_i,

    output wire                      uart_stb_o,
    input  wire [`WB_DATA_WIDTH-1:0] uart_dat_i,
    input  wire                      uart_ack_i,

    output wire                      sdram_stb_o,
    input  wire [`WB_DATA_WIDTH-1:0] sdram_dat_i,
    input  wire                      sdram_ack_i,

    output wire                      clint_stb_o,
    input  wire [`WB_DATA_WIDTH-1:0] clint_dat_i,
    input  wire                      clint_ack_i,

    output wire                      led_stb_o,
    input  wire [`WB_DATA_WIDTH-1:0] led_dat_i,
    input  wire                      led_ack_i,

    output wire                      sd_stb_o,
    input  wire [`WB_DATA_WIDTH-1:0] sd_dat_i,
    input  wire                      sd_ack_i,

    output wire                      plic_stb_o,
    input  wire [`WB_DATA_WIDTH-1:0] plic_dat_i,
    input  wire                      plic_ack_i,

    output wire                      decode_miss    // STB to an unmapped address
);

    // ------------------------------------------------------------------------
    // Broadcast
    // ------------------------------------------------------------------------
    assign s_adr_o = m_adr_i;
    assign s_dat_o = m_dat_i;
    assign s_sel_o = m_sel_i;
    assign s_we_o  = m_we_i;
    assign s_cyc_o = m_cyc_i;

    // ------------------------------------------------------------------------
    // Decode: at most one strobe
    // ------------------------------------------------------------------------
    wire [7:0] region = `REGION_SEL(m_adr_i);

    wire sel_boot  = (region == `REGION_BOOT);
    wire sel_clint = (region == `REGION_CLINT);
    wire sel_plic  = (region == `REGION_PLIC);
    wire sel_sd    = (region == `REGION_SD);
    wire sel_uart  = (region == `REGION_UART);
    wire sel_led   = (region == `REGION_LED);
    wire sel_sdram = (region == `REGION_SDRAM);
    wire sel_none  = ~(sel_boot | sel_clint | sel_plic | sel_uart |
                       sel_led  | sel_sd    | sel_sdram);

    assign boot_stb_o  = m_stb_i & sel_boot;
    assign clint_stb_o = m_stb_i & sel_clint;
    assign plic_stb_o  = m_stb_i & sel_plic;
    assign sd_stb_o    = m_stb_i & sel_sd;
    assign uart_stb_o  = m_stb_i & sel_uart;
    assign led_stb_o   = m_stb_i & sel_led;
    assign sdram_stb_o = m_stb_i & sel_sdram;

    assign decode_miss = m_stb_i & sel_none;

    // ------------------------------------------------------------------------
    // Error slave: one-cycle ERR for an unmapped access
    // ------------------------------------------------------------------------
    reg err_ack;
    always @(posedge clk or posedge rst) begin
        if (rst) err_ack <= 1'b0;
        else     err_ack <= decode_miss & ~err_ack;
    end

    // ------------------------------------------------------------------------
    // Return mux
    // ------------------------------------------------------------------------
    assign m_dat_o = sel_boot  ? boot_dat_i  :
                     sel_clint ? clint_dat_i :
                     sel_plic  ? plic_dat_i  :
                     sel_uart  ? uart_dat_i  :
                     sel_led   ? led_dat_i   :
                     sel_sd    ? sd_dat_i    :
                     sel_sdram ? sdram_dat_i : {`WB_DATA_WIDTH{1'b0}};

    assign m_ack_o = (sel_boot  & boot_ack_i)  |
                     (sel_clint & clint_ack_i) |
                     (sel_plic  & plic_ack_i)  |
                     (sel_uart  & uart_ack_i)  |
                     (sel_led   & led_ack_i)   |
                     (sel_sd    & sd_ack_i)    |
                     (sel_sdram & sdram_ack_i);

    assign m_err_o = err_ack;

endmodule
