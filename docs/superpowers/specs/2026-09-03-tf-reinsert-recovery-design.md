# TF Reinsert Recovery Design

## Scope

This change restores the TF/BMP reader after a card is removed during a read
and later reinserted. It does not reset SDRAM, HDMI, PLLs, or the active frame.

## Trigger

After all candidate images fail, the manager reports error code `3` and stays
idle with the prior frame visible. When the user reinserts the card and presses
`KEY1`, the manager emits a one-cycle `storage_reinit` request.

## Data Flow

The request asynchronously resets only `image_storage_adapter` and its
contained `bmp_read` and `sd_card_top` instances. The SD core deasserts
`storage_ready`, performs its normal initialization, and the manager then
rescans the card before loading the requested successor frame.

Automatic-play requests do not restart a reader in error state. A deliberate
manual `KEY1` action is required to prevent repeated SPI resets while no card
is installed.

## Verification

The manager test verifies the `storage_reinit` pulse after error code `3`.
The adapter test verifies that the pulse clears scan state and cached metadata.
Hardware acceptance is JTAG-only: display a frame, remove the card during the
next-image request until error `3`, reinsert the card, press `KEY1`, then
confirm a new image appears after normal initialization and scanning.
