#ifndef MIDI_SYSEX_RESET_H
#define MIDI_SYSEX_RESET_H

#include <stdint.h>

typedef enum midi_sysex_action {
    MIDI_SYSEX_ACTION_NONE = 0,
    MIDI_SYSEX_ACTION_RESET_SESSION = 1,
} midi_sysex_action;

typedef struct midi_sysex_reset_parser {
    uint8_t match_index;
} midi_sysex_reset_parser;

void midi_sysex_reset_parser_init(midi_sysex_reset_parser *parser);
midi_sysex_action midi_sysex_reset_process_usb_packet(
    midi_sysex_reset_parser *parser, const uint8_t packet[4]);

#endif
