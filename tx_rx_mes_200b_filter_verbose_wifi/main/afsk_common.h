#pragma once
#include <stdint.h>
#include <stddef.h>

/* Shared AFSK link parameters (identical for TX and RX). */
#define MARK_FREQ       1200        /* Hz, logical '1' */
#define SPACE_FREQ      2200        /* Hz, logical '0' */
#ifndef BAUD_RATE
#define BAUD_RATE       200         /* bits per second */
#endif
#ifndef PREAMBLE_BITS
#define PREAMBLE_BITS   640         /* leading '1's before a frame */
#endif
#define SAMPLE_RATE     48000       /* Hz, I2S RX sample rate */

/* Framing: payload bytes per block and the pause the transmitter keeps
 * between the blocks of one message. */
#define MAX_BLOCK_LEN   50          /* payload bytes per block */

/* afsk_utf8_block_len() keeps multi-byte characters whole by shortening the
 * block; a block that cannot hold the longest UTF-8 sequence leaves it no
 * choice but to split one, so the payload has to be at least 4 bytes. */
_Static_assert(MAX_BLOCK_LEN >= 4,
               "MAX_BLOCK_LEN must hold the longest UTF-8 character (4 bytes), "
               "or afsk_utf8_block_len() splits it across blocks");

#define BLOCK_GAP_MS    500         /* silence between blocks  */

/* Silence after which the receiver finalizes the frame it is assembling.
 * Shared so the inter-block pause can be checked against it (see the
 * _Static_assert in afsk_decoder.c) and so host tests can pace their
 * synthetic gaps the same way. */
#define SIGNAL_TIMEOUT_MS 2000

/* PTT keying for a voice radio (opto-isolator in place of the headset PTT
 * button). PTT_LEAD_MS lets the radio switch to transmit before the preamble
 * starts, PTT_TAIL_MS keeps it keyed so the last bit is not clipped.
 * Set TX_PTT_ENABLE to 0 for a direct wired link. These live here rather than
 * in tx_ad9851.h because the block timings below - and the receiver's idle
 * timeouts - are derived from them. */
#ifndef TX_PTT_ENABLE
#define TX_PTT_ENABLE   1
#endif
#define PTT_LEAD_MS     300
#define PTT_TAIL_MS     100
#define PTT_OVERHEAD_MS (TX_PTT_ENABLE ? (PTT_LEAD_MS + PTT_TAIL_MS) : 0)

/* Bits keyed for one full block: preamble, then payload and CRC byte in
 * UART-style 10-bit slots, then the trailing marks. Everything that has to
 * outlive a block (TX bit ring, TX idle timeout, RX assembly timeout) is
 * derived from these instead of being tuned by hand. */
#define BLOCK_BITS      (PREAMBLE_BITS + (MAX_BLOCK_LEN + 1) * 10 + 10)
#define BLOCK_AIR_MS    ((BLOCK_BITS * 1000) / BAUD_RATE)
#define BLOCK_TIME_MS   (BLOCK_AIR_MS + BLOCK_GAP_MS + PTT_OVERHEAD_MS)

/* Upper bound on how long tx_ad9851_wait_idle() may wait for the ISR to drain
 * the bit ring: the whole block on the air plus PTT lead/tail, plus 50% and
 * half a second of margin for clock tolerance. A timeout shorter than the
 * block itself releases the transmitter mid-transmission and the next block
 * is silently dropped, which is why this is computed, not a constant. */
#define TX_IDLE_TIMEOUT_MS (BLOCK_AIR_MS + BLOCK_AIR_MS / 2 + PTT_OVERHEAD_MS + 500)

/* Diagnostic chatter: preamble progress, idle level meter and the periodic
 * "waiting for signal" line. Set to 0 for a quiet log with received blocks
 * and assembled messages only. */
#ifndef AFSK_VERBOSE
#define AFSK_VERBOSE    1
#endif

/* CRC-8 (poly 0x07, init 0x00). Single shared implementation. */
uint8_t afsk_crc8(const uint8_t *data, size_t len);
