#ifndef I2S_CAPTURE_H
#define I2S_CAPTURE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

void i2s_capture_init(void);
void i2s_capture_tick_1ms(void);
void i2s_capture_task(void);
size_t i2s_capture_available(void);
size_t i2s_capture_read(int16_t *stereo_samples, size_t frame_count);
void i2s_capture_discard(void);
bool i2s_capture_clock_valid(void);

#endif
