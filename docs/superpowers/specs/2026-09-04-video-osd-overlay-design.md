# Video OSD Overlay Design

## Goal

Add the first visible product-layer feature to the accepted 125 MHz image
playback baseline: an always-visible OSD that does not alter image loading,
memory transactions, clocks, reset topology, buttons or encrypted HDMI IP.

## Architecture

Insert a project-owned `video_osd_overlay` stage in the 25 MHz `video_clk`
domain between `video_delay`/fallback selection and
`video_rgb_to_axis_640x480`:

`frame read -> video_delay -> image/fallback select -> video_osd_overlay -> RGB-to-AXIS -> HDMI`

The module observes the already video-domain-safe `display_valid`,
`display_test_pattern` and `disp_buf_idx` signals. It does not sample SD-card
or SDRAM-domain control signals.

## Visual Design

The 640x480 output has two opaque 24-pixel bars:

- top bar: dark blue, with the fixed white title `OSD DISPLAY`;
- bottom bar: dark blue, with a status label and colour indicator.

The status label is selected only from video-domain state:

| Condition | Label | Indicator/text colour |
| --- | --- | --- |
| `display_valid=0`, `display_test_pattern=0` | `WAIT TF` | red |
| `display_test_pattern=1` | `FALLBACK` | yellow |
| `display_valid=1`, buffer 0 | `IMAGE B0` | cyan |
| `display_valid=1`, buffer 1 | `IMAGE B1` | cyan |

Letters use a built-in 8x8 bitmap font doubled vertically to make 8x16
characters. Outside the bars the input RGB value passes through unchanged.

## Scope

Add:

- `rtl/video/video_osd_overlay.v`;
- `tests/tb_video_osd_overlay.sv`;
- both TD `.al` project-file entries.

Modify `rtl/top/top.v` only to introduce an OSD RGB wire and instantiate the
overlay immediately before the existing RGB-to-AXIS converter.

## Exclusions

This version does not add an OSD enable key, a menu, parameter adjustment,
alpha blending, external fonts, Unicode text, TF text assets, HDMI changes,
CDC changes, timing exceptions, SDRAM changes or configuration-Flash writes.

## Verification

1. Unit-test transparent pass-through, bar background, title glyph, all four
   status labels and status colours using Icarus.
2. Re-run all existing project-owned tests and the top-level stub elaboration.
3. Build the root TD project with `syn_1`, `phy_1` and bit generation.
4. JTAG-test first image, manual next, automatic play, TF removal and
   reinsertion. Confirm the OSD remains stable and status changes are correct.
   Do not program configuration Flash.
