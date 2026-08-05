#include "usb_audio_rate_match.h"
#include "usb_audio_config.h"

#include <stddef.h>
#include <stdio.h>

int main(void) {
    static const struct {
        size_t available;
        size_t expected;
    } cases[] = {
        {0u, 48u},
        {46u, 48u},
        {47u, 47u},
        {71u, 47u},
        {72u, 48u},
        {96u, 48u},
        {120u, 48u},
        {121u, 49u},
        {2048u, 49u},
    };
    app_usb_audio_stream_state stream;
    app_usb_audio_packet_action action;
    size_t capture_frames;
    size_t index;

    if (!app_usb_audio_control_channel_supported(0x0100u) ||
        app_usb_audio_control_channel_supported(0x0101u)) {
        fputs("UAC2 master-control Channel Number validation failed\n", stderr);
        return 1;
    }

    for (index = 0u; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        const size_t actual =
            app_usb_audio_packet_frames(cases[index].available);
        if (actual != cases[index].expected) {
            fprintf(stderr,
                    "USB audio rate match failed: available=%zu expected=%zu actual=%zu\n",
                    cases[index].available, cases[index].expected, actual);
            return 1;
        }
    }

    app_usb_audio_stream_reset(&stream);
    action = app_usb_audio_stream_plan(&stream, true, 2048u,
                                       &capture_frames);
    if (action != APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE) {
        fputs("USB audio initial open did not discard stale capture data\n",
              stderr);
        return 1;
    }
    action = app_usb_audio_stream_plan(&stream, true, 48u, &capture_frames);
    if (action != APP_USB_AUDIO_PACKET_SILENCE) {
        fputs("USB audio stream did not wait for fresh target fill\n", stderr);
        return 1;
    }
    action = app_usb_audio_stream_plan(&stream, true, 96u, &capture_frames);
    if (action != APP_USB_AUDIO_PACKET_CAPTURE || capture_frames != 48u) {
        fputs("USB audio stream did not start at the fresh target fill\n",
              stderr);
        return 1;
    }

    app_usb_audio_stream_reset(&stream);
    action = app_usb_audio_stream_plan(&stream, true, 2048u,
                                       &capture_frames);
    if (action != APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE) {
        fputs("USB audio reopen did not discard data captured while closed\n",
              stderr);
        return 1;
    }

    action = app_usb_audio_stream_plan(&stream, false, 120u,
                                       &capture_frames);
    if (action != APP_USB_AUDIO_PACKET_DISCARD_AND_SILENCE) {
        fputs("USB audio clock loss did not discard stale capture data\n",
              stderr);
        return 1;
    }
    action = app_usb_audio_stream_plan(&stream, true, 48u, &capture_frames);
    if (action != APP_USB_AUDIO_PACKET_SILENCE) {
        fputs("USB audio clock recovery did not rebuild target fill\n", stderr);
        return 1;
    }

    puts("PASS: USB audio asynchronous packet rate matching");
    return 0;
}
