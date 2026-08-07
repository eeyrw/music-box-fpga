#include "audio_session_defaults.h"

#include <stdio.h>

int main(void) {
    static const uint32_t expected[AUDIO_SESSION_DEFAULT_WORD_COUNT] = {
        UINT32_C(0x20000004),
        UINT32_C(0x00018001),
        UINT32_C(0x01400000),
        UINT32_C(0x00000000),
        UINT32_C(0x00001112),
    };
    uint32_t words[AUDIO_SESSION_DEFAULT_WORD_COUNT];
    unsigned index;

    audio_session_defaults_build(words);
    for (index = 0u; index < AUDIO_SESSION_DEFAULT_WORD_COUNT; ++index) {
        if (words[index] != expected[index]) {
            fprintf(stderr,
                    "default audio command word %u: got 0x%08x, expected "
                    "0x%08x\n",
                    index, (unsigned)words[index], (unsigned)expected[index]);
            return 1;
        }
    }
    puts("PASS: MCU session defaults enable the documented compressor");
    return 0;
}
