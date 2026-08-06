#include "midi_ingress_queue.h"

#include <stdio.h>

int main(void) {
    midi_ingress_queue queue;
    uint8_t packet[4];
    uint32_t index;
    midi_ingress_queue_init(&queue);
    for (index = 0u; index < MIDI_INGRESS_QUEUE_CAPACITY; ++index) {
        const uint8_t input[4] = {0x09u, 0x90u, (uint8_t)index,
                                  (uint8_t)(127u - (index & 127u))};
        if (!midi_ingress_queue_push(&queue, input)) {
            fputs("queue rejected an in-capacity packet\n", stderr);
            return 1;
        }
    }
    if (midi_ingress_queue_depth(&queue) != MIDI_INGRESS_QUEUE_CAPACITY ||
        !midi_ingress_queue_full(&queue) ||
        queue.high_water != MIDI_INGRESS_QUEUE_CAPACITY ||
        midi_ingress_queue_push(&queue, (const uint8_t[4]){0u, 0u, 0u, 0u}) ||
        queue.overflow_count != 1u) {
        fputs("queue capacity/overflow accounting failed\n", stderr);
        return 1;
    }
    for (index = 0u; index < MIDI_INGRESS_QUEUE_CAPACITY; ++index) {
        if (!midi_ingress_queue_pop(&queue, packet) || packet[0] != 0x09u ||
            packet[1] != 0x90u || packet[2] != (uint8_t)index) {
            fputs("queue changed FIFO packet order\n", stderr);
            return 1;
        }
    }
    if (midi_ingress_queue_full(&queue)) {
        fputs("drained MIDI queue remained full\n", stderr);
        return 1;
    }
    queue.write_count = UINT32_MAX - 1u;
    queue.read_count = UINT32_MAX - 1u;
    if (!midi_ingress_queue_push(
            &queue, (const uint8_t[4]){0x08u, 0x80u, 60u, 0u}) ||
        !midi_ingress_queue_pop(&queue, packet) || packet[1] != 0x80u ||
        midi_ingress_queue_depth(&queue) != 0u) {
        fputs("queue counters failed across uint32 wrap\n", stderr);
        return 1;
    }
    puts("PASS: dual-core MIDI ingress SPSC queue");
    return 0;
}
