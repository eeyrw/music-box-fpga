#ifndef TRANSPORT_HEALTH_POLICY_H
#define TRANSPORT_HEALTH_POLICY_H

#include <stdint.h>

typedef enum transport_health_result {
    TRANSPORT_HEALTH_OK = 0,
    TRANSPORT_HEALTH_STALE_WARNING,
    TRANSPORT_HEALTH_COMMAND_FAULT
} transport_health_result;

typedef enum fpga_session_observation {
    FPGA_SESSION_UNREACHABLE = 0,
    FPGA_SESSION_LOADING,
    FPGA_SESSION_READY,
    FPGA_SESSION_PLATFORM_FAULT,
    FPGA_SESSION_INCOMPATIBLE
} fpga_session_observation;

transport_health_result transport_health_classify(
    uint32_t previous_command_errors, uint32_t previous_stale_generations,
    uint32_t command_errors, uint32_t stale_generations);

fpga_session_observation fpga_session_classify(
    int version_read_result, uint32_t version, uint32_t expected_version,
    int status_read_result, uint32_t platform_status);

#endif
