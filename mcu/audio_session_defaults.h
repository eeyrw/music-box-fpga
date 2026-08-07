#ifndef AUDIO_SESSION_DEFAULTS_H
#define AUDIO_SESSION_DEFAULTS_H

#include <stdint.h>

#define AUDIO_SESSION_DEFAULT_WORD_COUNT 5u

void audio_session_defaults_build(
    uint32_t words[AUDIO_SESSION_DEFAULT_WORD_COUNT]);

#endif
