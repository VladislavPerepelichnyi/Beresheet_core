/*
 * SD card in SPI mode, through ZipCPU's sdspi controller.
 *
 * The controller handles SPI framing, command/response and a 512-byte FIFO;
 * this driver runs the card's initialisation and reads single blocks.
 *
 *   CMD0    GO_IDLE_STATE; with CS low this also selects SPI mode
 *   CMD8    SEND_IF_COND; a v2 card echoes the check pattern, v1 rejects it
 *   ACMD41  start initialisation; polled until the card leaves idle, which can
 *           take hundreds of milliseconds
 *   CMD58   READ_OCR; the CCS bit says whether CMD17 takes a block number
 *           (high capacity) or a byte address
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
