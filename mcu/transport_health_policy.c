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

fpga_session_observation fpga_session_classify(
    int version_read_result, uint32_t version, uint32_t expected_version,
    int status_read_result, uint32_t platform_status) {
    const uint32_t platform_error_mask = UINT32_C(0x00000002);
    const uint32_t asset_loaded_mask = UINT32_C(0x00000020);
    if (version_read_result != 0 || status_read_result != 0) {
        return FPGA_SESSION_UNREACHABLE;
    }
    if (version != expected_version) return FPGA_SESSION_INCOMPATIBLE;
    if ((platform_status & platform_error_mask) != 0u) {
        return FPGA_SESSION_PLATFORM_FAULT;
    }
    if ((platform_status & asset_loaded_mask) == 0u) {
        return FPGA_SESSION_LOADING;
    }
    return FPGA_SESSION_READY;
}
