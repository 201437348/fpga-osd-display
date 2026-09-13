# Registered Read FIFO Alignment Implementation Plan

**Goal:** Align registered FIFO returns so every active line begins with its
own first pixel without expanding the FIFO into logic.

**Spec:** `docs/superpowers/specs/2026-09-12-show-ahead-read-fifo-design.md`

### Task 1: Prove registered-output misalignment

- [x] Switch the line-boundary test FIFO to registered OUTREG mode.
- [x] Run the existing implementation and require a first-pixel mismatch.

### Task 2: Implement valid-driven alignment

- [x] Export the read FIFO `valid` signal through `frame_read_write`.
- [x] Add a four-entry alignment queue to `video_delay`.
- [x] Run the focused line-boundary and multiframe tests.

### Task 3: Integrate and regress

- [x] Restore the production FIFO to registered OUTREG mode.
- [x] Run scheduler, FIFO, underflow, OSD, AXIS, transition, and top tests.
- [x] Check both manifests and `git diff --check`.

### Task 4: Board observation

- [ ] Rebuild the solid red/green no-feather image and inspect A/B.
