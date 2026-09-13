# OSD Bypass Diagnostic Design

## Goal

Determine whether the fixed left-edge image-colored line is introduced by
`video_osd_overlay` or exists in the FIFO/video-delay image stream before the
overlay.

## Evidence

The final AXIS white marker reaches the physical left edge with stable shape,
so the HDMI core and display do not insert a pixel before AXIS x=0.  The
moving line seen at the old/new junction in that build is expected because
feathering was intentionally disabled.  The next comparison must restore the
normal feathered transition while removing only the OSD layer.

## Design

In the production top, restore `SLIDE_FEATHER_ENABLE` to one, disable the AXIS
marker with a constant zero, and connect the RGB-to-AXIS input directly to
`vout_data` rather than `vout_data_osd`.  Keep the OSD instance and its signals
in source so the bypass is a one-line reversible diagnostic rather than a
module deletion.

Do not alter the transition controller, slide reader, FIFO, SDRAM scheduler,
video timing, AXIS framing, HDMI ready monitor, or HDMI transmitter.

## Verification

Use structural assertions to require all three diagnostic selections, then
run the transition, full-line, video-delay, RGB-to-AXIS, and OSD unit tests.
Elaborate the production top with both real and stubbed boundaries and run
`git diff --check`.

## Board Interpretation

- Fixed left-edge line disappears: the OSD overlay is responsible.
- Fixed left-edge line remains: the defect is already present in the
  FIFO/video-delay image stream.
- Top/bottom bars or scrolling text remain visible: the intended diagnostic
  bitstream was not loaded.

