# Transition Left-Column Diagnostic Design

## Goal

Identify and fix the single colored column fixed at screen `x=0` that is
visible only while the horizontal image transition is active.

## Evidence

The artifact does not move with the old/new image boundary. It appears when
motion begins, reflects image content, remains at the physical left edge, and
disappears when motion stops. The refresh-backpressure fix eliminated FIFO
underflow and the earlier moving/yellow corruption, while changing the final
slide position from 638 to 640 did not affect this fixed-column artifact.

The read FIFO is configured as non-show-ahead with an unregistered output.
`video_delay` asserts FIFO read enable one timing stage before it samples the
FIFO output. A line-boundary latency mismatch could therefore display the
previous row's final pixel at the next row's first position. During a slide,
those pixels come from different images and make the error conspicuous; in
steady display both come from the same image and can hide it.

## Diagnostic Design

Add a focused pixel-path integration test using the production asynchronous
read FIFO and production `video_delay`. Feed a frame whose row-ending pixel,
next-row first pixel, and next-row second pixel have distinct marker values.
Drive realistic active-line and blanking timing, then capture output pixels
only while delayed `de` is asserted.

The test must verify the exact first, second, and final output pixel of two
successive rows. Its failure report must distinguish:

- previous-row final pixel leaking into current-row `x=0`;
- current-row `x=0` being duplicated or skipped;
- an error introduced after `video_delay` in the OSD or RGB-to-AXIS path.

First test the FIFO plus `video_delay` boundary. If that path is correct,
extend the same marker check through `video_osd_overlay` and
`video_rgb_to_axis_640x480` without changing the stimulus.

## Fix Boundary

Change only the stage that the failing test identifies. A FIFO latency defect
is corrected by aligning read enable, data capture, and delayed sync signals;
an OSD/AXIS defect is corrected in that downstream stage. Do not alter SDRAM
request scheduling, FIFO depth, slide positions, feather blending, frame
buffer contents, HDMI timing, or OSD layout. Do not hide the defect by
painting over or duplicating the first column.

Post-route timing adds a stronger hardware-only finding.  The 125 MHz
`ext_mem_clk` domain has an internal worst setup path of -4.746 ns from the
transition scheduler's feather selection/cache logic to `fifo_write_data`.
The path contains the cache RAM output, six adders, and one multiplier, and
is active only for feathered transition pixels.  Static display bypasses it.
RTL simulation cannot reproduce data corruption caused by this violation.

## Timing-Correction Design

Pipeline every FIFO-producing SDRAM return through a common ordered output
path.  Direct pixels carry their RGB value through the same valid pipeline as
blended pixels.  Blended pixels use three bounded stages: register source,
absolute difference, direction, and alpha; register the difference-by-alpha
product; then add or subtract the scaled product and emit the FIFO word.

Using a common pipeline preserves ordering when a blended segment is followed
immediately by a direct segment.  Reserve the pipeline occupancy in the FIFO
chunk-room threshold and delay final-frame completion until all valid stages
have drained.  SDRAM command issue and return accounting remain unchanged.

## Verification

The new marker test must pass with no first-column substitution and exactly
640 output pixels per active line. Re-run the transition controller, slide
scheduler, frame-read underflow, refresh sweep, real-top elaboration, and
`git diff --check`. TD synthesis, physical implementation, and board testing
are required only after simulation identifies and verifies a concrete fix.

Additionally, post-route timing must show that the former
`frame_slide_fifo_read -> fifo_write_data` multiply/add path is split across
register stages.  Board testing remains the final check because the original
artifact is caused by implementation timing rather than RTL event semantics.
