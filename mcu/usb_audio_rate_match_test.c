#include "usb_audio_rate_match.h"

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
    size_t index;

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
    puts("PASS: USB audio asynchronous packet rate matching");
    return 0;
}
