# TF WAV HDMI Background Audio

## Goal

Add continuous background audio from `BGM.WAV` in the FAT32 root directory to
the existing HDMI output. The first release plays one looping background track
independently of image changes.

The audio format is deliberately narrow: PCM WAV, 48 kHz, 24-bit, stereo,
little-endian, with a 6-byte block alignment and a 288000-byte-per-second data
rate. Unsupported, missing, damaged, or unavailable audio must be silent and
must not change image playback behavior.

## Scope

This work adds project-owned FAT32 WAV discovery, streaming, buffering, HDMI
PCM presentation, and ACR generation. It reuses the existing FAT32 file-chain
reader, TF SPI controller, generated asynchronous FIFO source, video clock,
and encrypted HDMI transmitter interface.

The SDRAM hard macro, frame buffers, image load manager, image playback
controls, video timing, HDMI PHY, PLL settings, and configuration Flash
behavior are not changed. Per-image music, volume controls, mute controls,
waveform display, sample-rate conversion, compressed audio, and non-PCM WAV
formats are out of scope.

## File Discovery

`fat32_directory_scan` continues through the root-directory chain until the
end marker or its existing traversal limit. It retains the first four regular
BMP records as before and independently records one regular short-name entry
whose 8.3 name is exactly `BGM     WAV`.

The scanner exports a BGM-found flag, first cluster, and byte length. Scanning
past four BMP files is necessary because `BGM.WAV` may occur later in the root
directory. A missing BGM record is successful image scanning with disabled
background audio, not a scan error.

## Audio Data Path

`image_storage_adapter` retains ownership of the one physical TF SPI sector
interface. It adds a project-owned `fat32_wav_loader`, which has its own
instance of the existing `fat32_file_sector_reader`. Therefore `BGM.WAV` may
be fragmented across a FAT32 cluster chain.

The WAV loader requests file sectors sequentially, parses the RIFF container,
and emits one 48-bit FIFO word per audio frame in the order
`{left_sample[23:0], right_sample[23:0]}`. Each 24-bit PCM channel is formed
from its WAV little-endian bytes without numerical conversion.

The parser accepts a RIFF/WAVE file with PCM format code 1, two channels,
48000 Hz, 24 bits per sample, 6-byte block alignment, and byte rate 288000. It
walks word-aligned chunks to locate `fmt ` and `data`, including legal extra
format bytes and ignorable chunks. The header search is limited to the first
16384 file bytes; exceeding that bound, missing required chunks, an invalid
chunk size, or a data length not divisible by six is an audio-only error.

At the `data` chunk end, the loader starts a new file-reader session from
logical sector zero and parses the header again. This provides a deterministic
loop without assuming that the WAV clusters are consecutive.

## Shared TF Arbitration

No request can preempt an active 512-byte physical SD sector. A new sector
arbiter has scanner, audio, and image request inputs and holds its grant until
the granted source drops its sector-request level. It inserts one low-request
clock between grants to preserve the existing SD-card controller contract.

Priority at an idle sector boundary is:

1. directory scan;
2. audio refill; and
3. image loader.

Directory scans occur before normal image and audio playback, including card
recovery. Once scanning completes, audio can defer the next image sector but
never interrupt an image sector already in progress. This guarantees that a
shared SPI controller remains protocol-correct while favoring continuous
sound. Image switching can become modestly slower during an audio refill
burst; it must retain its current retry and previous-frame protections.

## FIFO and Clock Domains

The existing Anlogic `EG4_Soft_FIFO` implementation is instantiated as a
48-bit, 2048-frame asynchronous FIFO. It writes in `sd_card_clk` and reads in
`video_clk`, retaining the generated Gray-pointer CDC and reset-release
protocol. Its 12288-byte capacity stores approximately 42.7 ms of stereo PCM
and consumes an estimated 11 BRAM9K blocks. The latest build uses 14 of 64
BRAM9K blocks, so the audio buffer remains within the device budget.

In the write domain, a refill burst starts at or below 512 stored frames and
continues until at least 1536 frames are stored. The parser requests sectors
only where enough FIFO capacity remains for the maximum 86 whole frames from
a 512-byte sector.

In the video domain, playback begins after at least 1024 frames are available.
A 25 MHz fractional accumulator produces exactly 48000 sample-enable pulses
per second. On every enable, the PCM player advances the FIFO and drives the
current frame to HDMI. On FIFO underflow, before prefill, or after an audio
error, it drives zero-valued stereo samples but continues issuing 48 kHz audio
valid pulses.

## HDMI Audio

The HDMI transmitter remains configured with `AUDIO_SAMPLE_RATE = "48K"`.
The PCM player connects directly to the transmitter `I_audio_valid`,
`I_audio_left_data`, and `I_audio_right_data` inputs in the existing
`video_clk` domain; no audio PLL and no I2S serial loopback are added.

A project-owned ACR generator follows the official reference behavior with
`N = 6144`, receiving the same 48 kHz valid stream and driving
`I_acr_valid`, `I_acr_cts`, and `I_acr_n`. This replaces the current permanent
zero audio and ACR connections only.

## Error Handling

The following conditions force silent samples and stop the affected WAV
session without resetting the image path: BGM absent, invalid directory record,
unsupported WAV fields, malformed RIFF/chunk structure, excessive header
length, invalid data length, FAT traversal error, or SD initialization loss.
FIFO underflow instead produces silence while the active WAV session continues
refilling the buffer.

When card initialization returns and directory scanning supplies valid BGM
metadata, the audio loader restarts, refills the FIFO, and resumes playback.
Existing no-card color-bar fallback and prior-frame retention behavior remain
unchanged.

## Verification

Add focused simulations for:

1. root-directory BGM discovery after four BMP entries;
2. canonical and padded-chunk WAV parsing, PCM byte order, loop restart, and
fragmented FAT32 WAV clusters;
3. invalid WAV metadata, missing BGM, malformed chunks, and FAT errors
producing silence without an image error;
4. audio FIFO prefill, low/high-water refill behavior, underflow silence, and
48 kHz cadence from the 25 MHz clock;
5. sector arbitration priority, non-preemption of an active image sector, and
one-low-clock request turnaround; and
6. HDMI audio/ACR top-level connections alongside existing image, OSD,
playback-control, and recovery regressions.

After local simulation and structural elaboration pass, TD GUI `syn_1` and
`phy_1` must be reviewed before JTAG download. Initial JTAG acceptance is
continuous audible `BGM.WAV`, valid first image, repeated manual image
changes, automatic playback, and TF removal/reinsertion. Configuration Flash
is not changed until those checks pass.

## Git

No Git operation is part of this work. Repository commits remain under
explicit user control.
