# Image Load Input Lock Design

## Problem

While an image is loading, the current manager records another `KEY1` press
as `pending_next`. After the first image commits, it immediately starts a
second frame transaction. Hardware diagnosis showed that this back-to-back
transaction can stall in frame-writer state `2` (`321100`) until the
ten-second load timeout expires.

## Behavior

Manual next-image requests are accepted only while the image-load manager is
idle. The first press starts one image transaction. Further `KEY1` presses
from the start of that transaction until its commit or failure are ignored;
they are not queued for later execution.

The error-3 TF recovery action remains available because it occurs while the
manager is idle. Automatic playback behavior is unchanged: it already issues
requests only when the manager is idle.

## Implementation

- `image_playback_control` gates `next_request` with `manager_idle`.
- `image_load_manager` stops latching next-image requests while in non-idle
  states, so it cannot queue a request from another future request source.
- The temporary writer-state diagnostic signal path and its conditional
  seven-segment override are removed. The second digit always returns to the
  scanned image count.

No changes are made to the TF reader, SDRAM writer state machine, frame
buffers, HDMI pipeline, reset sequence, or load timeout value.

## Verification

- Run the existing manager, adapter, and playback-control unit tests.
- Run the existing top-level static compile check.
- Hardware acceptance:
  - One `KEY1` press loads exactly one successor image.
  - A second `KEY1` during that load is ignored; no delayed second switch and
    no ten-second `321100` wait occur.
  - TF removal/reinsertion recovery at error code `3` still works after one
    deliberate `KEY1` press.
