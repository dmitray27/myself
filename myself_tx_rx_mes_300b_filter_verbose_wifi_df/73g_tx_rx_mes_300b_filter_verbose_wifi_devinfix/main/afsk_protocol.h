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
