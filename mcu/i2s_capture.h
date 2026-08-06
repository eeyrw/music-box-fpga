#ifndef I2S_CAPTURE_H
#define I2S_CAPTURE_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

void i2s_capture_init(void);
void i2s_capture_tick_1ms(void);
void i2s_capture_advance_ms(uint32_t elapsed_ms);
void i2s_capture_advance_us(uint32_t elapsed_us);
void i2s_capture_task(void);
size_t i2s_capture_available(void);
size_t i2s_capture_read(int16_t *stereo_samples, size_t frame_count);
void i2s_capture_discard(void);
bool i2s_capture_clock_valid(void);
uint32_t i2s_capture_rx_stall_count(void);
uint32_t i2s_capture_overrun_count(void);
uint32_t i2s_capture_lost_frame_count(void);
void i2s_capture_reset_diagnostics(void);

#endif
