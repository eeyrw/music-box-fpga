#ifndef DEBUG_CONSOLE_H
#define DEBUG_CONSOLE_H

#include <stdint.h>

typedef void (*debug_console_command_fn)(void *context, int character);

void debug_console_write(const char *text);
void debug_console_printf(const char *format, ...);
void debug_console_service(debug_console_command_fn command, void *context);
uint32_t debug_console_dropped_bytes(void);

#endif
