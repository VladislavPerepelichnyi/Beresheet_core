#include "sdcard.h"
#include "uart.h"

/*
 * sdspi registers. The command register holds the SD command number in its low
 * bits and controller flags above it; the bit definitions are the controller's.
 */
#define SD_CMD      (SD_BASE + 0x00u)
#define SD_DATA     (SD_BASE + 0x04u)
#define SD_FIFO_A   (SD_BASE + 0x08u)
#define SD_FIFO_B   (SD_BASE + 0x0Cu)

#define SD_SETAUX   0x0000ffu
#define SD_READAUX  0x0000bfu
#define SD_GO_CMD   0x000040u       /* "this is a command", plus the number */
#define SD_ACMD55   (SD_GO_CMD + 55u)
#define SD_READREG  0x000200u       /* expect an R3/R7: R1 plus 32 bits */
#define SD_FIFO_OP  0x000800u       /* the command delivers data into the FIFO */
#define SD_BUSY     0x004000u
#define SD_ERROR    0x008000u
#define SD_CLEARERR 0x008000u
#define SD_REMOVED  0x040000u
#define SD_PRESENTN 0x080000u

#define SD_GO_IDLE      (SD_REMOVED | SD_CLEARERR | SD_GO_CMD)          /* CMD0  */
#define SD_READ_SECTOR  (SD_GO_CMD | SD_CLEARERR | SD_FIFO_OP | 17u)    /* CMD17 */

/*
 * Aux word: 512-byte sectors, and the clock divider in the low bits.
 * SPI clock = CPU_HZ / (2 * (divider + 1)).
 */
#define SD_SECTOR_512B  0x090000u
#define SD_SPEED_SLOW   (CPU_HZ / 200000u - 1u)   /* 100 kHz, for initialisation */
#define SD_SPEED_FAST   1u                        /* CPU_HZ / 4: 6 MHz at 24 MHz */

static int         sd_ok;
static int         sd_hc;
static uint32_t    sd_status;
static const char *sd_err = "not initialised";

int         sd_present(void)     { return sd_ok; }
int         sd_is_hc(void)       { return sd_hc; }
uint32_t    sd_last_status(void) { return sd_status; }
const char *sd_error_text(void)  { return sd_err; }

/*
 * A command is "write the argument, write the command, wait for BUSY to clear".
 *
 * The wait does not stop early on the error flag: the controller ignores writes
 * to the data register until it is idle, so leaving mid-command would make the
 * next command fail too. The controller's own watchdog (about 175 ms) normally
 * ends a stuck command; the guard only catches a stuck controller.
 */
static uint32_t sd_wait(void)
{
    uint32_t r;
    uint32_t guard = 8000000u;

    do {
        r = mmio_r32(SD_CMD);
        if (r & SD_PRESENTN)
            break;
    } while ((r & SD_BUSY) && --guard);

    sd_status = r;
    return r;
}

static uint32_t sd_cmd(uint32_t cmd, uint32_t arg)
{
    mmio_w32(SD_DATA, arg);
    mmio_w32(SD_CMD, cmd);
    return sd_wait();
}

int sd_init(void)
{
    uint32_t r;
    int      tries;

    sd_ok = 0;
    sd_hc = 0;

    /* Slow clock and a known sector length before anything else. */
    mmio_w32(SD_DATA, SD_SECTOR_512B | SD_SPEED_SLOW);
    mmio_w32(SD_CMD,  SD_SETAUX);

    /* Clear whatever the controller was left holding. */
    mmio_w32(SD_DATA, 0);
    mmio_w32(SD_CMD,  SD_CLEARERR | SD_READAUX);

    r = mmio_r32(SD_CMD);
    sd_status = r;
    if (r & SD_PRESENTN) {
        sd_err = "no card in the socket";
        return -1;
    }

    /* CMD0: reset, and enter SPI mode. */
    r = sd_cmd(SD_GO_IDLE, 0);
    if (r & SD_ERROR) {
        sd_err = "no response to CMD0";
        return -1;
    }

    /*
     * CMD8: the check pattern 0x1AA comes back verbatim from a version 2 card.
     * The controller returns R7 in the data register.
     */
    r = sd_cmd((SD_GO_CMD | SD_READREG) + 8u, 0x000001AAu);
    if (r & SD_ERROR) {
        sd_err = "CMD8 rejected (card older than v2?)";
        return -1;
    }
    if ((mmio_r32(SD_DATA) & 0xFFFu) != 0x1AAu) {
        sd_err = "CMD8 check pattern came back wrong";
        return -1;
    }

    /* ACMD41, polled until the card leaves idle. HCS = 1: high-capacity
     * cards are supported. */
    for (tries = 0; tries < 20000; tries++) {
        sd_cmd(SD_ACMD55, 0);
        r = sd_cmd(SD_GO_CMD + 41u, 0x40000000u);
        if (r & SD_ERROR) {
            sd_err = "ACMD41 failed";
            return -1;
        }
        if ((r & 1u) == 0)          /* bit 0 is the card's "still idle" flag */
            break;
    }
    if (tries >= 20000) {
        sd_err = "card never left idle (ACMD41 timed out)";
        return -1;
    }

    /*
     * CMD58: OCR bit 30 is CCS. Set means the card is addressed in blocks;
     * clear means byte addresses, and CMD17 needs lba * 512 instead.
     */
    r = sd_cmd((SD_GO_CMD | SD_READREG) + 58u, 0);
    if (r & SD_ERROR) {
        sd_err = "CMD58 failed";
        return -1;
    }
    sd_hc = (mmio_r32(SD_DATA) & 0x40000000u) ? 1 : 0;

    /* The handshake is done, so the clock can come up. */
    mmio_w32(SD_DATA, SD_SECTOR_512B | SD_SPEED_FAST);
    mmio_w32(SD_CMD,  SD_SETAUX);

    sd_ok  = 1;
    sd_err = "ok";
    return 0;
}

int sd_read_block(uint32_t lba, uint8_t *buf)
{
    uint32_t r, w;
    int      i;

    if (!sd_ok) {
        sd_err = "read before a successful init";
        return -1;
    }

    r = sd_cmd(SD_READ_SECTOR, sd_hc ? lba : (lba * SD_BLOCK_SIZE));
    if (r & (SD_ERROR | SD_REMOVED)) {
        sd_err = "read failed";
        return -1;
    }

    /*
     * The FIFO returns 32-bit words with the first byte from the card in the
     * most significant lane. Unpack to a byte array in card order here, once,
     * so the callers see plain memory order.
     */
    for (i = 0; i < SD_BLOCK_SIZE / 4; i++) {
        w = mmio_r32(SD_FIFO_A);
        buf[i * 4 + 0] = (uint8_t)(w >> 24);
        buf[i * 4 + 1] = (uint8_t)(w >> 16);
        buf[i * 4 + 2] = (uint8_t)(w >> 8);
        buf[i * 4 + 3] = (uint8_t)(w);
    }

    return 0;
}
