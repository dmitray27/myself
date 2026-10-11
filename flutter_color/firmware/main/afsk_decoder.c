#include "afsk_decoder.h"
#include "esp_log.h"
#include "esp_timer.h"
#include <assert.h>
#include <string.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static const char *TAG = "AFSK_DEC";

#define INIT_NOISE_FLOOR    0.0001f
#define MIN_SIGNAL_RATIO    2.0f
#define CONFIDENCE_MIN      25
#define SAMPLE_FULL_SCALE   8388608.0f  /* 2^23, 24-bit signed */

/* A frame is finalized after SIGNAL_TIMEOUT_MS without signal, so the pause
 * the transmitter leaves between the blocks of one message (plus PTT
 * lead/tail) must stay well below it - otherwise every gap ends the frame. */
_Static_assert(BLOCK_GAP_MS + PTT_OVERHEAD_MS < SIGNAL_TIMEOUT_MS,
               "BLOCK_GAP_MS + PTT overhead must be shorter than "
               "SIGNAL_TIMEOUT_MS, or blocks are cut apart on RX");

/* Absolute squelch. The adaptive threshold is derived from the weaker of the
 * two tones, so a steady stray carrier (ADC self-noise, clock crosstalk, a
 * transmitter left keyed) makes the weaker tone vanish, drags the threshold
 * down with it and then looks like a perfectly confident MARK - the receiver
 * counts an endless preamble on a line that carries nothing. Anything below
 * this tone amplitude (relative to full scale) is never treated as signal. */
#ifndef MIN_TONE_AMPLITUDE
#define MIN_TONE_AMPLITUDE  0.01f                 /* -40 dBFS */
#endif
#define MIN_TONE_POWER      (MIN_TONE_AMPLITUDE * MIN_TONE_AMPLITUDE / 4.0f)

/* DC blocker cutoff (~10 Hz at 48 kHz). A DC offset from the ADC leaks into
 * the space correlator (2200 Hz is not an integer number of cycles per bit)
 * and biases the discriminator. */
#define DC_BLOCK_ALPHA      0.0013f

/* Idle line report: peak input level and per-tone levels, so a stray carrier
 * can be measured instead of guessed. Silenced with AFSK_VERBOSE 0. */
#if AFSK_VERBOSE
#define LEVEL_REPORT_MS     5000u
#endif

/* Preamble progress print interval, in bits. */
#define PREAMBLE_LOG_EVERY  (PREAMBLE_DETECT / 8)

/* Declare the preamble a bit before all its bits are counted: with clock
 * drift the sampler may under/over-count the preamble ones, so detecting at
 * 3/4 gives margin on both sides. The remaining mark bits are absorbed by the
 * WAITING_FOR_START tolerance below. */
#define PREAMBLE_DETECT     (PREAMBLE_BITS * 3 / 4)
#define START_MARK_TOLERANCE PREAMBLE_BITS

/* Over the air the preamble is not clean: a noise burst, a fade or the
 * squelch tail flips or mutes single bits. Zeroing the counter on every such
 * bit means one glitch past a quarter of the preamble leaves too few mark
 * bits to ever reach PREAMBLE_DETECT again, and the whole block is dropped
 * without a trace. Charge a penalty instead, so the score tracks the recent
 * quality of the line: scattered glitches only delay detection, while real
 * noise (roughly a fifth of the bits bad or worse) still never gets there. */
#define PREAMBLE_GLITCH_PENALTY  4

/* Detection lands before the preamble ends, so a long run of mark bits is
 * expected while waiting for START. A dropout in that run is not a reason to
 * discard the frame either - only a sustained one is. */
#define START_DROPOUT_TOLERANCE  32     /* bits, ~107 ms at 300 baud */

#if AFSK_VERBOSE
#define AFSK_DIAG(fmt, ...) printf(fmt "\n", ##__VA_ARGS__)
#else
#define AFSK_DIAG(fmt, ...) do {} while (0)
#endif

