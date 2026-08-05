#include "i2s_clock_monitor.h"

#include <stdint.h>
#include <stdio.h>

static int expect_valid(const char *step, const i2s_clock_monitor *monitor,
                        bool expected) {
    const bool actual = i2s_clock_monitor_valid(monitor);
    if (actual == expected) return 0;
    fprintf(stderr, "I2S clock monitor failed at %s: expected=%d actual=%d\n",
            step, expected, actual);
    return 1;
}

static int expect_recovery(const char *step, const i2s_clock_monitor *monitor,
                           bool expected) {
    const bool actual = i2s_clock_monitor_recovery_ready(monitor);
    if (actual == expected) return 0;
    fprintf(stderr,
            "I2S recovery monitor failed at %s: expected=%d actual=%d\n",
            step, expected, actual);
    return 1;
}

static void tick_by(i2s_clock_monitor *monitor, uint32_t *count,
                    uint32_t frames) {
    *count += frames;
    i2s_clock_monitor_tick(monitor, *count);
}

int main(void) {
    static const uint8_t boundary_jitter[8] = {
        46u, 50u, 47u, 49u, 48u, 48u, 48u, 48u,
    };
    i2s_clock_monitor monitor;
    uint32_t count = UINT32_MAX - 200u;
    size_t index;

    i2s_clock_monitor_init(&monitor, count);
    for (index = 0u; index < 4u; ++index) {
        i2s_clock_monitor_tick(&monitor, count);
    }
    if (expect_recovery("disconnected startup", &monitor, false) != 0) {
        return 1;
    }
    for (index = 0u; index < sizeof(boundary_jitter); ++index) {
        tick_by(&monitor, &count, boundary_jitter[index]);
    }
    if (expect_valid("48 kHz jittered acquisition across wrap", &monitor,
                     true) != 0) {
        return 1;
    }
    if (expect_recovery("initial source acquisition", &monitor, false) != 0) {
        return 1;
    }

    i2s_clock_monitor_tick(&monitor, count);
    i2s_clock_monitor_tick(&monitor, count);
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("short dropout grace", &monitor, true) != 0) return 1;
    if (expect_recovery("short dropout does not restart", &monitor, false) !=
        0) {
        return 1;
    }
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("disconnected source", &monitor, false) != 0) return 1;
    if (expect_recovery("stopped source awaits cadence", &monitor, false) !=
        0) {
        return 1;
    }

    for (index = 0u; index < 8u; ++index) {
        tick_by(&monitor, &count, 44u);
    }
    if (expect_valid("reject 44.1 kHz cadence", &monitor, false) != 0) return 1;

    for (index = 0u; index < 8u; ++index) {
        tick_by(&monitor, &count, 47u);
    }
    if (expect_valid("reject sustained 47 kHz", &monitor, false) != 0) {
        return 1;
    }

    for (index = 0u; index < 8u; ++index) {
        tick_by(&monitor, &count, 48u);
    }
    if (expect_valid("reconnected 48 kHz", &monitor, true) != 0) return 1;
    if (expect_recovery("reconnected source requires frame resync", &monitor,
                        true) != 0) {
        return 1;
    }

    /* Model the hardware owner consuming the recovery event, restarting PIO
     * at its LRCLK synchronization entry, and reacquiring the source rate. */
    i2s_clock_monitor_init(&monitor, count);
    if (expect_valid("post-resync acquisition", &monitor, false) != 0) return 1;
    for (index = 0u; index < 8u; ++index) {
        tick_by(&monitor, &count, 48u);
    }
    if (expect_valid("post-resync stable source", &monitor, true) != 0) return 1;
    if (expect_recovery("post-resync event consumed", &monitor, false) != 0) {
        return 1;
    }

    for (index = 0u; index < 8u; ++index) {
        tick_by(&monitor, &count, 49u);
    }
    if (expect_valid("reject sustained 49 kHz", &monitor, false) != 0) {
        return 1;
    }

    puts("PASS: I2S rolling-average clock acquisition and loss monitor");
    return 0;
}
