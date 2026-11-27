// =============================================================================
// An SD card in SPI mode, enough of one to boot from.
//
// Simulation only. It exists because the alternative is bringing up an SPI
// bus, a card protocol, and a filesystem parser at the same time on hardware
// with no visibility into any of them. Here the card is deterministic and the
// image is known, so a wrong byte is attributable.
//
// What it implements, which is the subset a boot loader uses:
//
//   CMD0   GO_IDLE_STATE     -> R1 = idle
//   CMD8   SEND_IF_COND      -> R7, echoing the check pattern back
//   CMD55  APP_CMD           -> R1, and arms the next command as an ACMD
//   CMD41  SD_SEND_OP_COND   -> R1, idle for the first few calls and then
//                               ready, so the host's polling loop is exercised
//                               rather than satisfied on the first try
//   CMD58  READ_OCR          -> R3 with CCS set: a high-capacity card, so the
//                               host must address it in blocks
//   CMD17  READ_SINGLE_BLOCK -> R1, then the 0xFE token and 512 bytes
//
// Anything else answers "illegal command", which is what a real card does and
// what the controller's error path expects.
//
// The image is sparse: the two hex files list only the sectors that are not
// all zeroes, which for a freshly made FAT32 volume is about ten of them. Any
// sector not in the list reads back as zeroes, exactly as a blank card would.
// =============================================================================
`timescale 1ns/1ps

module sd_model #(
    parameter SD_SECTORS = 64,          // sparse image capacity, in sectors
    parameter LBA_FILE   = "build/sd/sd_lba.hex",
    parameter DAT_FILE   = "build/sd/sd_dat.hex",
    parameter ACMD41_TRIES = 3          // times to answer "still busy"
)(
    input  wire clk,                    // the SoC clock, used only to sample
    input  wire cs_n,
    input  wire sck,
    input  wire mosi,
    output wire miso
);

    reg [31:0] lba_tab [0:SD_SECTORS-1];
    reg [7:0]  dat_tab [0:SD_SECTORS*512-1];

    integer i;
    initial begin
        for (i = 0; i < SD_SECTORS; i = i + 1)
            lba_tab[i] = 32'hFFFF_FFFF;
        for (i = 0; i < SD_SECTORS*512; i = i + 1)
            dat_tab[i] = 8'h00;
        $readmemh(LBA_FILE, lba_tab);
        $readmemh(DAT_FILE, dat_tab);
    end

    // ------------------------------------------------------------------------
    // Bit framing. SPI mode 0: the host samples on the rising edge, so the card
    // must present a bit on the falling edge and hold it. Both edges are found
    // by sampling with the system clock rather than by clocking logic on sck -
    // there is only one clock in this model and no gated-clock trouble with it.
    // ------------------------------------------------------------------------
    reg       sck_d;
    reg [2:0] bitcnt;
    reg [7:0] rxsr, txsr;
    reg [7:0] rx_byte;
    reg       rx_stb;

    wire sck_rise = sck & ~sck_d;
    wire sck_fall = ~sck & sck_d;

    // +nosdcard makes the model deaf: MISO stays high, which is exactly what an
    // empty socket looks like on a board with no card-detect pin. The driver
    // must then fall out on the controller's watchdog rather than spin, and
    // that is a property worth being able to test on demand.
    reg absent;
    initial absent = $test$plusargs("nosdcard");

    assign miso = (cs_n || absent) ? 1'b1 : txsr[7];

    // ------------------------------------------------------------------------
    // Command reception
    // ------------------------------------------------------------------------
    localparam RX_CMD = 2'd0, RX_ARG = 2'd1, RX_CRC = 2'd2;

    reg [1:0]  rx_state;
    reg [5:0]  cmd;
    reg [31:0] arg;
    reg [1:0]  argcnt;
    reg        app_cmd;                 // the last command was CMD55
    reg        card_idle;
    reg [7:0]  acmd41_left;

    // ------------------------------------------------------------------------
    // Response transmission. A response is at most five bytes (R3 and R7), and
    // a read adds a token, 512 bytes and a two-byte CRC after it.
    // ------------------------------------------------------------------------
    localparam TX_IDLE = 3'd0, TX_NCR = 3'd1, TX_RESP = 3'd2,
               TX_WAIT = 3'd3, TX_TOKEN = 3'd4, TX_DATA = 3'd5, TX_CRC = 3'd6;

    reg [2:0]  tx_state;
    reg [7:0]  resp [0:4];
    reg [2:0]  resp_len, resp_idx;
    reg [2:0]  ncr;
    reg        want_data;
    reg [9:0]  data_cnt;
    reg [31:0] data_base;               // all ones: the sector is not in the image
    reg [1:0]  crc_cnt;
    reg [7:0]  next_byte;

    wire byte_start = sck_fall && (bitcnt == 3'd0);

    integer k;

    initial begin
        sck_d = 1'b0; bitcnt = 3'd0; rxsr = 8'h00; txsr = 8'hFF;
        rx_byte = 8'h00; rx_stb = 1'b0;
        rx_state = RX_CMD; cmd = 6'd0; arg = 32'd0; argcnt = 2'd0;
        app_cmd = 1'b0; card_idle = 1'b1; acmd41_left = ACMD41_TRIES;
        tx_state = TX_IDLE; resp_len = 3'd0; resp_idx = 3'd0; ncr = 3'd0;
        want_data = 1'b0; data_cnt = 10'd0; data_base = 32'hFFFF_FFFF;
        crc_cnt = 2'd0; next_byte = 8'hFF;
        for (k = 0; k < 5; k = k + 1) resp[k] = 8'hFF;
    end

    always @(posedge clk) begin
        sck_d  <= sck;
        rx_stb <= 1'b0;

        if (cs_n) begin
            // Deselected: the framing restarts from a byte boundary. A partial
            // byte is dropped, which is what a real card does too.
            bitcnt <= 3'd0;
            txsr   <= 8'hFF;
        end else begin
            // --- sample MOSI ---
            if (sck_rise) begin
                rxsr   <= {rxsr[6:0], mosi};
                bitcnt <= bitcnt + 3'd1;
                if (bitcnt == 3'd7) begin
                    rx_byte <= {rxsr[6:0], mosi};
                    rx_stb  <= 1'b1;
                end
            end

            // --- drive MISO ---
            if (sck_fall) begin
                if (bitcnt == 3'd0)
                    txsr <= next_byte;
                else
                    txsr <= {txsr[6:0], 1'b1};
            end
        end

        // --------------------------------------------------------------------
        // Command decode. Six bytes: 0x40|cmd, then the argument, then a CRC
        // this model does not check - the controller computes a correct one and
        // checking it here would only duplicate its own formal proof.
        // --------------------------------------------------------------------
        if (rx_stb) begin
            case (rx_state)
            RX_CMD: if (rx_byte[7:6] == 2'b01) begin
                        cmd      <= rx_byte[5:0];
                        argcnt   <= 2'd0;
                        rx_state <= RX_ARG;
                    end
            RX_ARG: begin
                        arg <= {arg[23:0], rx_byte};
                        if (argcnt == 2'd3)
                            rx_state <= RX_CRC;
                        argcnt <= argcnt + 2'd1;
                    end
            RX_CRC: begin
                        rx_state <= RX_CMD;
                        do_command;
                    end
            default: rx_state <= RX_CMD;
            endcase
        end

        // --------------------------------------------------------------------
        // Response sequencing, one byte per SPI byte period.
        // --------------------------------------------------------------------
        if (byte_start) begin
            case (tx_state)
            TX_NCR: begin
                        next_byte <= 8'hFF;
                        if (ncr == 3'd0) begin
                            tx_state  <= TX_RESP;
                            next_byte <= resp[0];
                            resp_idx  <= 3'd1;
                            if (resp_len == 3'd1) begin
                                tx_state <= want_data ? TX_WAIT : TX_IDLE;
                                ncr      <= 3'd2;
                            end
                        end else
                            ncr <= ncr - 3'd1;
                    end
            TX_RESP: begin
                        next_byte <= resp[resp_idx];
                        resp_idx  <= resp_idx + 3'd1;
                        if (resp_idx + 3'd1 >= resp_len) begin
                            tx_state <= want_data ? TX_WAIT : TX_IDLE;
                            ncr      <= 3'd2;
                        end
                    end
            TX_WAIT: begin
                        // The card is fetching the block. Real ones take a
                        // while; a couple of byte times is enough to prove the
                        // host waits for the token rather than assuming it.
                        next_byte <= 8'hFF;
                        if (ncr == 3'd0)
                            tx_state <= TX_TOKEN;
                        else
                            ncr <= ncr - 3'd1;
                    end
            TX_TOKEN: begin
                        next_byte <= 8'hFE;     // start of a single block
                        tx_state  <= TX_DATA;
                        data_cnt  <= 10'd0;
                    end
            TX_DATA: begin
                        next_byte <= (data_base == 32'hFFFF_FFFF) ? 8'h00
                                     : dat_tab[data_base + {22'd0, data_cnt}];
                        data_cnt  <= data_cnt + 10'd1;
                        if (data_cnt == 10'd511) begin
                            tx_state <= TX_CRC;
                            crc_cnt  <= 2'd0;
                        end
                    end
            TX_CRC: begin
                        // The controller is configured not to check the data
                        // CRC, so any two bytes will do.
                        next_byte <= 8'hFF;
                        crc_cnt   <= crc_cnt + 2'd1;
                        if (crc_cnt == 2'd1)
                            tx_state <= TX_IDLE;
                    end
            default: next_byte <= 8'hFF;
            endcase
        end
    end

    // ------------------------------------------------------------------------
    // What each command answers. R1's bit 0 is "in idle state"; bit 2 is
    // "illegal command". Nothing else is ever set, because nothing here fails.
    // ------------------------------------------------------------------------
    task do_command;
        reg [7:0] r1;
        integer   s;
        begin
            r1         = card_idle ? 8'h01 : 8'h00;
            resp_len    = 3'd1;
            want_data  <= 1'b0;
            ncr        <= 3'd1;
            data_base  <= 32'hFFFF_FFFF;

            case (cmd)
            6'd0: begin                       // GO_IDLE_STATE
                    card_idle   = 1'b1;
                    acmd41_left = ACMD41_TRIES;
                    resp[0]     = 8'h01;
                  end
            6'd8: begin                       // SEND_IF_COND
                    resp[0] = r1;
                    resp[1] = 8'h00;
                    resp[2] = 8'h00;
                    resp[3] = {4'h0, arg[11:8]};      // the voltage range, echoed
                    resp[4] = arg[7:0];       // the check pattern, echoed
                    resp_len = 3'd5;
                  end
            6'd55: begin                      // APP_CMD
                    resp[0] = r1;
                  end
            6'd41: if (app_cmd) begin         // ACMD41: SD_SEND_OP_COND
                        if (acmd41_left != 0) begin
                            acmd41_left = acmd41_left - 8'd1;
                            resp[0]     = 8'h01;
                        end else begin
                            card_idle = 1'b0;
                            resp[0]   = 8'h00;
                        end
                   end else
                        resp[0] = 8'h04;      // CMD41 alone is illegal
            6'd58: begin                      // READ_OCR
                    resp[0] = r1;
                    // Ready, high capacity, and the usual voltage window.
                    resp[1] = card_idle ? 8'h40 : 8'hC0;
                    resp[2] = 8'hFF;
                    resp[3] = 8'h80;
                    resp[4] = 8'h00;
                    resp_len = 3'd5;
                  end
            6'd16: resp[0] = r1;              // SET_BLOCKLEN, always 512 here
            6'd17: begin                      // READ_SINGLE_BLOCK
                    resp[0]   = r1;
                    want_data <= 1'b1;
                    for (s = 0; s < SD_SECTORS; s = s + 1)
                        if (lba_tab[s] == arg)
                            data_base <= s * 512;
                  end
            default: resp[0] = 8'h04;         // illegal command
            endcase

            // CMD55 arms the next command, and only the next one.
            app_cmd  = (cmd == 6'd55);

            resp_idx <= 3'd0;
            tx_state <= TX_NCR;
        end
    endtask

endmodule
