#ifndef I2S_CLOCK_MONITOR_H
#define I2S_CLOCK_MONITOR_H

#include <stdbool.h>
#include <stdint.h>

/* The capture PIO emits one DMA word per stereo frame. Sampling its monotonic
 * producer count once per millisecond therefore measures the external LRCLK
 * rate without depending on USB control-request timing. */
typedef struct i2s_clock_monitor {
    uint32_t previous_frame_count;
    uint32_t window_frame_count;
    uint32_t window_elapsed_us;
    uint32_t stopped_elapsed_us;
    bool initialized;
    bool valid;
    bool seen_valid;
    bool recovery_pending;
} i2s_clock_monitor;

void i2s_clock_monitor_init(i2s_clock_monitor *monitor,
                            uint32_t frame_count);
void i2s_clock_monitor_tick(i2s_clock_monitor *monitor,
                            uint32_t frame_count);
void i2s_clock_monitor_advance(i2s_clock_monitor *monitor,
                               uint32_t frame_count, uint32_t elapsed_ms);
void i2s_clock_monitor_advance_us(i2s_clock_monitor *monitor,
                                  uint32_t frame_count,
                                  uint32_t elapsed_us);
bool i2s_clock_monitor_valid(const i2s_clock_monitor *monitor);
/* True after a previously valid source stopped and a valid 48 kHz cadence has
 * returned. The hardware owner must then restart its frame synchronizer and
 * reinitialize this monitor before publishing Clock Validity again. */
bool i2s_clock_monitor_recovery_ready(const i2s_clock_monitor *monitor);

#endif