/* DPLL: fraction of the residual phase error removed on every detected
 * bit transition. 0.5 => halve the error each edge (fast lock). */
#define PLL_INERTIA         0.5f

/* Shared quarter-symmetric sine table for the two NCOs. */
#define SINE_TABLE_BITS     10
#define SINE_TABLE_SIZE     (1 << SINE_TABLE_BITS)   /* 1024 */
#define SINE_TABLE_MASK     (SINE_TABLE_SIZE - 1)
#define SINE_TABLE_QUARTER  (SINE_TABLE_SIZE / 4)    /* 90 deg phase shift */

static float sine_table[SINE_TABLE_SIZE];
static uint32_t sine_table_state = 0;   /* 0=empty, 1=building, 2=ready */

/* Idempotent and thread-safe: call it once from app_main before the tasks that
 * use a decoder are created (afsk_decoder_init calls it too, which covers the
 * single-decoder case and the host tests).  The wait loop protects the unlikely
 * case of a concurrent init on the second core. */
void afsk_decoder_tables_init(void) {
    if (__sync_bool_compare_and_swap(&sine_table_state, 0, 1)) {
        for (int i = 0; i < SINE_TABLE_SIZE; i++) {
            sine_table[i] = sinf(2.0f * (float)M_PI * (float)i / (float)SINE_TABLE_SIZE);
        }
        __sync_synchronize();
        __sync_lock_test_and_set(&sine_table_state, 2);
    } else {
        while (__sync_or_and_fetch(&sine_table_state, 0) != 2) {
            __sync_synchronize();
        }
    }
}

static inline uint32_t nco_inc(int freq, int sample_rate) {
    return (uint32_t)(((double)freq * 4294967296.0) / (double)sample_rate);
}

#ifdef LEVEL_REPORT_MS
/* Amplitude (0..1 of full scale) as dBFS, floored for silence. */
static inline float level_dbfs(float amplitude) {
    return (amplitude > 1e-7f) ? 20.0f * log10f(amplitude) : -140.0f;
}
#endif

void afsk_decoder_init(afsk_decoder_t *dec, int sample_rate) {
    memset(dec, 0, sizeof(afsk_decoder_t));
    afsk_decoder_tables_init();

    dec->config.samples_per_bit = sample_rate / BAUD_RATE;

    dec->inc_mark = nco_inc(MARK_FREQ, sample_rate);
    dec->inc_space = nco_inc(SPACE_FREQ, sample_rate);

    /* The matched filter integrates over a whole bit, so its output settles on
     * the new bit one bit after the transition, i.e. half a bit after the
     * transition is *detected*. The PLL pulls its phase to 0 on the detected
     * transition, which puts the ideal sampling instant near phase 0.5 minus a
     * small margin against the next transition. */
    float offset_frac = 0.10f;
#ifdef HOST_TUNE
    const char *e;
    if ((e = getenv("DEC_OFFSET"))) offset_frac = (float)atof(e);
#endif

    dec->pll_step = (uint32_t)(4294967296.0 / (double)dec->config.samples_per_bit);
    if (offset_frac > 0.45f) offset_frac = 0.45f;
    if (offset_frac < 0.0f) offset_frac = 0.0f;
    dec->sample_point = (uint32_t)((0.5 - (double)offset_frac) * 4294967296.0);

    dec->state = WAITING_FOR_PREAMBLE;
    dec->last_signal_time = esp_timer_get_time() / 1000;
    dec->noise_floor = INIT_NOISE_FLOOR;
    dec->signal_threshold = INIT_NOISE_FLOOR * MIN_SIGNAL_RATIO;
    dec->level_report_time = dec->last_signal_time;

    ESP_LOGI(TAG, "Decoder initialized: samples/bit=%d, matched filter=%d taps, pll_step=%" PRIu32,
             dec->config.samples_per_bit, MF_TAPS, dec->pll_step);
}

