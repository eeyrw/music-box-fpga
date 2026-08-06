#include "transport_health_policy.h"

transport_health_result transport_health_classify(
    uint32_t previous_command_errors, uint32_t previous_stale_generations,
    uint32_t command_errors, uint32_t stale_generations) {
    if (command_errors != previous_command_errors) {
        return TRANSPORT_HEALTH_COMMAND_FAULT;
    }
    if (stale_generations != previous_stale_generations) {
        return TRANSPORT_HEALTH_STALE_WARNING;
    }
    return TRANSPORT_HEALTH_OK;
}
