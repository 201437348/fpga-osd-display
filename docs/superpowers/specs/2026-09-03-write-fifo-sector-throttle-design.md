# Write FIFO Sector Throttle Design

## Problem

The 512-word asynchronous FIFO between the BMP reader and SDRAM writer
silently drops pixels when full. The BMP source has no backpressure, so a
brief SDRAM write delay can leave the writer permanently short of its required
307200 pixels. The manager then waits in `341100` until its ten-second
timeout and retries the image.

## Design

The existing FIFO almost-full output is configured to assert at 256 queued
pixels. It is already in the BMP writer clock domain. `bmp_read` observes this
signal only after a 512-byte SD sector completes, before it starts the next
sector.

One sector produces at most 171 24-bit pixels. Starting a sector only below
the 256-pixel high-water mark therefore leaves at least 256 free FIFO entries,
which is sufficient to finish the entire in-flight sector without reaching the
511-entry full threshold.

When the FIFO is below the high-water mark, `bmp_read` immediately resumes
the next sector. During a pause, the SD controller is idle and SDRAM writing
continues draining the FIFO.

## Boundaries

- The FIFO depth remains 512; no extra BRAM is required.
- Pixels are never deliberately dropped or truncated.
- The SDRAM writer, TF command core, frame buffers, HDMI output, reset flow,
  image retry policy, and input-lock behavior are unchanged.
- The high-water signal is used only in the `sd_card_clk` domain, so no new
  clock-domain crossing is introduced.

## Implementation

- Override `wfifo_32_32_512`'s `AL_FULL_NUM` parameter to `256` and route its
  `afull` output through `frame_read_write` and `image_storage_adapter`.
- Add a BMP reader pause state that holds between data sectors while the
  high-water signal is asserted.
- Preserve the existing source-done condition: it is asserted only after the
  final sector has been completely delivered.

## Verification

- Add a BMP-reader unit test that holds the high-water input at a sector
  boundary and verifies no new read request starts until it clears.
- Run existing manager, adapter, and playback-control tests.
- Run top-level static compilation including the generated FIFO source.
- Hardware: repeatedly request images with both single presses and close
  sequential presses; every completed request changes one image without a
  ten-second `341100` timeout. Verify TF reinsert recovery remains intact.
