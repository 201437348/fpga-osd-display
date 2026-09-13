# Slide Endpoint Hold Design

## Goal

Remove the one-frame colored sliver at the left edge when a horizontal image
transition completes.

## Root Cause

The current curve exposes `slide_position=638` for the final active slide
frame. That frame intentionally outputs two pixels from the old image at the
left edge and 638 pixels from the new image. The following frame changes to a
direct read of the complete new image, making the two-pixel remainder appear
as a one-frame colored flash.

## Design

Change curve step 27 from 638 to 640. Keep `slide_active` and
`transition_busy` asserted for that endpoint frame. On the next frame request,
retain the existing completion behavior: commit `active_buffer_index`, clear
`slide_active`, and clear `transition_busy`.

This creates the terminal sequence `631 -> 640 (slide endpoint) -> 640
(direct)`. Both terminal frames render all 640 pixels from the new buffer, so
the ownership handoff cannot change visible pixels.

## Verification

The controller test must fail against the old curve, then verify that step 27
is position 640 while the transition remains active and the old buffer remains
committed. Step 28 must remain position 640, switch the active buffer, and
release the transition.

The line scheduler endpoint test must continue proving that position 640
produces exactly one complete new-image frame. Existing SDRAM busy and
underflow regressions must remain green.

## Scope

Modify only `video_transition_controller.v` and its focused test. Do not
change transition duration, SDRAM/FIFO behavior, image loading, HDMI timing,
OSD, or audio.