/* Back to hunting for a preamble. Both exits from a frame (abort and
 * finalization) go through here, so the transition-detector state cannot be
 * carried over into the next frame and fake an edge on its first bit. */
static void reset_frame_state(afsk_decoder_t *dec) {
    dec->state = WAITING_FOR_PREAMBLE;
    dec->ones_count = 0;
    dec->start_wait = 0;
    dec->start_dropout = 0;
    dec->preamble_glitches = 0;
    dec->preamble_best = 0;
    dec->rx_index = 0;
    dec->prev_sign = false;
    dec->have_prev_sign = false;
}

/* Give up on the frame being acquired and go back to hunting for a preamble.
 * Every abort is reported: a block lost here never reaches the CRC check, so
 * without this it disappears from the log entirely. */
static void abort_frame(afsk_decoder_t *dec, const char *reason) {
    (void)reason;
    dec->frames_aborted++;
    AFSK_DIAG("[RX] Frame aborted: %s (preamble peak %d/%d, %d glitch(es), "
              "total aborted: %" PRIu32 ")",
              reason, dec->preamble_best, PREAMBLE_DETECT,
              dec->preamble_glitches, dec->frames_aborted);

    reset_frame_state(dec);
}

/* Runs the framing state machine on one recovered bit. Returns true when a
 * complete message has been finalized into *msg. */
