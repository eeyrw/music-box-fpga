#include "tusb.h"

#include "usb_audio_config.h"

#include "pico/unique_id.h"

#include <string.h>

#define USB_VID 0xcafe
#define USB_PID 0x4018
#define AUDIO_TERM_TYPE_DIGITAL_AUDIO_INTERFACE 0x0602
#define MIDI_IAD_DESC_LEN 8

#define AUDIO_STEREO_DESC_LEN \
    (TUD_AUDIO_DESC_IAD_LEN + TUD_AUDIO_DESC_STD_AC_LEN + \
     TUD_AUDIO_DESC_CS_AC_LEN + TUD_AUDIO_DESC_CLK_SRC_LEN + \
     TUD_AUDIO_DESC_INPUT_TERM_LEN + TUD_AUDIO_DESC_OUTPUT_TERM_LEN + \
     2 * TUD_AUDIO_DESC_STD_AS_INT_LEN + TUD_AUDIO_DESC_CS_AS_INT_LEN + \
     TUD_AUDIO_DESC_TYPE_I_FORMAT_LEN + TUD_AUDIO_DESC_STD_AS_ISO_EP_LEN + \
     TUD_AUDIO_DESC_CS_AS_ISO_EP_LEN)

/* UAC2 recording topology (entity direction is relative to the USB audio
 * function, not to the host):
 *
 *   FPGA I2S --[Input Terminal 1: Digital Audio Interface]-->
 *       [Output Terminal 2: USB Streaming] --> AS interface 1 --> EP 0x81
 *                  ^
 *                  +-- Clock Source 3: external FPGA I2S, nominally 48 kHz
 *
 * Interface 0 is AudioControl. Interface 1 has alternate 0 (zero bandwidth)
 * and alternate 1 (stereo PCM stream). The endpoint is asynchronous because
 * its samples are clocked by the FPGA I2S clock rather than USB SOF.
 *
 * The class-specific descriptors encode these additional contracts:
 *
 * - Function category 0x09 identifies the device as a musical instrument.
 * - Clock Source 3 exposes read-only Frequency and Validity controls. It is
 *   associated with Input Terminal 1 because that external I2S input supplies
 *   the sampling clock as well as the audio data.
 * - bAssocTerminal is zero on both terminals. UAC2 reserves that field for a
 *   physical bidirectional pair such as headset microphone + earpiece; the
 *   data path here is expressed by Output Terminal 2 bSourceID = 1.
 * - The AS format is Type I, signed PCM, two 16-bit subslots, front left/right.
 * - EP 0x81 is full-speed isochronous IN, asynchronous, one transaction per
 *   1 ms frame. It accepts short/null packets and reserves 196 bytes so the
 *   firmware can send 47, 48, or 49 stereo frames without changing samples.
 */
#define AUDIO_STEREO_DESCRIPTOR(_itfnum, _stridx, _epin, _epsize) \
    TUD_AUDIO_DESC_IAD(_itfnum, 0x02, 0x00), \
    TUD_AUDIO_DESC_STD_AC(_itfnum, 0x00, _stridx), \
    TUD_AUDIO_DESC_CS_AC(0x0200, AUDIO_FUNC_MUSICAL_INSTRUMENT, \
        TUD_AUDIO_DESC_CLK_SRC_LEN + TUD_AUDIO_DESC_INPUT_TERM_LEN + \
        TUD_AUDIO_DESC_OUTPUT_TERM_LEN, \
        AUDIO_CS_AS_INTERFACE_CTRL_LATENCY_POS), \
    TUD_AUDIO_DESC_CLK_SRC(APP_USB_AUDIO_CLOCK_SOURCE_ID, \
        AUDIO_CLOCK_SOURCE_ATT_EXT_CLK, \
        (AUDIO_CTRL_R << AUDIO_CLOCK_SOURCE_CTRL_CLK_FRQ_POS) | \
        (AUDIO_CTRL_R << AUDIO_CLOCK_SOURCE_CTRL_CLK_VAL_POS), \
        APP_USB_AUDIO_INPUT_TERMINAL_ID, 0x00), \
    TUD_AUDIO_DESC_INPUT_TERM(APP_USB_AUDIO_INPUT_TERMINAL_ID, \
        AUDIO_TERM_TYPE_DIGITAL_AUDIO_INTERFACE, \
        0x00, APP_USB_AUDIO_CLOCK_SOURCE_ID, \
        0x02, AUDIO_CHANNEL_CONFIG_FRONT_LEFT | \
        AUDIO_CHANNEL_CONFIG_FRONT_RIGHT, 0x00, \
        AUDIO_CTRL_R << AUDIO_IN_TERM_CTRL_CONNECTOR_POS, 0x00), \
    TUD_AUDIO_DESC_OUTPUT_TERM(APP_USB_AUDIO_OUTPUT_TERMINAL_ID, \
        AUDIO_TERM_TYPE_USB_STREAMING, 0x00, \
        APP_USB_AUDIO_INPUT_TERMINAL_ID, APP_USB_AUDIO_CLOCK_SOURCE_ID, \
        0x0000, 0x00), \
    TUD_AUDIO_DESC_STD_AS_INT((uint8_t)((_itfnum) + 1), 0x00, 0x00, 0x00), \
    TUD_AUDIO_DESC_STD_AS_INT((uint8_t)((_itfnum) + 1), 0x01, 0x01, 0x00), \
    TUD_AUDIO_DESC_CS_AS_INT(APP_USB_AUDIO_OUTPUT_TERMINAL_ID, \
        AUDIO_CTRL_NONE, AUDIO_FORMAT_TYPE_I, \
        AUDIO_DATA_FORMAT_TYPE_I_PCM, 0x02, \
        AUDIO_CHANNEL_CONFIG_FRONT_LEFT | AUDIO_CHANNEL_CONFIG_FRONT_RIGHT, \
        0x00), \
    TUD_AUDIO_DESC_TYPE_I_FORMAT(0x02, 16), \
    TUD_AUDIO_DESC_STD_AS_ISO_EP(_epin, \
        (uint8_t)(TUSB_XFER_ISOCHRONOUS | TUSB_ISO_EP_ATT_ASYNCHRONOUS | \
                  TUSB_ISO_EP_ATT_DATA), _epsize, 0x01), \
    TUD_AUDIO_DESC_CS_AS_ISO_EP(AUDIO_CS_AS_ISO_DATA_EP_ATT_NON_MAX_PACKETS_OK, \
        AUDIO_CTRL_NONE, AUDIO_CS_AS_ISO_DATA_EP_LOCK_DELAY_UNIT_UNDEFINED, \
        0x0000)

