#include "midi_sysex_reset.h"

#include <stdio.h>

static int expect_no_action(midi_sysex_reset_parser *parser,
                            const uint8_t packet[4]) {
    return midi_sysex_reset_process_usb_packet(parser, packet) ==
           MIDI_SYSEX_ACTION_NONE;
}

int main(void) {
    midi_sysex_reset_parser parser;

    midi_sysex_reset_parser_init(&parser);
    if (!expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0xf0u, 0x7du, 0x4du}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0x42u, 0x01u, 0x01u}) ||
        midi_sysex_reset_process_usb_packet(
            &parser, (const uint8_t[4]){0x05u, 0xf7u, 0u, 0u}) !=
            MIDI_SYSEX_ACTION_RESET_SESSION) {
        fputs("complete reset-session SysEx was not recognized\n", stderr);
        return 1;
    }

    midi_sysex_reset_parser_init(&parser);
    if (!expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0xf0u, 0x7du, 0x4du}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x0fu, 0xf8u, 0u, 0u}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0x42u, 0x01u, 0x01u}) ||
        midi_sysex_reset_process_usb_packet(
            &parser, (const uint8_t[4]){0x05u, 0xf7u, 0u, 0u}) !=
            MIDI_SYSEX_ACTION_RESET_SESSION) {
        fputs("real-time event incorrectly interrupted SysEx\n", stderr);
        return 1;
    }

    midi_sysex_reset_parser_init(&parser);
    if (!expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0xf0u, 0x7du, 0x4du}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0x42u, 0x01u, 0x02u}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x05u, 0xf7u, 0u, 0u})) {
        fputs("wrong SysEx command was accepted\n", stderr);
        return 1;
    }

    midi_sysex_reset_parser_init(&parser);
    if (!expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0xf0u, 0x7du, 0x4du}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x09u, 0x90u, 60u, 100u}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0x42u, 0x01u, 0x01u}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x05u, 0xf7u, 0u, 0u})) {
        fputs("channel event did not cancel partial SysEx\n", stderr);
        return 1;
    }

    midi_sysex_reset_parser_init(&parser);
    if (!expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0xf0u, 0x7du, 0x4du}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0x42u, 0x01u, 0x01u}) ||
        !expect_no_action(&parser,
                          (const uint8_t[4]){0x04u, 0xf7u, 0u, 0u})) {
        fputs("SysEx ending with the wrong CIN was accepted\n", stderr);
        return 1;
    }

    puts("PASS: MCU reset-session System Exclusive parser");
    return 0;
}
