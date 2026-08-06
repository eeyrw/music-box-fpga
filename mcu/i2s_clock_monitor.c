#include "i2s_clock_monitor.h"

#include <stddef.h>

/* Main-loop sampling is not phase-locked to the 1 ms alarm. Measure against
 * the actual timer interval, and use a long enough window that the joined
 * eight-word PIO RX FIFO can change occupancy without looking like a 47 or
 * 49 kHz source. At 16 ms those rates differ from 48 kHz by 16 frames. */
#define I2S_CLOCK_WINDOW_US 16000u
#define I2S_CLOCK_FRAME_TOLERANCE 10u
#define I2S_CLOCK_STOPPED_US 4000u

void i2s_clock_monitor_init(i2s_clock_monitor *monitor,
                            uint32_t frame_count) {
    if (monitor == NULL) return;
    *monitor = (i2s_clock_monitor){
        .previous_frame_count = frame_count,
        .initialized = true,
    };
}

void i2s_clock_monitor_advance(i2s_clock_monitor *monitor,
                               uint32_t frame_count, uint32_t elapsed_ms) {
    i2s_clock_monitor_advance_us(monitor, frame_count, elapsed_ms * 1000u);
}

void i2s_clock_monitor_advance_us(i2s_clock_monitor *monitor,
                                  uint32_t frame_count,
                                  uint32_t elapsed_us) {
    uint32_t elapsed_frames;

    if (monitor == NULL || elapsed_us == 0u) return;
    if (!monitor->initialized) {
        i2s_clock_monitor_init(monitor, frame_count);
        return;
    }

    /* Unsigned subtraction intentionally handles the 32-bit producer counter
     * wrapping after long uptime. elapsed_ms allows a delayed main loop to
     * measure one real interval rather than replaying synthetic 1 ms samples. */
    elapsed_frames = frame_count - monitor->previous_frame_count;
    monitor->previous_frame_count = frame_count;

    if (elapsed_frames == 0u) {
        monitor->window_frame_count = 0u;
        monitor->window_elapsed_us = 0u;
        if (elapsed_us >= I2S_CLOCK_STOPPED_US -
                              monitor->stopped_elapsed_us) {
            monitor->stopped_elapsed_us = I2S_CLOCK_STOPPED_US;
        } else {
            monitor->stopped_elapsed_us += elapsed_us;
        }
        if (monitor->stopped_elapsed_us >= I2S_CLOCK_STOPPED_US) {
            if (monitor->seen_valid) monitor->recovery_pending = true;
            monitor->valid = false;
        }
        return;
    }

    monitor->stopped_elapsed_us = 0u;
    monitor->window_frame_count += elapsed_frames;
    monitor->window_elapsed_us += elapsed_us;
    if (monitor->window_elapsed_us >= I2S_CLOCK_WINDOW_US) {
        const uint32_t expected_frames =
            (monitor->window_elapsed_us * 48u + 500u) / 1000u;
        monitor->valid = monitor->window_frame_count >=
                             expected_frames - I2S_CLOCK_FRAME_TOLERANCE &&
                         monitor->window_frame_count <=
                             expected_frames + I2S_CLOCK_FRAME_TOLERANCE;
        if (monitor->valid) monitor->seen_valid = true;
        monitor->window_frame_count = 0u;
        monitor->window_elapsed_us = 0u;
    }
}

void i2s_clock_monitor_tick(i2s_clock_monitor *monitor,
                            uint32_t frame_count) {
    i2s_clock_monitor_advance(monitor, frame_count, 1u);
}

bool i2s_clock_monitor_valid(const i2s_clock_monitor *monitor) {
    return monitor != NULL && monitor->valid;
}

bool i2s_clock_monitor_recovery_ready(const i2s_clock_monitor *monitor) {
    return monitor != NULL && monitor->valid && monitor->recovery_pending;
}
