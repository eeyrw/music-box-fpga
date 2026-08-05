#ifndef MSF2_EXAMPLE_H
#define MSF2_EXAMPLE_H

#include <stdint.h>

int app_synth_init(void);
void app_synth_1ms_timer_isr(void);
int app_synth_service(void);
int app_midi_note_on(uint8_t channel, uint8_t key, uint8_t velocity);
int app_midi_note_off(uint8_t channel, uint8_t key);
int app_midi_control_change(uint8_t channel, uint8_t controller, uint8_t value);
void app_midi_program_change(uint8_t channel, uint8_t program);
int app_midi_pitch_bend(uint8_t channel, uint8_t lsb, uint8_t msb);
int app_midi_channel_pressure(uint8_t channel, uint8_t pressure);
int app_midi_key_pressure(uint8_t channel, uint8_t key, uint8_t pressure);

#endif
