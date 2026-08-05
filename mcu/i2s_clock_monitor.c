#include "i2s_clock_monitor.h"

#include <stddef.h>

/* Per-millisecond counts may move across timer boundaries, so determine rate
 * from an eight-millisecond sum. A nominal source contributes 384 frames; the
 * +/-2 tolerance accepts boundary jitter while rejecting sustained 47/49 kHz
 * clocks that the fixed-48-kHz USB declaration must not label as valid. A
 * completely stopped producer still invalidates after four 1 ms ticks. */
#define I2S_CLOCK_WINDOW_TICKS 8u
#define I2S_CLOCK_WINDOW_MIN_FRAMES 382u
#define I2S_CLOCK_WINDOW_MAX_FRAMES 386u
#define I2S_CLOCK_STOPPED_TICKS 4u

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

    if (monitor == NULL) return;
    if (!monitor->initialized) {
        i2s_clock_monitor_init(monitor, frame_count);
        return;
    }

    /* Unsigned subtraction intentionally handles the 32-bit producer counter
     * wrapping after long uptime. Only a one-millisecond delta is interpreted. */
    elapsed_frames = frame_count - monitor->previous_frame_count;
    monitor->previous_frame_count = frame_count;

    if (elapsed_frames == 0u) {
        monitor->window_frame_count = 0u;
        monitor->window_tick_count = 0u;
        if (monitor->stopped_tick_count < I2S_CLOCK_STOPPED_TICKS) {
            ++monitor->stopped_tick_count;
        }
        if (monitor->stopped_tick_count >= I2S_CLOCK_STOPPED_TICKS) {
            if (monitor->seen_valid) monitor->recovery_pending = true;
            monitor->valid = false;
        }
        return;
    }

    monitor->stopped_tick_count = 0u;
    monitor->window_frame_count += elapsed_frames;
    ++monitor->window_tick_count;
    if (monitor->window_tick_count >= I2S_CLOCK_WINDOW_TICKS) {
        monitor->valid =
            monitor->window_frame_count >= I2S_CLOCK_WINDOW_MIN_FRAMES &&
            monitor->window_frame_count <= I2S_CLOCK_WINDOW_MAX_FRAMES;
        if (monitor->valid) monitor->seen_valid = true;
        monitor->window_frame_count = 0u;
        monitor->window_tick_count = 0u;
    }
}

bool i2s_clock_monitor_valid(const i2s_clock_monitor *monitor) {
    return monitor != NULL && monitor->valid;
}

bool i2s_clock_monitor_recovery_ready(const i2s_clock_monitor *monitor) {
    return monitor != NULL && monitor->valid && monitor->recovery_pending;
}
