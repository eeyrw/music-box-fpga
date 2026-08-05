#ifndef USB_AUDIO_RATE_MATCH_H
#define USB_AUDIO_RATE_MATCH_H

#include <stddef.h>

#define APP_USB_AUDIO_NOMINAL_FRAMES 48u
#define APP_USB_AUDIO_MAX_FRAMES 49u
#define APP_USB_AUDIO_TARGET_FRAMES 96u
#define APP_USB_AUDIO_ADJUST_MARGIN 24u

/* Select the next asynchronous IN packet size from the capture-ring fill.
 * Returning one frame around the nominal packet rate adjusts producer/consumer
 * clock drift without dropping, repeating, or interpolating any I2S sample. */
size_t app_usb_audio_packet_frames(size_t available_frames);

#endif