/* EF/02/01 is the USB multi-interface function device tuple. It tells an
 * IAD-aware host to bind each contiguous interface collection as one function
 * instead of attempting to interpret the device class from a single interface. */
static const tusb_desc_device_t device_descriptor = {
    .bLength = sizeof(tusb_desc_device_t),
    .bDescriptorType = TUSB_DESC_DEVICE,
    .bcdUSB = 0x0200,
    .bDeviceClass = TUSB_CLASS_MISC,
    .bDeviceSubClass = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0 = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor = USB_VID,
    .idProduct = USB_PID,
    .bcdDevice = 0x0100,
    .iManufacturer = 1,
    .iProduct = 2,
    .iSerialNumber = 3,
    .bNumConfigurations = 1,
};

enum {
    ITF_AUDIO_CONTROL = 0,
    ITF_AUDIO_STREAMING,
    ITF_MIDI,
    ITF_MIDI_STREAMING,
    ITF_COUNT,
};

/* Configuration layout:
 *
 *   IAD #1: interfaces 0..1, UAC2 stereo recording
 *   IAD #2: interfaces 2..3, MIDI 1.0 AudioControl + MIDIStreaming
 *
 * Endpoint numbers are unique per direction: Audio IN 1, MIDI OUT 2, and MIDI
 * IN 2. A single configuration keeps host enumeration deterministic. */

#define CONFIG_TOTAL_LEN \
    (TUD_CONFIG_DESC_LEN + AUDIO_STEREO_DESC_LEN + MIDI_IAD_DESC_LEN + \
     TUD_MIDI_DESC_LEN)

static const uint8_t configuration_descriptor[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_COUNT, 0, CONFIG_TOTAL_LEN, 0x00, 100),
    AUDIO_STEREO_DESCRIPTOR(ITF_AUDIO_CONTROL, 4, APP_USB_AUDIO_EP_IN,
                            CFG_TUD_AUDIO_EP_SZ_IN),
    /* MIDI 1.0 is a second two-interface Audio-class function. Interface 2 is
     * its empty AudioControl interface; interface 3 is MIDIStreaming with one
     * Embedded IN/OUT Jack pair carried by 64-byte bulk endpoints. */
    MIDI_IAD_DESC_LEN, TUSB_DESC_INTERFACE_ASSOCIATION, ITF_MIDI, 0x02,
        TUSB_CLASS_AUDIO, AUDIO_SUBCLASS_CONTROL,
        AUDIO_FUNC_PROTOCOL_CODE_UNDEF, 5,
    TUD_MIDI_DESCRIPTOR(ITF_MIDI, 5, APP_USB_MIDI_EP_OUT,
                        APP_USB_MIDI_EP_IN, 64),
};
_Static_assert(sizeof(configuration_descriptor) == CONFIG_TOTAL_LEN,
               "USB configuration descriptor length mismatch");

static const char *const string_descriptors[] = {
    NULL,
    "Music Box FPGA",
    "FPGA Synth MIDI + I2S Capture",
    NULL,
    "FPGA I2S Capture",
    "Synth MIDI Input",
};
static uint16_t string_descriptor[33];

const uint8_t *tud_descriptor_device_cb(void) {
    return (const uint8_t *)&device_descriptor;
}

const uint8_t *tud_descriptor_configuration_cb(uint8_t index) {
    (void)index;
    return configuration_descriptor;
}

const uint16_t *tud_descriptor_string_cb(uint8_t index, uint16_t language_id) {
    char serial[2u * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1u];
    const char *text_value;
    size_t count;
    size_t character;

    (void)language_id;
    /* Index zero is the LANGID table, not a text string. All other strings are
     * converted from the firmware's ASCII literals to USB UTF-16LE on demand.
     * The RP2040 flash unique ID supplies a stable per-board serial number. */
    if (index == 0u) {
        string_descriptor[0] = (uint16_t)((TUSB_DESC_STRING << 8) | 4u);
        string_descriptor[1] = 0x0409;
        return string_descriptor;
    }
    if (index >= sizeof(string_descriptors) / sizeof(string_descriptors[0])) {
        return NULL;
    }
    if (index == 3u) {
        pico_get_unique_board_id_string(serial, sizeof(serial));
        text_value = serial;
    } else {
        text_value = string_descriptors[index];
    }
    if (text_value == NULL) return NULL;
    count = strlen(text_value);
    if (count > 32u) count = 32u;
    for (character = 0u; character < count; ++character) {
        string_descriptor[character + 1u] = (uint8_t)text_value[character];
    }
    string_descriptor[0] =
        (uint16_t)((TUSB_DESC_STRING << 8) | (2u * count + 2u));
    return string_descriptor;
}
