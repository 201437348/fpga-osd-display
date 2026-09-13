# Pre-FIFO Uniform Slide Diagnostic Design

## Goal

Locate the motion-only left-edge color line on either side of the asynchronous
read FIFO write boundary.

## Design

Keep the real SDRAM scheduler, command traffic, return handling, asynchronous
FIFO, `video_delay`, OSD, AXIS, HDMI, and display timing active. Add a disabled
by default parameter to `frame_slide_fifo_read`. When enabled, latch whether
the accepted frame request is a slide and replace each final 32-bit FIFO write
for that frame with one uniform RGB value derived from the latched slide
position. Static frames retain their real SDRAM pixels.

Restore the top-level RGB selection to the normal `vout_data_raw` path. Enable
the new diagnostic only at the `frame_read_write` instance in `top.v`.

## Verification

The full-line scheduler test must prove that all pixels in every enabled slide
frame equal the expected uniform word, while its normal and feather-disabled
modes retain existing exact-pixel behavior. Existing scheduler, FIFO,
video-delay, OSD, AXIS, transition, wrapper, and top elaboration tests remain
passing.

## Board Interpretation

- No left-edge line: the fault is before the FIFO write override, in SDRAM
  return data or scheduler image generation.
- Left-edge line returns: the fault is after the override, in the asynchronous
  FIFO or `video_delay` path.
- Static images must remain normal.
