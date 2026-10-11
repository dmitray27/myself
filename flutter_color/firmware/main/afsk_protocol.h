#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "afsk_common.h"

/* Serializes one block (preamble, payload, CRC, trailing marks) into a plain
 * bit buffer, wrapping at buffer_size. Kept for the host tests. */
void afsk_serialize_block(const uint8_t *data, size_t len,
                          volatile bool *bit_buffer,
                          volatile uint32_t *w_idx,
                          uint32_t buffer_size);

/* Same, but aware of the index the timer ISR reads from, so a full ring is
 * detected instead of overwriting bits still waiting to be keyed.
 * Returns the number of bits that did not fit, i.e. 0 on success. */
uint32_t afsk_serialize_block_ring(const uint8_t *data, size_t len,
                                   volatile bool *bit_buffer,
                                   volatile uint32_t *w_idx,
                                   const volatile uint32_t *r_idx,
                                   uint32_t buffer_size);

int afsk_utf8_block_len(const char *buf, int start, int len, int max_len);

/* Block header that precedes the text inside every frame (AFSK_HDR_LEN bytes,
 * covered by the block CRC). block_no is 0-based; total >= 1. */
typedef struct {
    uint8_t seq;
    uint8_t block_no;
    uint8_t total;
} afsk_block_hdr_t;

/* Writes header + text into `out`; returns the frame length or 0 if it does
 * not fit. */
size_t afsk_pack_block(uint8_t *out, size_t out_size,
                       const afsk_block_hdr_t *hdr,
                       const uint8_t *text, size_t text_len);

/* Splits a CRC-checked frame into header and text. false on a frame too
 * short for a header or with an inconsistent header (total == 0,
 * block_no >= total, text longer than MAX_BLOCK_LEN). */
bool afsk_unpack_block(const uint8_t *frame, size_t frame_len,
                       afsk_block_hdr_t *hdr,
                       const uint8_t **text, size_t *text_len);
