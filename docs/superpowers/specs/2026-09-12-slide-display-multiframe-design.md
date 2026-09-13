# Slide Display Multi-Frame Diagnostic Design

## Goal

Determine whether moving-frame color artifacts are caused by stale pixels
crossing the scheduler, asynchronous FIFO, and video-delay boundaries.

## Design

Build a focused integration test around the real `frame_slide_fifo_read`, the
project's behavioral `rfifo_32_32_512`, and the real `video_delay`. Run the
memory side at 125 MHz and the video side at 25 MHz. Encode buffer, row, and
column in every SDRAM response so a pixel from another row, frame, or slide
position is immediately distinguishable.

Run consecutive 64-by-2 frames at slide positions 0, 2, 20, 35, 48, 62, and
64. Consume each frame as two active video lines and compare all 128 displayed
pixels, with failures reporting frame position, row, and x. Marker logic stays
outside this test so it cannot hide stale data.

## Interpretation

- A mismatch in the first 32 pixels identifies a scheduler/FIFO/video-delay
  boundary defect and provides the exact stale source value for a fix.
- A clean run proves the RTL functional chain is coherent under modeled CDC;
  the next hardware diagnostic must then distinguish physical FIFO reset/CDC
  behavior from temporal display effects.

## Timing Finding

The integration regression passes all 896 pixels, but the board build does not
meet timing. `phy_1/final_timing.rpt` reports an `ext_mem_clk` same-clock path
with `-1.033 ns` setup slack from the write FIFO read pointer to
`frame_slide_fifo_read.phase_offset_reg[3]`. Related paths to `issue_count` and
`App_rd_addr` also fail setup.

The path crosses `frame_fifo_write`'s combinational FIFO-level addition and
comparison, then `O_wr_busy`, and finally the read scheduler's start decision.
Register the FIFO-data-ready decision inside `frame_fifo_write`; keep
`App_rd_busy` in the final burst-start condition so read and write transactions
cannot start together. `O_wr_busy` must still assert one clock before write data
is enabled, preserving its arbitration warning role while ending the long
FIFO-pointer-to-read-scheduler path at a register.

The white read-FIFO marker is diagnostic only. Disable it for the timing-fix
board build so the observed image is production behavior.

## Verification

The focused arbiter regression changes `rdusedw` between clock edges and
requires `O_wr_busy` to remain unchanged until the next edge. It also requires
the busy warning before `App_wr_en` and prevents a write start while
`App_rd_busy` is asserted.

The first post-fix physical build removed every former write-FIFO read-pointer
path to `phase_offset`, `issue_count`, and `App_rd_addr`. Its remaining three
`ext_mem_clk` same-clock violations were independent scheduler paths: two from
the overlap index through the asynchronous cache read and channel subtraction
to multiplier input registers (`-0.591 ns` and `-0.177 ns`), and one from the
cascaded row/address expression to `segment_addr` (`-0.031 ns`).

Add a raw-pixel stage before difference calculation so cache lookup ends at a
register, then calculate difference and direction, then multiply. Direct and
blended returns use the same valid pipeline, its FIFO occupancy reserve is four
words, and final completion waits for all three internal valid stages to drain.
Track old and new current-row base addresses directly and increment them once
per row, avoiding the cascaded `base + row_offset + position - half-width`
expression without changing any generated address.

The second post-fix physical build closes the complete
`ext_mem_clk -> ext_mem_clk` group at 125 MHz: worst setup slack is
`+0.107 ns`, Fmax is `126.695 MHz`, and there are zero violating endpoints.
The former write-FIFO, overlap-cache/multiplier, and cascaded row-address paths
are absent from the failing-path list.

After the fix, the focused test and the scheduler, full-line, multi-frame,
video-delay, RGB-to-AXIS, OSD, underflow, marker, and real/stub top regressions
pass. These regressions also pass after the raw-pixel and row-base timing
refinement. A 24-frame worst-stall refresh run (`stall=16`, FIFO depth 512) completes
with zero underflows, dropped commands, or scheduler stalls. The remaining six
refresh cases were already known to pass before this write-only change; an
attempted all-at-once rerun exceeded the 900-second per-process limit because
seven CPU-heavy Icarus jobs contended for the host. No design failure was
reported by those interrupted runs.
