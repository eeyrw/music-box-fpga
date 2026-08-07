#include "transport_health_policy.h"

#include <stdio.h>

static int expect(transport_health_result actual,
                  transport_health_result expected, const char *message) {
    if (actual == expected) return 0;
    fprintf(stderr, "FAIL: %s (actual=%d expected=%d)\n", message,
            (int)actual, (int)expected);
    return 1;
}

static int expect_session(fpga_session_observation actual,
                          fpga_session_observation expected,
                          const char *message) {
    if (actual == expected) return 0;
    fprintf(stderr, "FAIL: %s (actual=%d expected=%d)\n", message,
            (int)actual, (int)expected);
    return 1;
}

int main(void) {
    int failures = 0;
    failures += expect(transport_health_classify(7u, 20u, 7u, 20u),
                       TRANSPORT_HEALTH_OK, "unchanged counters");
    failures += expect(transport_health_classify(7u, 20u, 7u, 22u),
                       TRANSPORT_HEALTH_STALE_WARNING,
                       "stale rejection remains nonfatal");
    failures += expect(transport_health_classify(7u, 20u, 8u, 20u),
                       TRANSPORT_HEALTH_COMMAND_FAULT,
                       "command error is fatal");
    failures += expect(transport_health_classify(7u, 20u, 8u, 22u),
                       TRANSPORT_HEALTH_COMMAND_FAULT,
                       "command error dominates stale warning");
    failures += expect_session(
        fpga_session_classify(-1, 0u, UINT32_C(0x00100000), -1, 0u),
        FPGA_SESSION_UNREACHABLE, "unreachable FPGA");
    failures += expect_session(
        fpga_session_classify(0, UINT32_C(0x00100000),
                              UINT32_C(0x00100000), 0, 0u),
        FPGA_SESSION_LOADING, "asset loading");
    failures += expect_session(
        fpga_session_classify(0, UINT32_C(0x00100000),
                              UINT32_C(0x00100000), 0, UINT32_C(0x20)),
        FPGA_SESSION_READY, "loaded compatible FPGA");
    failures += expect_session(
        fpga_session_classify(0, UINT32_C(0x00100000),
                              UINT32_C(0x00100000), 0, UINT32_C(0x22)),
        FPGA_SESSION_PLATFORM_FAULT, "loader fault");
    failures += expect_session(
        fpga_session_classify(0, UINT32_C(0x000e0000),
                              UINT32_C(0x00100000), 0, UINT32_C(0x20)),
        FPGA_SESSION_INCOMPATIBLE, "interface mismatch");
    if (failures != 0) return 1;
    puts("PASS: transport health and FPGA session observations");
    return 0;
}
