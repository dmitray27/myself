#include "afsk_protocol.h"
#include "esp_log.h"
#include <string.h>
#include <inttypes.h>

static const char *TAG = "AFSK_PROTO";

typedef struct {
    volatile bool *buffer;
    volatile uint32_t *w_idx;
    const volatile uint32_t *r_idx;
    uint32_t size;
    uint32_t dropped;
} tx_ring_t;

static void push_tx_bit(tx_ring_t *ring, bool bit) {
    uint32_t next_w_idx = (*ring->w_idx + 1) % ring->size;
    if (ring->r_idx == NULL || next_w_idx != *ring->r_idx) {
        ring->buffer[*ring->w_idx] = bit;
        *ring->w_idx = next_w_idx;
    } else {
        ring->dropped++;
    }
}

void afsk_serialize_block(const uint8_t *data, size_t len,
                          volatile bool *bit_buffer,
                          volatile uint32_t *w_idx,
                          uint32_t buffer_size) {
    afsk_serialize_block_ring(data, len, bit_buffer, w_idx, NULL, buffer_size);
}

uint32_t afsk_serialize_block_ring(const uint8_t *data, size_t len,
                                   volatile bool *bit_buffer,
                                   volatile uint32_t *w_idx,
                                   const volatile uint32_t *r_idx,
                                   uint32_t buffer_size) {
    tx_ring_t ring = {
        .buffer = bit_buffer,
        .w_idx = w_idx,
        .r_idx = r_idx,
        .size = buffer_size,
        .dropped = 0,
    };

    for (int i = 0; i < PREAMBLE_BITS; i++) {
        push_tx_bit(&ring, 1);
    }

    for (size_t i = 0; i < len; i++) {
        uint8_t byte = data[i];
        push_tx_bit(&ring, 0);  // START
        for (int b = 0; b < 8; b++) {
            push_tx_bit(&ring, (byte >> b) & 0x01);
        }
        push_tx_bit(&ring, 1);  // STOP
    }

    uint8_t crc = afsk_crc8(data, len);
    push_tx_bit(&ring, 0);
    for (int b = 0; b < 8; b++) {
        push_tx_bit(&ring, (crc >> b) & 0x01);
    }
    push_tx_bit(&ring, 1);

    for (int i = 0; i < 10; i++) {
        push_tx_bit(&ring, 1);
    }

    /* A truncated frame goes on the air as a CRC error at best, so it is worth
     * a line in the log rather than silence. */
    if (ring.dropped > 0) {
        ESP_LOGE(TAG, "TX bit ring full: %" PRIu32 " bit(s) of the block dropped",
                 ring.dropped);
    }

    return ring.dropped;
}

/* Largest byte count <= max_len starting at `start` that does not split a
 * multibyte UTF-8 character. A continuation byte matches 10xxxxxx (0x80..0xBF);
 * if the byte just past the block is a continuation byte we are mid-character,
 * so back off until the next block would start on a character boundary. */
int afsk_utf8_block_len(const char *buf, int start, int len, int max_len) {
    int n = (len - start < max_len) ? (len - start) : max_len;
    if (start + n < len) {
        while (n > 0 && ((unsigned char)buf[start + n] & 0xC0) == 0x80) {
            n--;
        }
    }
    if (n <= 0) {
        n = (len - start < max_len) ? (len - start) : max_len;
    }
    return n;
}

uint8_t afsk_crc8(const uint8_t *data, size_t len) {
    uint8_t crc = 0x00;
    while (len--) {
        crc ^= *data++;
        for (uint8_t i = 0; i < 8; i++) {
            crc = (crc & 0x80) ? ((crc << 1) ^ 0x07) : (crc << 1);
        }
    }
    return crc;
}
