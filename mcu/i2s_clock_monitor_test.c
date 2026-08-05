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

int main(void) {
    i2s_clock_monitor monitor;
    uint32_t count = UINT32_MAX - 70u;

    i2s_clock_monitor_init(&monitor, count);
    count += 48u;
    i2s_clock_monitor_tick(&monitor, count);
    count += 48u; /* Wrap the producer count while acquiring the clock. */
    i2s_clock_monitor_tick(&monitor, count);
    count += 48u;
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("48 kHz acquisition", &monitor, true) != 0) return 1;

    count += 48u;
    i2s_clock_monitor_tick(&monitor, count);
    count += 48u;
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("stable 48 kHz", &monitor, true) != 0) return 1;

    i2s_clock_monitor_tick(&monitor, count);
    i2s_clock_monitor_tick(&monitor, count);
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("short dropout grace", &monitor, true) != 0) return 1;
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("disconnected source", &monitor, false) != 0) return 1;

    count += 44u;
    i2s_clock_monitor_tick(&monitor, count);
    count += 44u;
    i2s_clock_monitor_tick(&monitor, count);
    count += 44u;
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("reject 44.1 kHz cadence", &monitor, false) != 0) return 1;

    count += 48u;
    i2s_clock_monitor_tick(&monitor, count);
    count += 49u;
    i2s_clock_monitor_tick(&monitor, count);
    count += 47u;
    i2s_clock_monitor_tick(&monitor, count);
    if (expect_valid("reconnected 48 kHz", &monitor, true) != 0) return 1;

    puts("PASS: I2S 48 kHz clock acquisition and loss monitor");
    return 0;
}
