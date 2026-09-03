# Storage Initialization Fallback Design

## Scope

This change addresses only the no-card startup path in the project-owned
image load manager. It does not modify vendor SD, SDRAM, FIFO, or HDMI logic.

## Behavior

- If TF initialization has not completed after 10 seconds and no frame has
  ever been committed, display the existing eight-color fallback bars.
- Report the condition as error code `4` on the final diagnostic digit.
- If a valid frame is already displayed, loss of storage readiness must keep
  that frame visible and must not enable the fallback bars.
- A later successful frame commit clears the fallback selection and error.

## Implementation

`image_load_manager` gains an independently parameterized storage-init
timeout counter. The counter runs only while `storage_ready` is low and is
cleared immediately once initialization succeeds. Existing per-image loading
timeouts and their two retries are unchanged.

## Verification

The manager unit test uses a shortened init timeout and verifies that a
no-card startup selects the fallback pattern, keeps `display_valid` low, and
reports error code `4`. Existing tests continue to verify that storage loss
after a committed frame retains that frame.

## Hardware Acceptance

Download through JTAG only. With no TF card inserted, wait approximately
10 seconds and confirm color bars plus diagnostic error code `4`. Do not
program configuration Flash for this test.
