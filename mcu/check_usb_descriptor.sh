#!/bin/sh
set -eu

objcopy=$1
descriptor_object=$2
descriptor_bin=$(mktemp)
trap 'rm -f "$descriptor_bin"' EXIT HUP INT TERM

"$objcopy" \
    --dump-section .rodata.configuration_descriptor="$descriptor_bin" \
    "$descriptor_object"

od -An -v -tu1 "$descriptor_bin" | awk '
{
    for (field = 1; field <= NF; ++field) byte[count++] = $field
}
END {
    valid = 1
    offset = 0
    while (offset < count) {
        descriptor_len = byte[offset]
        type = byte[offset + 1]
        if (descriptor_len < 2 || offset + descriptor_len > count) {
            valid = 0
            break
        }
        if (type == 11) {
            if (byte[offset + 2] == 0 && byte[offset + 3] == 2) audio_iad = 1
            if (byte[offset + 2] == 2 && byte[offset + 3] == 2) midi_iad = 1
        } else if (type == 4) {
            interface_seen[byte[offset + 2]] = 1
        } else if (type == 5) {
            endpoint = byte[offset + 2]
            attributes = byte[offset + 3]
            packet_size = byte[offset + 4] + 256 * byte[offset + 5]
            if (endpoint == 129 && attributes == 5 && packet_size == 196) audio_in = 1
            if (endpoint == 2 && attributes == 2 && packet_size == 64) midi_out = 1
            if (endpoint == 130 && attributes == 2 && packet_size == 64) midi_in = 1
        }
        offset += descriptor_len
    }
    total_length = byte[2] + 256 * byte[3]
    if (count != 227 || offset != count || byte[1] != 2 ||
        total_length != count || byte[4] != 4 || !audio_iad || !midi_iad ||
        !interface_seen[0] || !interface_seen[1] || !interface_seen[2] ||
        !interface_seen[3] || !audio_in || !midi_out || !midi_in) {
        valid = 0
    }
    if (!valid) {
        print "invalid USB Audio/MIDI configuration descriptor" > "/dev/stderr"
        exit 1
    }
    print "USB descriptor check passed (227 bytes, UAC2 + MIDI 1.0)"
}'
