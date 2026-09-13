# Solid-Frame No-Feather Diagnostic Design

## Goal

Separate the moving white boundary from the fixed left-edge A/B color lines.

## Design

Keep the real SDRAM solid red/green frame diagnostic unchanged and disable
only `SLIDE_FEATHER_ENABLE` at the production top. This removes the overlap
cache and blend phases while retaining the same slide positions, direct old
and new reads, asynchronous FIFO, and display backend.

## Board Interpretation

- White moving line disappears: it originates in the feather cache or blend
  pipeline.
- White moving line remains: it is a direct-path data alignment artifact.
- Record A and B independently; their behavior locates the separate fixed-edge
  contamination.
