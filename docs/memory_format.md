# Wave Memory Format

Addresses identify 16-bit words. A voice configuration gives `base_addr` in
words and gives `length`, `loop_start`, and `loop_end` in sample frames.

## Mono

When `stereo` is clear, frame `n` is stored at:

```text
base_addr + n
```

The fetched sample is used for both channels before channel gain is applied.

## Stereo

When `stereo` is set, channels are interleaved left first:

```text
left(n)  = base_addr + 2*n
right(n) = base_addr + 2*n + 1
```

Interpolation operates independently on each channel.

## Abstract Memory Handshake

The core issues one 32-bit word-address request at a time. A request transfers
when `mem_req_valid && mem_req_ready`. A response transfers when
`mem_rsp_valid`; responses must arrive in request order. The initial simulation
model accepts every request and returns its signed 16-bit value one cycle later.
