#ifndef I2S_CAPTURE_H
#define I2S_CAPTURE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

void i2s_capture_init(void);
size_t i2s_capture_available(void);
size_t i2s_capture_read(int16_t *stereo_samples, size_t frame_count);
bool i2s_capture_clock_valid(void);

#endif
