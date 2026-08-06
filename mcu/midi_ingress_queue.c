#include "midi_ingress_queue.h"

_Static_assert((MIDI_INGRESS_QUEUE_CAPACITY &
                (MIDI_INGRESS_QUEUE_CAPACITY - 1u)) == 0u,
               "MIDI ingress queue capacity must be a power of two");

void midi_ingress_queue_init(midi_ingress_queue *queue) {
    atomic_init(&queue->write_count, 0u);
    atomic_init(&queue->read_count, 0u);
    atomic_init(&queue->high_water, 0u);
    atomic_init(&queue->overflow_count, 0u);
}

bool midi_ingress_queue_push(midi_ingress_queue *queue, const uint8_t packet[4]) {
    const uint32_t write = atomic_load_explicit(&queue->write_count,
                                                 memory_order_relaxed);
    const uint32_t depth = write - atomic_load_explicit(
        &queue->read_count, memory_order_acquire);
    uint32_t packed;
    if (depth == MIDI_INGRESS_QUEUE_CAPACITY) {
        atomic_fetch_add_explicit(&queue->overflow_count, 1u,
                                  memory_order_relaxed);
        return false;
    }
    packed = (uint32_t)packet[0] | ((uint32_t)packet[1] << 8) |
             ((uint32_t)packet[2] << 16) | ((uint32_t)packet[3] << 24);
    queue->packets[write & (MIDI_INGRESS_QUEUE_CAPACITY - 1u)] = packed;
    atomic_store_explicit(&queue->write_count, write + 1u, memory_order_release);
    if (depth + 1u > atomic_load_explicit(&queue->high_water,
                                          memory_order_relaxed)) {
        atomic_store_explicit(&queue->high_water, depth + 1u,
                              memory_order_relaxed);
    }
    return true;
}

bool midi_ingress_queue_pop(midi_ingress_queue *queue, uint8_t packet[4]) {
    const uint32_t read = atomic_load_explicit(&queue->read_count,
                                                memory_order_relaxed);
    uint32_t packed;
    if (read == atomic_load_explicit(&queue->write_count,
                                     memory_order_acquire)) return false;
    packed = queue->packets[read & (MIDI_INGRESS_QUEUE_CAPACITY - 1u)];
    packet[0] = (uint8_t)packed;
    packet[1] = (uint8_t)(packed >> 8);
    packet[2] = (uint8_t)(packed >> 16);
    packet[3] = (uint8_t)(packed >> 24);
    atomic_store_explicit(&queue->read_count, read + 1u, memory_order_release);
    return true;
}

uint32_t midi_ingress_queue_depth(const midi_ingress_queue *queue) {
    return atomic_load_explicit(&queue->write_count, memory_order_acquire) -
           atomic_load_explicit(&queue->read_count, memory_order_acquire);
}

bool midi_ingress_queue_full(const midi_ingress_queue *queue) {
    return midi_ingress_queue_depth(queue) == MIDI_INGRESS_QUEUE_CAPACITY;
}
