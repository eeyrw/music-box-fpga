/* Complete firmware integration example for the compact-v2 MSF2 runtime.
 *
 * The example covers the complete path from MIDI callbacks, through voice and
 * modulation processing, to command serialization and synchronous SPI output.
 * It is compiled by the host verification target. A real board only needs to
 * supply asset storage, three small HAL functions, and a 1 ms timer interrupt.
 */

#include "msf2.h"
#include "msf2_example.h"

#include <stddef.h>
#include <stdint.h>

#define APP_VOICE_COUNT 128u
#define APP_SPI_COMMAND_OPCODE UINT8_C(0xa5)
#define APP_MAX_COMMAND_PAYLOAD_WORDS 16u
#define APP_MAX_COMMAND_WORDS (1u + APP_MAX_COMMAND_PAYLOAD_WORDS)
#define APP_MAX_SPI_FRAME_BYTES (4u + 4u * APP_MAX_COMMAND_WORDS)

/* The linker script may expose an MSF2 blob stored in internal flash or XIP
 * memory. Replace these symbols with the selected MCU's asset mechanism. */
extern const uint8_t app_msf2_image_start[];
extern const uint8_t app_msf2_image_end[];

/* Board HAL: transmit one complete buffer using SPI mode 0 (CPOL=0, CPHA=0),
 * MSB first, on the FPGA command-port chip select.
 *
 * CS must go low before byte zero and stay low until the final byte has been
 * clocked. This call must be synchronous: bytes points to a stack buffer which
 * becomes invalid when the function returns. A DMA-based HAL must therefore
 * wait for completion here, or first copy the frame to a DMA-owned queue.
 * Return zero after a complete successful transfer and nonzero on failure. */
extern int platform_spi_write_mode0_cs0(const uint8_t *bytes,
                                        size_t byte_count);
extern uint32_t platform_irq_save(void);
extern void platform_irq_restore(uint32_t state);

/* Update CRC-16/CCITT-FALSE with one byte. This compact bitwise version uses no
 * lookup table: polynomial 0x1021, initial value 0xffff, no reflection, and no
 * final XOR. SPI traffic is sparse enough that saving ROM is usually preferable
 * to a 512-byte CRC table on a small MCU. */
static uint16_t app_crc16_byte(uint16_t crc, uint8_t byte) {
    uint8_t bit;
    crc ^= (uint16_t)byte << 8;
    for (bit = 0u; bit < 8u; ++bit) {
        if ((crc & UINT16_C(0x8000)) != 0u) {
            crc = (uint16_t)((uint16_t)(crc << 1) ^ UINT16_C(0x1021));
        } else {
            crc = (uint16_t)(crc << 1);
        }
    }
    return crc;
}

/* Convert one complete runtime command into the FPGA SPI wire format:
 *
 *   [0]       0xa5 command-transaction opcode
 *   [1]       number of 32-bit command words
 *   [2..3]    CRC16, high byte first
 *   [4..end]  command words, every word high byte first
 *
 * CRC covers byte [1] and all serialized words; it does not cover 0xa5. The
 * runtime invokes its sink once per complete command. The low byte of word[0]
 * is the command payload length, so it must equal word_count - 1. */
static int platform_enqueue_command(const uint32_t *words,
                                    uint8_t word_count) {
    uint8_t frame[APP_MAX_SPI_FRAME_BYTES];
    uint16_t crc = UINT16_C(0xffff);
    uint8_t payload_words;
    uint8_t word_index;
    size_t frame_index;

    if (words == NULL || word_count == 0u ||
        word_count > APP_MAX_COMMAND_WORDS) {
        return -1;
    }
    payload_words = (uint8_t)(words[0] & UINT32_C(0xff));
    if (payload_words > APP_MAX_COMMAND_PAYLOAD_WORDS ||
        word_count != (uint8_t)(payload_words + 1u)) {
        return -1;
    }

    crc = app_crc16_byte(crc, word_count);
    for (word_index = 0u; word_index < word_count; ++word_index) {
        const uint32_t word = words[word_index];
        crc = app_crc16_byte(crc, (uint8_t)(word >> 24));
        crc = app_crc16_byte(crc, (uint8_t)(word >> 16));
        crc = app_crc16_byte(crc, (uint8_t)(word >> 8));
        crc = app_crc16_byte(crc, (uint8_t)word);
    }

    frame[0] = APP_SPI_COMMAND_OPCODE;
    frame[1] = word_count;
    frame[2] = (uint8_t)(crc >> 8);
    frame[3] = (uint8_t)crc;
    frame_index = 4u;
    for (word_index = 0u; word_index < word_count; ++word_index) {
        const uint32_t word = words[word_index];
        frame[frame_index++] = (uint8_t)(word >> 24);
        frame[frame_index++] = (uint8_t)(word >> 16);
        frame[frame_index++] = (uint8_t)(word >> 8);
        frame[frame_index++] = (uint8_t)word;
    }

    return platform_spi_write_mode0_cs0(frame, frame_index);
}

