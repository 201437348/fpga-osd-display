# SDRAM Busy Read Backpressure Design

## Goal

Prevent refresh stalls from dropping read commands and deadlocking
`frame_slide_fifo_read` while preserving the existing SDRAM interface.

## Behavior

`App_rd_en` is asserted only while the scheduler is in `S_ISSUE` and
`Sdr_busy` is low. When `Sdr_busy` is high during `S_ISSUE`, `issue_count` and
`App_rd_addr` hold their values. Return processing remains independent because
already accepted commands may return while the controller reports busy.

The last command in a chunk moves the scheduler to `S_WAIT_RETURN` only on a
non-busy cycle in which `App_rd_en` is actually asserted. This keeps issued
command count, address advancement, and expected return count identical.

## Alternatives

A retry queue would require an explicit controller acceptance contract that
the existing interface does not expose. Making the simulation model queue
commands during busy would hide the production RTL defect. Direct gating and
state freezing therefore provides the smallest implementation consistent
with the available `Sdr_busy` backpressure signal.

## Verification

Extend the scheduler unit test with busy pulses covering the beginning,
middle, and end of command chunks. During each busy cycle, require
`App_rd_en=0`, a stable address, and a stable issue counter. After release,
require a contiguous address trace, the exact expected command/output counts,
`read_finish`, and no `read_fault`.

Then rerun the seven-case refresh matrix. Every run must reach 24 frames with
`dropped_commands=0`, `scheduler_stuck=0`, and no underflow after
`display_valid` becomes active.

## Scope

Modify only `frame_slide_fifo_read.v` and its tests. The write scheduler,
legacy read scheduler, dual-FIFO scheduler, SDRAM wrapper, and vendor FIFO IP
remain unchanged.
