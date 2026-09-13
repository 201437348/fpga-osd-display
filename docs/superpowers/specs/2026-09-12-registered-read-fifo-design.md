# Registered Read FIFO Boundary Fix Design

## Goal

Eliminate the fixed image-colored column at physical x=0 by replacing the
unregistered read-FIFO output with an explicit registered-output timing
contract.

## Evidence

Feather blending, FIFO underflow, AXIS backpressure, OSD composition, HDMI
framing, and the display-side left boundary have been excluded by independent
board tests.  The generated read FIFO is configured with
`SHOW_AHEAD_EN=0` and `OUTREG_EN="NOREG"`; its RAM output is therefore not
registered even though `video_delay` assumes a deterministic one-cycle read
response.  RTL simulation cannot model silicon-level RAM output settling at
the first read after horizontal blanking.

## Design

Override the production read FIFO instance with `OUTREG_EN="OUTREG"`.  This
adds one deterministic clock of output latency.  Move `video_delay.read_en`
from `de_d[18]` to `de_d[17]`, issuing each FIFO read two clocks before the
existing `de_d[19]` capture point.  Keep the capture point, output DE at
`de_d[20]`, and all HS/VS delays unchanged.

Restore the normal production presentation: feathering enabled, AXIS marker
disabled, and `vout_data_osd` connected to RGB-to-AXIS.  Retain the AXIS ready
counter implementation for evidence, but return the rightmost status digit to
its normal underflow/error display because ready backpressure was zero.

## Verification

Run the production FIFO plus `video_delay` boundary test with `OUTREG` enabled.
It must fail with the old one-clock read lead and pass after the read enable is
moved one clock earlier.  Require exact pixel order across two line boundaries.
Then run transition, full-line, OSD, AXIS, underflow, real-top and stub-top
regressions plus `git diff --check`.

## Board Acceptance

The normal OSD and feathered transition must be restored, the white marker
must be absent, and the fixed left-edge image-colored line must disappear.

