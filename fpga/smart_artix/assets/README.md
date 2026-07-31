# Smart Artix Assets

This directory is reserved for board-specific asset-image notes and manifests.
Do not commit generated DDR3 wave images here unless they are intentionally small
test fixtures.

The intended board flow is:

```text
SF2/MIDI preprocessing
  -> wave image and metadata
  -> SD card, host transfer, or MCU storage
  -> DDR3 load before playback
  -> SPI transactional voice commands during playback
```

The current format and commands are documented in
[`../../../docs/board/asset_loading.md`](../../../docs/board/asset_loading.md)
and [`../../../docs/development/tooling.md`](../../../docs/development/tooling.md).
