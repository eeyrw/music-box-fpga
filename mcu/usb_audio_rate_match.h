#ifndef USB_AUDIO_RATE_MATCH_H
#define USB_AUDIO_RATE_MATCH_H

#include <stdbool.h>
#include <stddef.h>

#define APP_USB_AUDIO_NOMINAL_FRAMES 48u
#define APP_USB_AUDIO_MAX_FRAMES 49u
#define APP_USB_AUDIO_TARGET_FRAMES 96u
#define APP_USB_AUDIO_ADJUST_MARGIN 24u

typedef struct app_usb_audio_stream_state {
    bool started;
    bool resync_pending;
} app_usb_audio_stream_state;

typedef enum app_usb_audio_packet_action {
    APP_USB_AUDIO_PACKET_SILENCE,
    APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE,
    APP_USB_AUDIO_PACKET_CAPTURE,
} app_usb_audio_packet_action;

/* Select the next asynchronous IN packet size from the capture-ring fill.
 * Returning one frame around the nominal packet rate adjusts producer/consumer
 * clock drift without dropping, repeating, or interpolating any I2S sample. */
size_t app_usb_audio_packet_frames(size_t available_frames);

/* Reset at startup and whenever the AudioStreaming endpoint closes. The first
 * packet after a reset discards samples accumulated while no host consumed the
 * ring, then the stream waits for a fresh target fill. */
void app_usb_audio_stream_reset(app_usb_audio_stream_state *state);

app_usb_audio_packet_action app_usb_audio_stream_plan(
    app_usb_audio_stream_state *state, bool clock_valid,
    size_t available_frames, size_t *capture_frames);

#endif
