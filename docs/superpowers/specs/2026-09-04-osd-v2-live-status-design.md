# OSD v2 Live Image Status

## Goal

Turn the existing OSD from a buffer indicator into a live, user-visible image
status display. The feature must show the actual displayed image number and
the number of BMP files found on the TF card, while showing a clear transient
state during scan and frame loading.

## Scope

The feature uses status already produced by `image_load_manager` and does not
change the SD-card reader, BMP parser, SDRAM interface, frame FIFO, clock
frequencies, PLL phase, button behavior, retry policy, timeout values, ADC,
SDC, or configuration Flash.

The top OSD title remains `OSD DISPLAY`. The bottom line is widened from eight
to ten character cells and displays one of the following:

- `IMAGE 1/4` through `IMAGE 4/4`: a committed, visible image; the numerator
  is the current image and the denominator is the scanned image count.
- `LOAD 2/4`: the target image is being written and verified. A previously
  committed frame remains displayed while this text is shown.
- `SCAN`: the TF card is ready and the image directory scan or recovery scan is
  in progress.
- `WAIT TF`: storage is not ready and no fallback pattern is active.
- `FALLBACK`: no valid frame is available and the existing colour pattern is
  active.

The feature supports the manager's existing maximum of four images. It does
not promise support for a different BMP format, more than four images, or a
different automatic-play interval.

## Architecture

`image_load_manager` already exports `current_image_index`,
`target_image_index`, `image_count`, `state`, `display_valid`, and
`display_test_pattern` in the `sd_card_clk` domain. `top.v` will connect the
currently unused image-index output and form a presentation-only packed status
bundle from those values plus `storage_ready`.

The bundle crosses to `video_clk` through two video-clocked registers, like
the existing display-valid and buffer-index status crossings. It is never used
to issue storage commands, select SDRAM buffers, or control timing-sensitive
logic. The manager holds each status for far longer than the two video-clock
cycles required to observe it; an occasional transition-frame visual mismatch
would be harmless and self-correcting. No timing exception is added.

`video_osd_overlay` receives the synchronized status fields and converts them
to the fixed-width text above. Image indices are converted from zero-based
manager values to user-facing values one through four. `FALLBACK` and `WAIT
TF` retain priority over scan, loading, and image text.

## Alternatives

1. **Presentation-only two-register status crossing (selected).** It follows
   the project's existing display-status crossing pattern, changes no
   functional CDC, and is appropriate because the data only affects text.
2. **Snapshot/toggle handshake.** This would make every character update
   atomic, but adds a new control CDC for a cosmetic display and has no
   functional benefit here.
3. **Infer the image number from the SDRAM buffer index.** Rejected because
   there are only two frame buffers but up to four images, so it cannot report
   the real image number.

## Verification

Update `tb_video_osd_overlay.sv` to check glyph placement and colour for
`IMAGE 1/4`, `IMAGE 4/4`, `LOAD 2/4`, `SCAN`, `WAIT TF`, and `FALLBACK`.
Add a focused top-level structural check that the status fields use only the
two-register `sd_card_clk` to `video_clk` presentation crossing.

After TD `syn_1` and `phy_1` succeed, use JTAG only for board validation:

1. Boot with the normal four-BMP TF card and observe `SCAN`, followed by
   `IMAGE 1/4`.
2. Use manual next to observe `LOAD 2/4`, then `IMAGE 2/4`; repeat through the
   wrap from `IMAGE 4/4` to `IMAGE 1/4`.
3. Run automatic play and confirm that load and committed labels follow the
   real displayed order.
4. Remove and reinsert the TF card to confirm the existing retained-image and
   fallback behavior still works, with the corresponding text.

Passing requires all existing image playback behavior to remain unchanged and
the OSD text to match the manager state. This build must not be programmed to
configuration Flash until JTAG validation passes.

## Self-Review

The design has a single presentation boundary, names all new status states,
defines priority, preserves the accepted storage path, and gives both unit and
board acceptance criteria. It deliberately avoids timing, PLL, SDRAM, FIFO,
and button changes.
