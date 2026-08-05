#ifndef USB_AUDIO_CONFIG_H
#define USB_AUDIO_CONFIG_H

/* One full-speed USB frame is 1 ms. The asynchronous capture endpoint may
 * send one frame less or more than the nominal 48 stereo frames, so its
 * wMaxPacketSize must accommodate 49 frames * 2 channels * 2 bytes. */
#define APP_USB_AUDIO_SAMPLE_RATE_HZ 48000u
#define APP_USB_AUDIO_EP_IN 0x81u
#define APP_USB_AUDIO_EP_MAX_PACKET 196u
#define APP_USB_MIDI_EP_OUT 0x02u
#define APP_USB_MIDI_EP_IN 0x82u

/* UAC2 entity IDs are local to the AudioControl interface. Keep these IDs in
 * sync between the descriptors and the class-specific control callbacks. */
enum app_usb_audio_entity_id {
    APP_USB_AUDIO_INPUT_TERMINAL_ID = 1,
    APP_USB_AUDIO_OUTPUT_TERMINAL_ID = 2,
    APP_USB_AUDIO_CLOCK_SOURCE_ID = 3,
};

#endif
