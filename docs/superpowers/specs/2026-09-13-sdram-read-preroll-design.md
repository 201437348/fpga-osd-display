# SDRAM Read Preroll Design

## Goal

Prevent stale SDRAM return words from the preceding address segment from
appearing at the beginning of a new slide segment.

## Evidence

The left-edge A/B artifacts remain with real solid-color SDRAM buffers but
disappear when returned pixels are generated from the scheduler phase. The
same address sequence, output pipeline, asynchronous FIFO, video timing, and
HDMI path remain active in that diagnostic. This isolates the artifact to the
real `Sdr_rd_dout` data associated with discontinuous read-address changes.

## Design

Before every payload chunk, issue four reads while holding `App_rd_addr` at
the chunk's first address. Wait until all four responses have returned and
discard them. Then issue a complete 128-word SDRAM burst beginning at that
same address. Only the words required by the current image segment enter the
output pipeline; surplus tail returns are counted and discarded before the
next address segment can begin.

The scheduler exposes `READ_CHUNK_PREROLL_WORDS` and
`FIXED_READ_BURST_ENABLE`; both default to their legacy disabled behavior for
reuse. The production top selects four preroll words and fixed 128-word
bursts. Preroll and payload commands obey `Sdr_busy`, and `read_busy` remains
asserted until every surplus return has drained.

## Verification

A focused SDRAM model delays command addresses by two returns and verifies
both preroll and fixed-burst tail discard. Existing scheduler, 640x480 full-frame,
multiframe display, FIFO boundary, underflow, OSD, AXIS, transition, and top
elaboration tests must continue to pass.
