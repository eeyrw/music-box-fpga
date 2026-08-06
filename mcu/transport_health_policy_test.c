#include "transport_health_policy.h"

#include <stdio.h>

static int expect(transport_health_result actual,
                  transport_health_result expected, const char *message) {
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
    if (failures != 0) return 1;
    puts("PASS: transport health distinguishes stale warnings from faults");
    return 0;
}
