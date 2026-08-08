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
    audio_session_compressor_build(words, 0);
    if (words[0] != expected[0] || words[1] != (expected[1] & ~UINT32_C(1)) ||
        words[2] != expected[2] || words[3] != expected[3] ||
        words[4] != expected[4]) {
        fputs("disabled compressor command changed fields other than enable\n",
              stderr);
        return 1;
    }
    puts("PASS: MCU session defaults enable the documented compressor");
    return 0;
}
