#ifndef TUSB_CONFIG_H
#define TUSB_CONFIG_H

#include "usb_audio_config.h"

#ifndef CFG_TUSB_MCU
#error CFG_TUSB_MCU must be defined by the Pico SDK
#endif

#ifndef CFG_TUSB_OS
#define CFG_TUSB_OS OPT_OS_NONE
#endif
#define CFG_TUSB_DEBUG 0
#define CFG_TUD_ENABLED 1
#define CFG_TUD_MAX_SPEED OPT_MODE_FULL_SPEED
#define BOARD_TUD_RHPORT 0
#define CFG_TUSB_MEM_ALIGN __attribute__((aligned(4)))

#define CFG_TUD_ENDPOINT0_SIZE 64
#define CFG_TUD_AUDIO 1
#define CFG_TUD_MIDI 1
#define CFG_TUD_CDC 0
#define CFG_TUD_MSC 0
#define CFG_TUD_HID 0
#define CFG_TUD_VENDOR 0

#define CFG_TUD_MIDI_RX_BUFSIZE 128
#define CFG_TUD_MIDI_TX_BUFSIZE 64

#define CFG_TUD_AUDIO_FUNC_1_SAMPLE_RATE APP_USB_AUDIO_SAMPLE_RATE_HZ
/* Exact byte length of the custom UAC2 function, including its IAD. TinyUSB
 * uses this value to skip from the AudioControl interface to the next USB
 * function during SET_CONFIGURATION; it is therefore a parsing boundary, not
 * merely a buffer-size hint. Keep usb_descriptors.c tied to this same macro.
 *
 * This topology deliberately has no Feature Unit. Starting from TinyUSB's
 * stock microphone descriptor length and adjusting for channel count would be
 * wrong because Feature Unit descriptors have a variable entity length. */
#define APP_USB_AUDIO_DESC_LEN \
    (TUD_AUDIO_DESC_IAD_LEN + TUD_AUDIO_DESC_STD_AC_LEN + \
     TUD_AUDIO_DESC_CS_AC_LEN + TUD_AUDIO_DESC_CLK_SRC_LEN + \
     TUD_AUDIO_DESC_INPUT_TERM_LEN + TUD_AUDIO_DESC_OUTPUT_TERM_LEN + \
     2 * TUD_AUDIO_DESC_STD_AS_INT_LEN + TUD_AUDIO_DESC_CS_AS_INT_LEN + \
     TUD_AUDIO_DESC_TYPE_I_FORMAT_LEN + TUD_AUDIO_DESC_STD_AS_ISO_EP_LEN + \
     TUD_AUDIO_DESC_CS_AS_ISO_EP_LEN)
#define CFG_TUD_AUDIO_FUNC_1_DESC_LEN APP_USB_AUDIO_DESC_LEN
#define CFG_TUD_AUDIO_FUNC_1_N_AS_INT 1
#define CFG_TUD_AUDIO_FUNC_1_CTRL_BUF_SZ 64
#define CFG_TUD_AUDIO_ENABLE_EP_IN 1
#define CFG_TUD_AUDIO_FUNC_1_N_BYTES_PER_SAMPLE_TX 2
#define CFG_TUD_AUDIO_FUNC_1_N_CHANNELS_TX 2
#define CFG_TUD_AUDIO_EP_SZ_IN APP_USB_AUDIO_EP_MAX_PACKET
#define CFG_TUD_AUDIO_FUNC_1_EP_IN_SZ_MAX CFG_TUD_AUDIO_EP_SZ_IN
#define CFG_TUD_AUDIO_FUNC_1_EP_IN_SW_BUF_SZ (4 * CFG_TUD_AUDIO_EP_SZ_IN)
#define CFG_TUD_AUDIO_EP_IN_FLOW_CONTROL 0

#endif
