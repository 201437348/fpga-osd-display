# Optimized TF WAV HDMI Audio

## Goal

Replace the current oversized background-audio storage format with a
demonstration-grade implementation that uses substantially less EG4S20 block
RAM without changing the existing TF image, OSD, HDMI video, SDRAM, or card
recovery behavior.

The system plays one looping background track while a valid image is shown.
Changing pictures, automatic picture playback, and the normal image-loading
path must not restart or pause the track. Missing, malformed, or removed audio
media must produce silence only; image playback remains operational.

## User Media Contract

The TF card remains FAT32 and `BGM.WAV` remains in its root directory. The
recommended export contract is:

- File name: `BGM.WAV`
- Container: RIFF/WAVE
- Codec: signed PCM
- Sample rate: 48000 Hz
- Channels: stereo
- Resolution: 16-bit

This provides a 192000-byte-per-second stream, one third less input bandwidth
than the previous 24-bit stream. The loader continues to walk RIFF chunks and
supports fragmented FAT32 cluster chains. Existing support for the official
48 kHz, stereo, 24-bit WAVE_FORMAT_EXTENSIBLE PCM file remains accepted for
compatibility, but it is not the preferred final demonstration media.

## Chosen Architecture

`fat32_wav_loader` parses the preferred 16-bit PCM frame as four little-endian
bytes and emits `{left[15:0], right[15:0]}`. It retains the existing 24-bit
compatibility parser; for that legacy path it explicitly discards the least
significant eight bits of each channel and emits the same normalized 32-bit
representation. The loader rejects all other sample rates, channel counts,
and compressed formats.

The source-clock domain writes a 32-bit-by-1024-frame asynchronous FIFO and
the 25 MHz HDMI pixel-clock domain reads it. FIFO levels use the following
fixed values:

| Control | Frames | Time at 48 kHz |
| --- | ---: | ---: |
| Capacity | 1024 | 21.33 ms |
| Start playback | 512 | 10.67 ms |
| Start refill | 256 | 5.33 ms |
| Stop refill | 768 | 16.00 ms |

The shared SPI sector arbiter remains unchanged: directory scanning has first
priority, audio refill has second priority, and image loading has third
priority. No requester may preempt a physical sector that is already active.
The chosen 21.33 ms buffer prevents an image sector or a FAT lookup from
causing an audible gap while still reducing audio FIFO storage from 98304 to
32768 bits. On EG4S20 this reduces the estimated audio FIFO cost from about
11 BRAM9K blocks to about 4 BRAM9K blocks.

`audio_pcm_player` continues to generate exactly 48000 sample-valid pulses per
second from the 25 MHz video clock. It left-justifies each 16-bit channel in
the 24-bit HDMI transmitter interface by appending eight zero LSBs, matching
the official I2S/HDMI sample alignment. HDMI remains configured as 48 kHz and
the audio clock regeneration parameters remain `N=6144`; no extra audio PLL
or I2S loopback is introduced.

The audio reader overrides the shared file-reader default of 4096 FAT32
clusters with the full 65535-cluster limit. The original default remains in
place for the BMP client. This prevents a multi-minute WAV from being
truncated at the old approximately-16 MiB boundary on a card formatted with
4 KiB clusters, while preserving a finite guard against a corrupt circular
FAT chain.

## Playback and Error Policy

The WAV loader starts after the directory scanner locates `BGM.WAV`, so audio
can fill in the background while the first image loads. HDMI PCM playback
begins only after both a valid display frame and the 512-frame FIFO prefill are
present. Reaching the data chunk end restarts the FAT32 reader at the start of
the same file and loops the track.

An empty FIFO, missing file, invalid WAV header, malformed RIFF chunk, FAT
error, SD removal, or storage reinitialization drives zero-valued PCM at the
48 kHz cadence. SD reinitialization clears the FIFO and starts discovery again;
a later valid `BGM.WAV` resumes background playback after the usual prefill.

## Implementation Scope

The implementation changes only project-owned audio interfaces and tests:

- `rtl/storage/fat32_wav_loader.v`
- `rtl/storage/image_storage_adapter.v`
- `rtl/audio/audio_pcm_player.v`
- `rtl/top/top.v`
- audio-focused simulation testbenches

The project manifest is updated only if a new source file is required. The
existing SDRAM hard macro, generated FIFO implementation, video clocks, HDMI
PHY, video timing, image loader, OSD, and button behavior are not modified.

## Verification

Simulation must cover the following conditions before board testing:

1. standard 48 kHz, stereo, 16-bit PCM parsing across a sector boundary;
2. little-endian sample reconstruction and 16-bit-to-24-bit left alignment;
3. loop restart, a fragmented FAT32 file, and RIFF chunk padding;
4. unsupported audio and malformed input becoming silence without an image
   failure;
5. FIFO prefill, low/high-water refill hysteresis, and underflow silence;
6. audio refill interleaved with a normal image load without sector
   preemption; and
7. structural top-level elaboration with the existing HDMI transmitter ports.
8. a 4097-cluster FAT32 audio chain, which crosses the former 4096-cluster
   cutoff without reporting an error.

TD GUI verification is limited to `syn_1` and `phy_1`, followed by JTAG board
testing. The board test checks audible continuous music, manual image change,
automatic rotation, TF removal, and card reinsertion. The user performs TD and
hardware actions; this work does not invoke TD command-line builds or change
configuration Flash.

## Out of Scope

Multiple tracks, per-image audio, playback controls, volume controls, sample
rate conversion, compressed codecs, and arbitrary WAV sample rates are not
part of this implementation. The media-export contract intentionally keeps the
hardware small, deterministic, and aligned with the official 48 kHz HDMI
example.
