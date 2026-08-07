#ifndef MIDI_INGRESS_QUEUE_H
#define MIDI_INGRESS_QUEUE_H

#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>

#define MIDI_INGRESS_QUEUE_CAPACITY 256u

typedef struct midi_ingress_queue {
    uint32_t packets[MIDI_INGRESS_QUEUE_CAPACITY];
    _Atomic uint32_t write_count;
    _Atomic uint32_t read_count;
    _Atomic uint32_t high_water;
    _Atomic uint32_t overflow_count;
} midi_ingress_queue;

void midi_ingress_queue_init(midi_ingress_queue *queue);
bool midi_ingress_queue_push(midi_ingress_queue *queue, const uint8_t packet[4]);
bool midi_ingress_queue_pop(midi_ingress_queue *queue, uint8_t packet[4]);
uint32_t midi_ingress_queue_depth(const midi_ingress_queue *queue);
bool midi_ingress_queue_full(const midi_ingress_queue *queue);
uint32_t midi_ingress_queue_discard_all(midi_ingress_queue *queue);

#endif
