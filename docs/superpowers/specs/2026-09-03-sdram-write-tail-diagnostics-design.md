# SDRAM Write Tail Diagnostics Design

## Scope

This diagnostic identifies why image loading can remain in `341100` for more
than five seconds. It adds observability only; it does not change TF reads,
SDRAM requests, frame-buffer selection, reset behavior, or HDMI output.

## Trigger and Display

The normal six-digit display is `S C L R W X`:

- `S`: image-load-manager state
- `C`: scanned image count
- `L`: load active
- `R`: BMP source completion observed
- `W`: SDRAM frame-write completion observed
- `X`: error code

When, and only when, `S=3`, `L=1`, `R=1`, and `W=0`, the second digit (`C`)
will instead show the current `frame_fifo_write` state. The other five digits
retain their existing meanings. Thus an affected interval is displayed as
`3 F 1 1 0 0`, where `F` is the writer state.

## State Meanings

- `0`: writer is idle; a missing cross-clock completion notification is
  suspected.
- `2`: writer is waiting for enough FIFO data to start its final burst; a
  write-stream accounting or FIFO-tail issue is suspected.
- `3`: writer is issuing a burst; SDRAM arbitration or controller progress is
  suspected if this persists visibly.
- `4` or `5`: writer is completing the final burst or ending the transaction;
  a delayed completion notification is suspected if this persists visibly.

## Implementation Boundaries

`frame_fifo_write` exposes its existing internal state through a new debug
output. `frame_read_write` passes that output to `top`. `top` selects it for
the second seven-segment digit only during the trigger condition above. The
state machine and all existing data/control ports are otherwise unchanged.

## Verification

- Compile the top-level design with the existing Icarus static compile check.
- Run the existing manager, adapter, and playback-control tests unchanged.
- Hardware test: switch images until a slow `341100` interval occurs; record
  the second digit while it is delayed. The result selects the permanent
  repair path without modifying functional behavior in this diagnostic build.
