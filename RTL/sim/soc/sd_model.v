// =============================================================================
// Behavioural SD card in SPI mode, simulation only.
//
// Implements the subset of commands a boot loader uses:
//
//   CMD0   GO_IDLE_STATE      R1 = idle
//   CMD8   SEND_IF_COND       R7, voltage range and check pattern echoed
//   CMD55  APP_CMD            R1; marks the next command as an ACMD
//   ACMD41 SD_SEND_OP_COND    R1, busy for ACMD41_TRIES calls, then ready
//   CMD58  READ_OCR           R3 with CCS set (high capacity, block addressed)
//   CMD16  SET_BLOCKLEN       R1 (blocks are always 512 bytes)
//   CMD17  READ_SINGLE_BLOCK  R1, then token 0xFE, 512 data bytes, 2 CRC bytes
//
// Any other command is answered "illegal command". The image is sparse: the
// LBA file lists the sectors present and the data file holds their contents;
// any other sector reads as zeroes. Command CRCs are not checked.
//
// Plusargs: +sd_lba=<file> and +sd_dat=<file> override LBA_FILE/DAT_FILE;
// +nosdcard holds MISO high, as an empty socket does.
// =============================================================================
`timescale 1ns/1ps

module sd_model #(
    parameter SD_SECTORS = 64,          // sparse image capacity, in sectors
    parameter [8*256-1:0] LBA_FILE = "build/sd/sd_lba.hex",
    parameter [8*256-1:0] DAT_FILE = "build/sd/sd_dat.hex",
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

    reg [8*256-1:0] lba_file, dat_file;
    integer i;
    initial begin
        for (i = 0; i < SD_SECTORS; i = i + 1)
            lba_tab[i] = 32'hFFFF_FFFF;
        for (i = 0; i < SD_SECTORS*512; i = i + 1)
            dat_tab[i] = 8'h00;
        if (!$value$plusargs("sd_lba=%s", lba_file)) lba_file = LBA_FILE;
        if (!$value$plusargs("sd_dat=%s", dat_file)) dat_file = DAT_FILE;
        $readmemh(lba_file, lba_tab);
        $readmemh(dat_file, dat_tab);
    end

    // ------------------------------------------------------------------------
    // Bit framing, SPI mode 0: MOSI is sampled on the rising edge of sck and
    // MISO changes on the falling edge. Both edges are detected by sampling
    // sck with the system clock.
    // ------------------------------------------------------------------------
    reg       sck_d;
    reg [2:0] bitcnt;
    reg [7:0] rxsr, txsr;
    reg [7:0] rx_byte;
    reg       rx_stb;

    wire sck_rise = sck & ~sck_d;
    wire sck_fall = ~sck & sck_d;

    // +nosdcard: MISO stays high, as with an empty socket and no card-detect
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
    // Response transmission: up to five bytes (R3, R7), followed for a read by
    // a token, 512 data bytes and a two-byte CRC.
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
            // Deselected: framing restarts on a byte boundary; a partial byte
            // is dropped.
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
        // Command decode: 0x40|cmd, four argument bytes, CRC (not checked)
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
                        // Read access time: a few 0xFF bytes before the token,
                        // so the host must wait for it
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
                        // Data CRC is not checked by the host controller
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
    // Command responses. R1 bit 0 = in idle state, bit 2 = illegal command.
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

            // CMD55 applies to the next command only
            app_cmd  = (cmd == 6'd55);

            resp_idx <= 3'd0;
            tx_state <= TX_NCR;
        end
    endtask

endmodule
