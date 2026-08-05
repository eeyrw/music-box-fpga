#include "usb_audio_rate_match.h"

size_t app_usb_audio_packet_frames(size_t available_frames) {
    if (available_frames >
        APP_USB_AUDIO_TARGET_FRAMES + APP_USB_AUDIO_ADJUST_MARGIN) {
        return APP_USB_AUDIO_MAX_FRAMES;
    }
    if (available_frames <
            APP_USB_AUDIO_TARGET_FRAMES - APP_USB_AUDIO_ADJUST_MARGIN &&
        available_frames >= APP_USB_AUDIO_NOMINAL_FRAMES - 1u) {
        return APP_USB_AUDIO_NOMINAL_FRAMES - 1u;
    }
    return APP_USB_AUDIO_NOMINAL_FRAMES;
}

void app_usb_audio_stream_reset(app_usb_audio_stream_state *state) {
    state->started = false;
    state->resync_pending = true;
}

app_usb_audio_packet_action app_usb_audio_stream_plan(
    app_usb_audio_stream_state *state, bool clock_valid,
    size_t available_frames, size_t *capture_frames) {
    *capture_frames = APP_USB_AUDIO_NOMINAL_FRAMES;

    if (!clock_valid) {
        state->started = false;
        state->resync_pending = false;
        return APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE;
    }

    if (state->resync_pending) {
        state->started = false;
        state->resync_pending = false;
        return APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE;
    }

    if (!state->started) {
        if (available_frames < APP_USB_AUDIO_TARGET_FRAMES) {
            return APP_USB_AUDIO_PACKET_SILENCE;
        }
        state->started = true;
    }

    if (available_frames < APP_USB_AUDIO_NOMINAL_FRAMES - 1u) {
        state->started = false;
        return APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE;
    }

    *capture_frames = app_usb_audio_packet_frames(available_frames);
    return APP_USB_AUDIO_PACKET_CAPTURE;
}
