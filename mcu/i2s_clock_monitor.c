#include "i2s_clock_monitor.h"

#include <stddef.h>

/* A nominal 48 kHz source advances by 48 frames in a 1 ms observation window.
 * Integer tick timing and the short DMA block-rearm interval can move one or
 * two frames across a boundary, so accept 46..50. This rejects absent clocks,
 * common 44.1/96 kHz mistakes, and random activity on floating wiring. */
#define I2S_CLOCK_MIN_FRAMES_PER_MS 46u
#define I2S_CLOCK_MAX_FRAMES_PER_MS 50u
#define I2S_CLOCK_ACQUIRE_TICKS 3u
#define I2S_CLOCK_LOSS_TICKS 4u

void i2s_clock_monitor_init(i2s_clock_monitor *monitor,
                            uint32_t frame_count) {
    if (monitor == NULL) return;
    *monitor = (i2s_clock_monitor){
        .previous_frame_count = frame_count,
        .initialized = true,
    };
}

void i2s_clock_monitor_tick(i2s_clock_monitor *monitor,
                            uint32_t frame_count) {
    uint32_t elapsed_frames;
    bool cadence_ok;

    if (monitor == NULL) return;
    if (!monitor->initialized) {
        i2s_clock_monitor_init(monitor, frame_count);
        return;
    }

    /* Unsigned subtraction intentionally handles the 32-bit producer counter
     * wrapping after long uptime. Only a one-millisecond delta is interpreted. */
    elapsed_frames = frame_count - monitor->previous_frame_count;
    monitor->previous_frame_count = frame_count;
    cadence_ok = elapsed_frames >= I2S_CLOCK_MIN_FRAMES_PER_MS &&
                 elapsed_frames <= I2S_CLOCK_MAX_FRAMES_PER_MS;

    if (cadence_ok) {
        monitor->bad_ticks = 0u;
        if (monitor->good_ticks < I2S_CLOCK_ACQUIRE_TICKS) {
            ++monitor->good_ticks;
        }
        if (monitor->good_ticks >= I2S_CLOCK_ACQUIRE_TICKS) {
            monitor->valid = true;
        }
    } else {
        monitor->good_ticks = 0u;
        if (monitor->bad_ticks < I2S_CLOCK_LOSS_TICKS) {
            ++monitor->bad_ticks;
        }
        if (monitor->bad_ticks >= I2S_CLOCK_LOSS_TICKS) {
            monitor->valid = false;
        }
    }
}

bool i2s_clock_monitor_valid(const i2s_clock_monitor *monitor) {
    return monitor != NULL && monitor->valid;
}
