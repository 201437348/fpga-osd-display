# HDMI AXIS Ready Diagnostic Design

## Goal

Determine whether the fixed colored column at physical screen `x=0` is caused
by the RGB-to-AXIS source presenting pixels while the HDMI transmitter is not
ready to accept them.

## Evidence

The artifact is unchanged when transition feathering is compiled out.  The
HDMI transmitter exposes `O_axis_s_ready`, but the current RGB-to-AXIS source
does not consume or monitor it.  In AXIS, a pixel transfers only when both
`valid` and `ready` are high.  Ignoring a low `ready` can drop a pixel while
the raster source continues, which can appear at a fixed line boundary and be
most visible while image content changes.

## Design

Add `I_video_ready` and a four-bit saturating `O_backpressure_count` diagnostic
to `video_rgb_to_axis_640x480`.  Increment the counter on each clock where the
registered AXIS output is valid and the HDMI input is not ready.  Keep the
counter sticky until reset so a brief event remains observable after a slide.
Do not gate, delay, or modify AXIS video in this diagnostic revision.

Synchronize the count through two registers into the existing board status
domain.  Reserve the rightmost seven-segment digit exclusively for the
backpressure count in this diagnostic build, so zero cannot be confused with
an unrelated status source.

## Verification

Extend the line-boundary test to prove the counter remains zero while ready is
high, counts three injected valid-cycle stalls, saturates at `F`, and leaves
pixel ordering, SOF, TLAST, and valid timing unchanged.  Re-run the focused
transition and pixel-path regressions and elaborate the changed interfaces.

## Board Interpretation

- Rightmost digit remains `0`: the HDMI core accepted every valid pixel, so
  AXIS backpressure is excluded.
- Rightmost digit becomes `1` through `F`: the source violated the AXIS
  transfer contract; the next implementation must buffer or otherwise absorb
  the observed backpressure.
