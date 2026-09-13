# HDMI Left-Edge Marker Diagnostic Design

## Goal

Locate the fixed image-colored line relative to the final FPGA pixel boundary
by replacing the first sixteen AXIS pixels of every active row with white only
while the slide transition is active.

## Evidence

The line remains with feather blending disabled, FIFO underflow is zero, and
the HDMI AXIS ready monitor remains zero.  Routed timing from the registered
OSD output to the RGB-to-AXIS register has more than 16 ns of setup slack.
The remaining boundary is whether the unwanted color already exists before
the final AXIS register or is inserted after that register.

## Design

Add `I_marker_enable` to `video_rgb_to_axis_640x480` and connect it to
`slide_active`.  When enabled, replace exactly input pixels `x=0..15` of every
active row with `24'hFFFFFF`.  Use the converter's existing line-start state
and x counter, so no new timing generator or frame buffer is introduced.

Do not change valid, ready monitoring, SOF, TLAST, or any upstream RGB/FIFO
signal.  Outside a slide, and from x=16 onward during a slide, forward the
existing RGB value unchanged.

## Verification

The line-boundary test must check three complete 640-pixel rows.  With marker
disabled, all pixels remain unchanged.  With marker enabled, each row has
white at x=0 through x=15 and original data at x=16 through x=639.  Existing
SOF, TLAST, valid, and backpressure-count assertions must continue to pass.

## Board Interpretation

- White band reaches the physical left edge and the image-colored line is
  gone: the unwanted color originates before the AXIS output register.
- An image-colored line remains immediately left of the white band: the HDMI
  core, serializer, cable, or display inserts/substitutes the boundary pixel.
- The white band is shifted, clipped, or otherwise malformed: the HDMI line
  framing boundary is misaligned.
