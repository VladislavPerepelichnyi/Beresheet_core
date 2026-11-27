/*
 * SD card over SPI, driving ZipCPU's sdspi controller.
 *
 * The controller does the SPI framing, the command/response protocol and the
 * 512-byte data FIFO. This driver only has to run the card's power-up sequence
 * and then ask for sectors.
 *
 * The power-up sequence is fixed by the SD specification and every step of it
 * exists for a reason:
 *
 *   CMD0    GO_IDLE_STATE. With CS held low this is also what puts a card into
 *           SPI mode at all - a card comes up expecting the native SD protocol.
 *   CMD8    SEND_IF_COND. Asks "do you understand 2.0 voltage signalling?" and
 *           echoes a check pattern back. A version 1 card rejects it, which is
 *           how the two are told apart.
 *   ACMD41  the actual initialisation, and it is a *poll*: the card returns
 *           "still busy" until its internal setup finishes, which can take
 *           hundreds of milliseconds on a cold card.
 *   CMD58   READ_OCR, which carries the CCS bit - the one thing that decides
 *           whether CMD17 wants a block number or a byte address. Getting this
 *           wrong reads the right data from the wrong place by a factor of 512.
 */
#ifndef SDCARD_H
#define SDCARD_H

#include <stdint.h>
#include "soc.h"

#define SD_BLOCK_SIZE 512

/* Returns 0 on success, non-zero on failure. Safe to call twice. */
int  sd_init(void);

/* One 512-byte block into buf. Returns 0 on success. */
int  sd_read_block(uint32_t lba, uint8_t *buf);

/* Diagnostics, valid after sd_init(). */
int         sd_present(void);
int         sd_is_hc(void);          /* block addressed rather than byte addressed */
uint32_t    sd_last_status(void);
const char *sd_error_text(void);

#endif
