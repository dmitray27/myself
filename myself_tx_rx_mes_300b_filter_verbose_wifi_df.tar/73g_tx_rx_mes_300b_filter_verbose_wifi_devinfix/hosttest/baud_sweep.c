#define _GNU_SOURCE
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
/* Noise-threshold sweep for one baud rate.
 *
 * Same signal path as hosttest/host_test_ext.c (persistent decoder, real
 * inter-block gaps, optional sample-clock drift), but instead of a single
 * pass/fail it walks the noise amplitude up and prints, for every level, how
 * many of N runs (different noise seeds) delivered the whole message intact.
 * Compile once per BAUD_RATE to compare 200 vs 300 baud on identical input.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#include "afsk_protocol.h"
#include "afsk_decoder.h"

volatile uint32_t tx_bit_r_idx = 0;
int64_t g_virtual_us = 0;

#define FS            48000
#define FULL_SCALE    8388608.0   /* 2^23 */
#define TONE_AMP      0.30

static bool bit_buf[65536];
static volatile uint32_t w_idx;

static void feed_silence(afsk_decoder_t *dec, afsk_message_t *msg, int ms,
                         double noise_amp, unsigned int *seed,
                         char *assembled, int *assembled_len) {
    int samples = (int)((int64_t)ms * FS / 1000);
    for (int i = 0; i < samples; i++) {
        double n = noise_amp * (((double)rand_r(seed) / RAND_MAX) * 2.0 - 1.0);
        int32_t smp = (int32_t)(n * FULL_SCALE);
        g_virtual_us += 1000000 / FS;
        if (afsk_decoder_process_sample(dec, smp, msg) && msg->crc_valid) {
            memcpy(assembled + *assembled_len, msg->text, msg->length);
            *assembled_len += msg->length;
        }
    }
}

static bool run_once(const char *message, double fs_actual, double noise_amp,
                     unsigned int seed) {
    int len = (int)strlen(message);
    static char assembled[8192];
    int assembled_len = 0;

    memset(assembled, 0, sizeof(assembled));

    afsk_decoder_t dec;
    afsk_message_t msg;
    memset(&msg, 0, sizeof(msg));
    g_virtual_us = 0;
    afsk_decoder_init(&dec, FS);

    int samples_per_bit_gen = (int)(fs_actual / BAUD_RATE + 0.5);
    double phase = 0.0;

    feed_silence(&dec, &msg, 200, noise_amp, &seed, assembled, &assembled_len);

    for (int start = 0; start < len; ) {
        int block_len = afsk_utf8_block_len(message, start, len, MAX_BLOCK_LEN);
        char block[MAX_BLOCK_LEN + 1];
        memcpy(block, message + start, block_len);
        block[block_len] = '\0';

        tx_bit_r_idx = 0;
        w_idx = 0;
        memset(bit_buf, 0, sizeof(bit_buf));
        afsk_serialize_block((const uint8_t *)block, block_len, bit_buf, &w_idx,
                             sizeof(bit_buf) / sizeof(bit_buf[0]));
        uint32_t nbits = w_idx;

        for (uint32_t b = 0; b < nbits; b++) {
            double f = bit_buf[b] ? (double)MARK_FREQ : (double)SPACE_FREQ;
            for (int i = 0; i < samples_per_bit_gen; i++) {
                phase += 2.0 * M_PI * f / fs_actual;
                double n = noise_amp *
                           (((double)rand_r(&seed) / RAND_MAX) * 2.0 - 1.0);
                int32_t smp = (int32_t)((TONE_AMP * sin(phase) + n) * FULL_SCALE);
                g_virtual_us += 1000000 / FS;
                if (afsk_decoder_process_sample(&dec, smp, &msg) &&
                    msg.crc_valid) {
                    memcpy(assembled + assembled_len, msg.text, msg.length);
                    assembled_len += msg.length;
                }
            }
        }

        feed_silence(&dec, &msg, BLOCK_GAP_MS + PTT_OVERHEAD_MS, noise_amp,
                     &seed, assembled, &assembled_len);
        start += block_len;
    }

    feed_silence(&dec, &msg, SIGNAL_TIMEOUT_MS + 500, noise_amp, &seed,
                 assembled, &assembled_len);

    return assembled_len == len && memcmp(assembled, message, len) == 0;
}

/* Wideband SNR of the generated stream: sine of amplitude TONE_AMP against
 * uniform noise of amplitude noise_amp over the full 0..FS/2 band. */
static double snr_db(double noise_amp) {
    if (noise_amp <= 0.0) return INFINITY;
    double s = TONE_AMP / sqrt(2.0);
    double n = noise_amp / sqrt(3.0);
    return 20.0 * log10(s / n);
}

int main(int argc, char **argv) {
    int runs = (argc > 1) ? atoi(argv[1]) : 5;

    static char msg[151];
    const char *seed_text =
        "Embedded systems combine hardware and software to work reliably. ";
    for (size_t i = 0; i < sizeof(msg) - 1; i++) {
        msg[i] = seed_text[i % strlen(seed_text)];
    }
    msg[sizeof(msg) - 1] = '\0';

    double default_levels[] = {0.00, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30,
                               0.40, 0.50, 0.60, 0.75, 1.00, 1.25, 1.50,
                               2.00, 2.50, 3.00};
    double argv_levels[64];
    const double *levels = default_levels;
    size_t n_levels = sizeof(default_levels) / sizeof(default_levels[0]);
    if (argc > 2) {
        n_levels = 0;
        for (int a = 2; a < argc && n_levels < 64; a++) {
            argv_levels[n_levels++] = atof(argv[a]);
        }
        levels = argv_levels;
    }
    const double drifts[] = {1.0, 1.003, 0.997};
    const char *drift_name[] = {"clock exact", "clock +0.3%", "clock -0.3%"};

    printf("baud=%d  samples/bit=%d  block=%d bits (%d ms air)  msg=%d bytes"
           "  runs/level=%d\n",
           BAUD_RATE, FS / BAUD_RATE, BLOCK_BITS, BLOCK_AIR_MS,
           (int)strlen(msg), runs);

    for (size_t d = 0; d < sizeof(drifts) / sizeof(drifts[0]); d++) {
        printf("\n%s\n", drift_name[d]);
        printf("  noise  wideband SNR   ok/%d\n", runs);
        for (size_t l = 0; l < n_levels; l++) {
            int ok = 0;
            for (int r = 0; r < runs; r++) {
                if (run_once(msg, (double)FS * drifts[d], levels[l],
                             1000u + 7u * (unsigned)r)) {
                    ok++;
                }
            }
            double snr = snr_db(levels[l]);
            if (isinf(snr)) {
                printf("  %5.2f       clean      %d/%d\n", levels[l], ok, runs);
            } else {
                printf("  %5.2f    %6.1f dB      %d/%d\n", levels[l], snr, ok,
                       runs);
            }
            fflush(stdout);
        }
    }
    return 0;
}
