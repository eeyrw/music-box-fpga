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
