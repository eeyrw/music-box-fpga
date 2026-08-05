#ifndef I2S_CLOCK_MONITOR_H
#define I2S_CLOCK_MONITOR_H

#include <stdbool.h>
#include <stdint.h>

/* The capture PIO emits one DMA word per stereo frame. Sampling its monotonic
 * producer count once per millisecond therefore measures the external LRCLK
 * rate without depending on USB control-request timing. */
typedef struct i2s_clock_monitor {
    uint32_t previous_frame_count;
    uint8_t good_ticks;
    uint8_t bad_ticks;
    bool initialized;
    bool valid;
} i2s_clock_monitor;

void i2s_clock_monitor_init(i2s_clock_monitor *monitor,
                            uint32_t frame_count);
void i2s_clock_monitor_tick(i2s_clock_monitor *monitor,
                            uint32_t frame_count);
bool i2s_clock_monitor_valid(const i2s_clock_monitor *monitor);

#endif