static msf2_view app_view;
static msf2_runtime app_runtime;
static msf2_channel_state app_channels[MSF2_CHANNEL_COUNT];
static msf2_voice_state app_voices[APP_VOICE_COUNT];
static uint16_t app_free_stack[APP_VOICE_COUNT];

/* Bank and program selection are MIDI policy, not MSF2 asset state. Keeping
 * them here also makes Program Change independent from active voice state. */
static uint16_t app_bank[MSF2_CHANNEL_COUNT];
static uint8_t app_program[MSF2_CHANNEL_COUNT];

/* The interrupt only increments this counter. The main control loop performs
 * all runtime mutation, so MIDI events and control ticks cannot race. */
static volatile uint32_t app_pending_ms_ticks;

static int app_command_sink(void *context, const uint32_t *words,
                            uint8_t word_count) {
    (void)context;
    return platform_enqueue_command(words, word_count);
}

int app_synth_init(void) {
    const size_t image_size = (size_t)(app_msf2_image_end - app_msf2_image_start);
    msf2_result result = msf2_view_init(&app_view, app_msf2_image_start, image_size);
    if (result != MSF2_OK) {
        /* Fail closed: do not accept MIDI or fall back to parsing SF2. */
        return -(int)result;
    }
    result = msf2_runtime_init(&app_runtime, &app_view, app_channels,
                               app_voices, app_free_stack, APP_VOICE_COUNT,
                               app_command_sink, NULL);
    return result == MSF2_OK ? 0 : -(int)result;
}

/* Call from the selected MCU's 1 ms timer ISR. A wrapping unsigned counter is
 * sufficient; the main loop consumes one unit at a time. */
void app_synth_1ms_timer_isr(void) {
    ++app_pending_ms_ticks;
}

/* Call regularly from the serialized MIDI/control task. A production system
 * may cap the loop and report overload if command transport cannot catch up. */
int app_synth_service(void) {
    uint32_t ticks;
    uint32_t irq_state = platform_irq_save();
    ticks = app_pending_ms_ticks;
    app_pending_ms_ticks = 0u;
    platform_irq_restore(irq_state);
    while (ticks-- != 0u) {
        msf2_result result;
        result = msf2_runtime_control_tick(&app_runtime);
        if (result != MSF2_OK) return -(int)result;
    }
    return 0;
}

int app_midi_note_on(uint8_t channel, uint8_t key, uint8_t velocity) {
    uint8_t started_layers = 0u;
    msf2_result result;
    if (channel >= MSF2_CHANNEL_COUNT) return -(int)MSF2_ERR_ARGUMENT;
    result = msf2_runtime_note_on(&app_runtime, channel, app_program[channel],
                                  app_bank[channel], key, velocity,
                                  &started_layers);
    if (result != MSF2_OK) return -(int)result;
    return (int)started_layers; /* Zero means the selected preset/key was unmapped. */
}

int app_midi_note_off(uint8_t channel, uint8_t key) {
    return -(int)msf2_runtime_note_off(&app_runtime, channel, key);
}

int app_midi_control_change(uint8_t channel, uint8_t controller, uint8_t value) {
    if (channel >= MSF2_CHANNEL_COUNT || controller > 127u || value > 127u) {
        return -(int)MSF2_ERR_ARGUMENT;
    }

    /* Bank Select is consumed by the application and also forwarded so an SF2
     * modulator that explicitly references CC0/32 observes the MIDI value. */
    if (controller == 0u) {
        app_bank[channel] = (uint16_t)(((uint16_t)value << 7) |
                                      (app_bank[channel] & UINT16_C(0x007f)));
    } else if (controller == 32u) {
        app_bank[channel] = (uint16_t)((app_bank[channel] & UINT16_C(0x3f80)) |
                                      value);
    }
    return -(int)msf2_runtime_control_change(&app_runtime, channel,
                                             controller, value);
}

void app_midi_program_change(uint8_t channel, uint8_t program) {
    if (channel < MSF2_CHANNEL_COUNT && program <= 127u) {
        app_program[channel] = program;
    }
}

int app_midi_pitch_bend(uint8_t channel, uint8_t lsb, uint8_t msb) {
    const int32_t unsigned_value = ((int32_t)(msb & 0x7fu) << 7) | (lsb & 0x7fu);
    return -(int)msf2_runtime_pitch_bend(&app_runtime, channel,
                                        (int16_t)(unsigned_value - 8192));
}

int app_midi_channel_pressure(uint8_t channel, uint8_t pressure) {
    return -(int)msf2_runtime_channel_pressure(&app_runtime, channel, pressure);
}

int app_midi_key_pressure(uint8_t channel, uint8_t key, uint8_t pressure) {
    return -(int)msf2_runtime_key_pressure(&app_runtime, channel, key, pressure);
}

/* RPN/NRPN is deliberately absent here. A complete MIDI policy layer must
 * track CC101/100 or CC99/98 selection plus CC6/38/96/97 data operations, then
 * update the corresponding runtime tuning/controller state through an explicit
 * API. Forwarding those raw CC values alone is not RPN/NRPN interpretation. */
