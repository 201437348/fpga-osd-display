# TF Hot-Removal Automatic Audio Recovery

## Goal

Recover automatically from TF card removal and reinsertion without requiring a
picture-change button. A valid image already held in SDRAM remains on screen
throughout recovery. When the card is reinserted, the project rediscovers
`BGM.WAV`, refills audio, and resumes the track from its start.

## Observed Failure

The board has no project-connected TF card-detect input, and the vendor SPI SD
controller does not time out a missing card. After removal it can retain
`sd_init_done=1` and hold a sector-read request indefinitely. Audio then
underflows to silence, but the existing image manager receives no storage-loss
event. A later next-image request eventually exercises the existing failed-load
reinitialization path, which explains the observed `341...`, `540003`, and
second-button recovery.

## Chosen Design

Add a project-owned liveness watchdog at the one physical SD sector interface
inside `image_storage_adapter`.

When `sd_sec_read` is active, any `sd_sec_read_data_valid` byte or
`sd_sec_read_end` pulse proves forward progress and resets the watchdog. If no
progress occurs for 250 ms, the adapter emits one `storage_fault_pulse` and
latches the fault until the SD core is reset. The timeout is far longer than a
normal high-speed SPI command and 512-byte transfer, so it does not change
normal image or audio arbitration. It detects an unplugged card after the
audio FIFO reaches its refill watermark and the next audio sector receives no
response.

The pulse is passed directly to `image_load_manager`, which shares the
`sd_card_clk` domain. It has priority over ordinary load and button events:

1. retain `display_valid`, display-buffer selection, and current image index;
2. abort any pending image load;
3. emit the existing one-cycle `storage_reinit` reset to the SD adapter and
   audio FIFO; and
4. remember that this is a display-preserving hot-removal recovery.

The reset makes `sd_init_done` deassert, so the OSD naturally shows `WAIT TF`.
With no card, the manager remains in reset-wait while retaining the prior
image. After reinsertion and successful SD initialization, it requests a
directory scan. The adapter rediscovers both BMP metadata and `BGM.WAV` and
starts its audio loader. For the display-preserving recovery case, the manager
records the new image count and returns directly to idle after the scan; it
does not reload or switch an image. The audio player resumes only after its
existing 512-frame prefill, so playback starts from the beginning without a
partial or stale FIFO frame.

## Scope

Modify only project-owned control and verification code:

- `rtl/storage/image_storage_adapter.v`: sector-progress watchdog and fault
  pulse;
- `rtl/control/image_load_manager.v`: display-preserving reinitialization;
- `rtl/top/top.v`: same-clock fault connection;
- storage-adapter and load-manager testbenches; and
- the continuous project report.

The generated SD controller, FAT32 loaders, WAV parser, audio FIFO depth,
HDMI PCM/ACR, SDRAM, image frame buffers, video timing, OSD renderer, and pin
constraints remain unchanged.

## Error and User-Visible Behavior

Normal sector transfers reset the watchdog every returned byte. A persistent
missing-card request causes one fault, not a fault storm. The reset releases
the stuck arbiter grant and clears the audio FIFO. The old SDRAM frame remains
selected and the OSD reports `WAIT TF` until card initialization succeeds. A
card that returns with invalid media produces the existing scan/error behavior
and silence, while the old frame remains intact.

The 250 ms watchdog interval is an upper-bound detection delay, not an audio
buffer length. Audio normally becomes silent after its existing short FIFO
buffer drains; the watchdog then guarantees automatic recovery rather than
waiting for a user button.

## Verification

Simulation must demonstrate:

1. normal SD sector bytes and end pulses never fault the watchdog;
2. an active request with no returned progress produces one fault at the
   configured interval;
3. a fault emits `storage_reinit`, retains a committed display frame, and
   clears stale image-load state;
4. after a recovered scan, image metadata is refreshed but no BMP load is
   started and the current frame/index remain unchanged; and
5. a normal manual image change and normal automatic play still load the next
   frame after a non-fault scan.

Board acceptance covers immediate reinsertion, ten-second removal, and at
least one-minute removal. All three must enter `WAIT TF` after removal, retain
the old image, enter `SCAN` after reinsertion, and resume `BGM.WAV` without a
button. Once sound returns, manual next and automatic playback must remain
continuous.

## Exclusions

This design does not add a physical card-detect signal, multi-track recovery,
or a new audio status display. It intentionally uses transaction liveness so
it works with the current board connections and protects both image and audio
users of the shared SD SPI interface.
