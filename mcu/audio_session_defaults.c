#include "audio_session_defaults.h"

#define COMPRESSOR_COMMAND_HEADER UINT32_C(0x20000004)
#define COMPRESSOR_ENABLED UINT32_C(1)
#define COMPRESSOR_RATIO_SLOPE_Q0_16 UINT32_C(0x0000c000)
#define COMPRESSOR_THRESHOLD_CB_Q12_20 (UINT32_C(20) << 20)
#define COMPRESSOR_ATTACK_STEP_CB_Q12_20 UINT32_C(0)
#define COMPRESSOR_RELEASE_FRAMES UINT32_C(240000)
#define COMPRESSOR_FULL_RANGE_CB_Q12_20 (UINT32_C(1000) << 20)
#define COMPRESSOR_RELEASE_STEP_CB_Q12_20                              \
    ((COMPRESSOR_FULL_RANGE_CB_Q12_20 + COMPRESSOR_RELEASE_FRAMES - 1u) / \
     COMPRESSOR_RELEASE_FRAMES)

void audio_session_defaults_build(
    uint32_t words[AUDIO_SESSION_DEFAULT_WORD_COUNT]) {
    audio_session_compressor_build(words, 1);
}

void audio_session_compressor_build(
    uint32_t words[AUDIO_SESSION_DEFAULT_WORD_COUNT], int enabled) {
    words[0] = COMPRESSOR_COMMAND_HEADER;
    words[1] = (COMPRESSOR_RATIO_SLOPE_Q0_16 << 1) |
               (enabled != 0 ? COMPRESSOR_ENABLED : 0u);
    words[2] = COMPRESSOR_THRESHOLD_CB_Q12_20;
    words[3] = COMPRESSOR_ATTACK_STEP_CB_Q12_20;
    words[4] = COMPRESSOR_RELEASE_STEP_CB_Q12_20;
}
