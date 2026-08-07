#include "midi_sysex_reset.h"

#include <stddef.h>

static const uint8_t reset_session_message[] = {
    0xf0u, 0x7du, 0x4du, 0x42u, 0x01u, 0x01u, 0xf7u,
};

void midi_sysex_reset_parser_init(midi_sysex_reset_parser *parser) {
    parser->match_index = 0u;
}

static midi_sysex_action consume_byte(midi_sysex_reset_parser *parser,
                                      uint8_t value) {
    if (value == reset_session_message[parser->match_index]) {
        ++parser->match_index;
        if (parser->match_index == sizeof(reset_session_message)) {
            parser->match_index = 0u;
            return MIDI_SYSEX_ACTION_RESET_SESSION;
        }
        return MIDI_SYSEX_ACTION_NONE;
    }

    parser->match_index = value == reset_session_message[0] ? 1u : 0u;
    return MIDI_SYSEX_ACTION_NONE;
}

midi_sysex_action midi_sysex_reset_process_usb_packet(
    midi_sysex_reset_parser *parser, const uint8_t packet[4]) {
    const uint8_t cin = packet[0] & 0x0fu;
    uint8_t byte_count;
    uint8_t index;

    switch (cin) {
        case 0x04u: byte_count = 3u; break;
        case 0x05u: byte_count = 1u; break;
        case 0x06u: byte_count = 2u; break;
        case 0x07u: byte_count = 3u; break;
        case 0x0fu:
            /* MIDI real-time messages may be interleaved with SysEx. */
            return MIDI_SYSEX_ACTION_NONE;
        default:
            parser->match_index = 0u;
            return MIDI_SYSEX_ACTION_NONE;
    }

    for (index = 0u; index < byte_count; ++index) {
        const midi_sysex_action action = consume_byte(parser, packet[index + 1u]);
        if (action != MIDI_SYSEX_ACTION_NONE) {
            /* This seven-byte command must end in a one-byte SysEx-end packet. */
            if (cin == 0x05u && index == 0u) return action;
            parser->match_index = 0u;
        }
    }
    return MIDI_SYSEX_ACTION_NONE;
}