static bool process_bit(afsk_decoder_t *dec, bool bit, float max_power,
                        int confidence, uint32_t current_time,
                        afsk_message_t *msg) {
    bool message_ready = false;
    bool need_finalize = false;
    bool usable = max_power > dec->signal_threshold && confidence >= CONFIDENCE_MIN;

    switch (dec->state) {
        case WAITING_FOR_PREAMBLE:
            if (bit && usable) {
                dec->ones_count++;
                if (dec->ones_count > dec->preamble_best) {
                    dec->preamble_best = dec->ones_count;
                }
                if (AFSK_VERBOSE && dec->ones_count % PREAMBLE_LOG_EVERY == 0) {
                    printf("[PREAMBLE] %d/%d (conf: %d%%, glitches: %d)\n",
                           dec->ones_count, PREAMBLE_DETECT, confidence,
                           dec->preamble_glitches);
                }
                if (dec->ones_count >= PREAMBLE_DETECT) {
                    dec->state = WAITING_FOR_START;
                    dec->ones_count = 0;
                    dec->start_wait = 0;
                    dec->start_dropout = 0;
                }
            } else if (dec->ones_count > 0) {
                dec->preamble_glitches++;
                dec->ones_count -= PREAMBLE_GLITCH_PENALTY;
                if (dec->ones_count < 0) {
                    dec->ones_count = 0;
                    if (dec->preamble_best > PREAMBLE_LOG_EVERY) {
                        AFSK_DIAG("[RX] Preamble lost at %d/%d after %d glitch(es)",
                                  dec->preamble_best, PREAMBLE_DETECT,
                                  dec->preamble_glitches);
                    }
                    dec->preamble_glitches = 0;
                    dec->preamble_best = 0;
                }
            }
            break;

        case WAITING_FOR_START:
            /* The bit-clock only re-locks on a mark<->space transition, so at
             * the (transition-free) preamble->start boundary the sampling phase
             * can still land on a trailing preamble mark. Tolerate a few extra
             * mark bits and wait for the actual START (space) instead of
             * discarding the frame. */
            if (usable) {
                dec->start_dropout = 0;
                if (!bit) {
                    dec->state = RECEIVING;
                    dec->bit_counter = 0;
                    dec->current_byte = 0;
                    dec->rx_index = 0;
                } else if (++dec->start_wait > START_MARK_TOLERANCE) {
                    abort_frame(dec, "no START within the preamble");
                }
            } else {
                /* Both counters advance on every unusable bit: a dropout is
                 * also time spent waiting for START. */
                dec->start_dropout++;
                dec->start_wait++;
                if (dec->start_dropout > START_DROPOUT_TOLERANCE ||
                    dec->start_wait > START_MARK_TOLERANCE) {
                    abort_frame(dec, "signal lost before START");
                }
            }
            break;

        case RECEIVING:
            if (dec->bit_counter < 8) {
                if (bit) dec->current_byte |= (1 << dec->bit_counter);
                dec->bit_counter++;
            } else {
                /* 9th slot is the stop bit; accept the data byte on a
                   confident bit regardless of stop-bit polarity.
                   If we have already filled the receive buffer, there is no
                   room for the next byte (including the CRC), so abort. */
                if (dec->rx_index >= MAX_MESSAGE_LEN - 1) {
                    abort_frame(dec, "payload overflow");
                    return false;
                }
                if (confidence >= CONFIDENCE_MIN) {
                    dec->rx_buffer[dec->rx_index++] = dec->current_byte;
                }
                dec->state = WAITING_FOR_NEXT_BYTE;
                dec->bit_counter = 0;
                dec->current_byte = 0;
            }
            break;

        /* Frame layout: N payload bytes followed by one CRC-8 byte, each in a
         * UART-style slot. There is no length field and no end marker, so the
         * frame is finalized when the next START never comes - either right
         * here (a non-START slot with at least a payload byte and the CRC byte
         * already decoded, rx_index > 1) or below on SIGNAL_TIMEOUT_MS of
         * silence. The last decoded byte is then taken as the CRC. */
        case WAITING_FOR_NEXT_BYTE:
            if (!bit && usable) {
                dec->state = RECEIVING;
                dec->bit_counter = 0;
                dec->current_byte = 0;
            } else if (dec->rx_index > 1) {
                need_finalize = true;
            } else {
                /* Only the CRC byte (or nothing) was decoded: there is no
                 * payload to hand over, the frame is simply gone */
                abort_frame(dec, "frame ended before any payload byte");
            }
            break;
    }

    if (need_finalize || (current_time - dec->last_signal_time > SIGNAL_TIMEOUT_MS)) {
        if (dec->state != WAITING_FOR_PREAMBLE && dec->rx_index > 1) {
            uint8_t received_crc = dec->rx_buffer[dec->rx_index - 1];
            uint8_t calculated_crc = afsk_crc8(dec->rx_buffer, dec->rx_index - 1);
            msg->length = dec->rx_index - 1;
            memcpy(msg->text, dec->rx_buffer, msg->length);
            msg->text[msg->length] = '\0';
            msg->received_crc = received_crc;
            msg->calculated_crc = calculated_crc;
            msg->crc_valid = (received_crc == calculated_crc);
            message_ready = true;
            reset_frame_state(dec);
        }
        dec->last_signal_time = current_time;
    }

    return message_ready;
}

