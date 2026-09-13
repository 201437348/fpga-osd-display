# Video-Clock Slide Bypass Diagnostic Design

## Goal

Determine whether the motion-only left-edge color line is created before or
after the video-clock RGB boundary.

## Design

Add a small `video_slide_diagnostic_pattern` module in the `video_clk` domain.
For every active pixel in one frame, form the same RGB value solely from
`slide_position`. The whole active picture is therefore one uniform color that
changes from frame to frame during the transition, without consuming SDRAM or
the asynchronous read FIFO. Any spatial stripe is necessarily outside the
intended diagnostic content.

In the production top, select this diagnostic RGB only while `slide_active` is
high and `display_valid` is true. Keep real image RGB for every static frame.
Feed the selected value through the unchanged OSD, RGB-to-AXIS converter, HDMI
core, PHY, cable, and display. Do not change DE/HS/VS, slide control, SDRAM
traffic, FIFO reads, OSD status, AXIS framing, or HDMI parameters.

## Verification

A focused test checks that pixels remain identical across x positions and
lines at one slide position, then change uniformly at another position.
Existing transition, OSD, AXIS,
FIFO/video-delay, scheduler, and real/stub top tests must remain passing.

## Board Interpretation

- Color line remains during the moving diagnostic ramp: the source is after
  the video-clock RGB selection, in OSD/AXIS/HDMI/PHY/cable/display behavior.
- Color line disappears during the moving diagnostic ramp: the source is in
  the SDRAM/read-FIFO/video-delay image path that has been bypassed.
- Static images must remain normal because the diagnostic is not selected
  outside a slide.
