# SDRAM Read Preroll Implementation Plan

**Goal:** Discard stale SDRAM data before every visible read chunk.

**Spec:** `docs/superpowers/specs/2026-09-13-sdram-read-preroll-design.md`

### Task 1: Reproduce stale returns

- [x] Add a two-command stale-address SDRAM response model.
- [x] Require exact old/new segment pixels and explicit preroll command count.

### Task 2: Add preroll states

- [x] Add parameterized preroll issue and return-wait states.
- [x] Hold the first payload address and discard every preroll response.
- [x] Verify four preroll words remove the solid-color A/B artifacts.
- [x] Reject sixteen-word preroll after it produced almost no further board
  improvement with real images.
- [x] Restore four-word preroll and use complete 128-word payload bursts,
  discarding surplus tail returns before every address switch.

### Task 3: Regress and observe

- [x] Run focused, scheduler, FIFO, video, and diagnostic tests.
- [x] Run 640x480 full-frame and real/stub top elaboration checks.
- [x] Build and observe the board with solid SDRAM data and confirm the A/B
  artifacts disappear.
- [x] Build and observe the board with real image data restored and feathering
  still disabled.
- [x] Confirm fixed 128-word bursts remove both real-image artifacts with
  feathering disabled.
- [x] Reject feathering with fixed bursts after hardware showed incomplete
  frames, severe multidirectional ghosting, rollback, and a blocked next key.
- [x] Restore the board-proven feather-disabled fixed-burst configuration.
