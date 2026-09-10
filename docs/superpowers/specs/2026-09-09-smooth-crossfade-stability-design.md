# Smooth Crossfade Stability Design

## Goal

Make the selected diagonal crossfade look continuous to the naked eye while
eliminating transition-only rectangular corruption and preventing the moving
highlight from overpowering the image blend.

## Observed Problems

- Sixteen alpha levels complete in about 0.28 seconds at 60 Hz.  Each 6.25%
  jump is visible as a separate brightness step.
- The diagonal center advances about 70 pixels per frame, making the accent
  jump rather than sweep.
- The current colored highlight subtracts unsigned RGB channels.  When a
  picture channel exceeds the highlight target, the subtraction wraps and can
  produce an unexpectedly dark or strongly colored stripe.
- Old and new FIFOs are serviced in 256-word groups.  Shorter alternating
  groups reduce the maximum time either FIFO waits for a refill and therefore
  reduce the risk of transition-only underflow artifacts.

## Selected Design

The transition controller will expose a 7-bit alpha from 0 through 64 and
advance once per video frame.  The resulting transition lasts about 1.08
seconds at 60 Hz and changes opacity by 1.5625% per frame.

The blender will divide weighted RGB sums by 64.  The diagonal center will be
calculated from the alpha value in roughly 18-pixel steps instead of using the
old 70-pixel lookup table.  The hard red/gold band will become a narrow soft
white accent that moves each frame and brightens each channel only slightly
toward white; this calculation cannot underflow or wrap.

The frame reader will use 128-word bursts for both old and new transition
streams.  It will retain the prior real-`Sdr_rd_en` return accounting, so the
route remains stable until all 128 returned words reach the selected FIFO.
The frame length and SDRAM addresses do not change.

## Scope

Only the transition controller, blender, dual-frame read burst setting, and
their focused tests change.  Image loading, FAT32, TF recovery, audio, OSD,
HDMI timing, SDRAM frequency, memory map, and normal first-image behavior stay
unchanged.

## Verification

Simulation must cover alpha endpoints, an exact midpoint blend, 64 frame
steps, transition release after the final full-new frame, non-wrapping warm
white highlight output, 128-word production burst integration, delayed SDRAM
returns, complete addresses, and correct old/new return routing.

Board validation uses JTAG before Flash.  Repeated KEY2 transitions and
several KEY4 automatic cycles must show a roughly one-second continuous blend,
an understated moving accent, no blocks, no stripes, no tearing, and no audio,
OSD, or TF-recovery regression.

## Fallback

If any transition-only corruption remains after this revision, stop extending
the dual-frame implementation.  Replace it with a single-frame fade-through-
white transition, which preserves a deliberate exit and entrance while
removing simultaneous old/new SDRAM reads.
