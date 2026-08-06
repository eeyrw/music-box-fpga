#ifndef TRANSPORT_HEALTH_POLICY_H
#define TRANSPORT_HEALTH_POLICY_H

#include <stdint.h>

typedef enum transport_health_result {
    TRANSPORT_HEALTH_OK = 0,
    TRANSPORT_HEALTH_STALE_WARNING,
    TRANSPORT_HEALTH_COMMAND_FAULT
} transport_health_result;

transport_health_result transport_health_classify(
    uint32_t previous_command_errors, uint32_t previous_stale_generations,
    uint32_t command_errors, uint32_t stale_generations);

#endif
