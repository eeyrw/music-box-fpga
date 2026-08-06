#include "debug_console.h"

#include "hardware/uart.h"
#include "pico/stdlib.h"

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

#define DEBUG_CONSOLE_TX_BUFFER_SIZE 4096u
#define DEBUG_CONSOLE_RX_BUDGET 1u
#define DEBUG_CONSOLE_TX_BUDGET 32u

static char tx_buffer[DEBUG_CONSOLE_TX_BUFFER_SIZE];
static uint32_t tx_read_index;
static uint32_t tx_write_index;
static uint32_t dropped_bytes;

_Static_assert((DEBUG_CONSOLE_TX_BUFFER_SIZE &
                (DEBUG_CONSOLE_TX_BUFFER_SIZE - 1u)) == 0u,
               "debug console TX buffer size must be a power of two");

void debug_console_write(const char *text) {
    if (text == NULL) return;
    while (*text != '\0') {
        const uint32_t next =
            (tx_write_index + 1u) & (DEBUG_CONSOLE_TX_BUFFER_SIZE - 1u);
        if (next == tx_read_index) {
            ++dropped_bytes;
        } else {
            tx_buffer[tx_write_index] = *text;
            tx_write_index = next;
        }
        ++text;
    }
}

void debug_console_printf(const char *format, ...) {
    char line[192];
    va_list arguments;
    int length;
    va_start(arguments, format);
    length = vsnprintf(line, sizeof(line), format, arguments);
    va_end(arguments);
    if (length < 0) return;
    line[sizeof(line) - 1u] = '\0';
    debug_console_write(line);
    if ((size_t)length >= sizeof(line)) {
        dropped_bytes += (uint32_t)length - (uint32_t)sizeof(line) + 1u;
    }
}

void debug_console_service(debug_console_command_fn command, void *context) {
    uint32_t count;
    if (command != NULL) {
        for (count = 0u; count < DEBUG_CONSOLE_RX_BUDGET &&
                         uart_is_readable(uart0);
             ++count) {
            command(context, uart_getc(uart0));
        }
    }
    for (count = 0u; count < DEBUG_CONSOLE_TX_BUDGET &&
                     tx_read_index != tx_write_index && uart_is_writable(uart0);
         ++count) {
        uart_putc_raw(uart0, tx_buffer[tx_read_index]);
        tx_read_index =
            (tx_read_index + 1u) & (DEBUG_CONSOLE_TX_BUFFER_SIZE - 1u);
    }
}

uint32_t debug_console_dropped_bytes(void) {
    return dropped_bytes;
}