bool afsk_decoder_process_sample(afsk_decoder_t *dec,
                                 int32_t sample,
                                 afsk_message_t *msg) {
    uint32_t current_time = esp_timer_get_time() / 1000;
    float s = (float)sample / SAMPLE_FULL_SCALE;

    dec->dc_level += DC_BLOCK_ALPHA * (s - dec->dc_level);
    s -= dec->dc_level;

    float mag = (s < 0.0f) ? -s : s;
    if (mag > dec->peak_level) dec->peak_level = mag;

    /* --- Quadrature mix with each tone's NCO --- */
    uint32_t im = dec->phase_mark >> (32 - SINE_TABLE_BITS);
    float c_m = sine_table[(im + SINE_TABLE_QUARTER) & SINE_TABLE_MASK];
    float q_m = sine_table[im & SINE_TABLE_MASK];
    dec->phase_mark += dec->inc_mark;

    uint32_t is = dec->phase_space >> (32 - SINE_TABLE_BITS);
    float c_s = sine_table[(is + SINE_TABLE_QUARTER) & SINE_TABLE_MASK];
    float q_s = sine_table[is & SINE_TABLE_MASK];
    dec->phase_space += dec->inc_space;

    /* --- Matched filter: integrate each product over one bit --- */
    const float prod[4] = { s * c_m, s * q_m, s * c_s, s * q_s };
    float *oldest = dec->mf_hist[dec->mf_idx];
    for (int k = 0; k < 4; k++) {
        dec->mf_sum[k] += prod[k] - oldest[k];
        oldest[k] = prod[k];
    }
    if (++dec->mf_idx >= MF_TAPS) dec->mf_idx = 0;

    const float inv_len = 1.0f / (float)MF_TAPS;
    dec->mI = dec->mf_sum[0] * inv_len;
    dec->mQ = dec->mf_sum[1] * inv_len;
    dec->sI = dec->mf_sum[2] * inv_len;
    dec->sQ = dec->mf_sum[3] * inv_len;

    float mark_env = dec->mI * dec->mI + dec->mQ * dec->mQ;
    float space_env = dec->sI * dec->sI + dec->sQ * dec->sQ;
    float demod = mark_env - space_env;

    float max_power = (mark_env > space_env) ? mark_env : space_env;
    bool signal_present = max_power > dec->signal_threshold;

    /* Advance the bit clock and sample the bit when the accumulator crosses the
     * (delay-compensated) sampling point set in init.
     * The clock is advanced (and the sampling instant detected) before the
     * transition pull below, so the crossing test stays monotonic. */
    uint32_t prev_pll = dec->pll;
    dec->pll += dec->pll_step;
    bool sample_now = (prev_pll < dec->sample_point) && (dec->pll >= dec->sample_point);

    /* --- DPLL: nudge clock phase toward each detected transition ---
     * A transition marks a bit boundary, so the reference phase here is 0,
     * not sample_point: pulling the accumulator toward 0 keeps the later
     * sample_point crossing in the middle of the bit.  Retargeting this at
     * sample_point instead samples right on the transition, where the
     * matched filter has not settled yet, and no frame decodes at all. */
    bool cur_sign = demod > 0.0f;
    if (signal_present && dec->have_prev_sign && cur_sign != dec->prev_sign) {
        dec->pll = (uint32_t)((float)(int32_t)dec->pll * PLL_INERTIA);
    }
    dec->prev_sign = cur_sign;
    dec->have_prev_sign = true;

    if (!sample_now) {
        return false;
    }

    bool bit = demod > 0.0f;
    float min_env = (mark_env < space_env) ? mark_env : space_env;
    int confidence = (max_power > 1e-9f)
                         ? (int)((max_power - min_env) * 100.0f / max_power)
                         : 0;

    dec->noise_floor = dec->noise_floor * 0.95f + min_env * 0.05f;
    dec->signal_threshold = dec->noise_floor * MIN_SIGNAL_RATIO;
    if (dec->signal_threshold < MIN_TONE_POWER) {
        dec->signal_threshold = MIN_TONE_POWER;
    }
    if (max_power > dec->signal_threshold) {
        dec->last_signal_time = current_time;
    }

    if (mark_env > dec->peak_mark) dec->peak_mark = mark_env;
    if (space_env > dec->peak_space) dec->peak_space = space_env;
#ifdef LEVEL_REPORT_MS
    if (current_time - dec->level_report_time >= LEVEL_REPORT_MS) {
        if (dec->state == WAITING_FOR_PREAMBLE) {
            printf("[LEVEL] peak: %.1f dBFS | mark: %.1f | space: %.1f | squelch: %.1f dBFS\n",
                   level_dbfs(dec->peak_level),
                   level_dbfs(2.0f * sqrtf(dec->peak_mark)),
                   level_dbfs(2.0f * sqrtf(dec->peak_space)),
                   level_dbfs(MIN_TONE_AMPLITUDE));
        }
        dec->level_report_time = current_time;
        dec->peak_level = 0.0f;
        dec->peak_mark = 0.0f;
        dec->peak_space = 0.0f;
    }
#endif

    return process_bit(dec, bit, max_power, confidence, current_time, msg);
}
