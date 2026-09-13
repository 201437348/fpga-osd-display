# SDRAM Return Uniform Diagnostic Design

## Goal

Determine whether the motion-only left-edge color line originates in real
SDRAM pixel data/addressing or inside the slide scheduler's composition and
output pipeline.

## Design

Add a disabled-by-default parameter to `frame_slide_fifo_read`. For an
accepted slide frame, replace `Sdr_rd_dout` at the scheduler's return-data
consumption point with one 32-bit color derived from the latched slide
position. Keep real `App_rd_en`, `App_rd_addr`, `Sdr_rd_en`, phase changes,
return counts, overlap cache, feather pipeline, FIFO writes, and all downstream
logic unchanged. Static frames continue consuming real SDRAM pixels.

Pass the parameter through `frame_read_write`. In `top.v`, disable the existing
final FIFO-payload override and enable this return-entry override.

## Board Interpretation

- No line: the scheduler and its output pipeline are clean; investigate real
  SDRAM return pixels and addresses.
- Line returns: investigate the scheduler's phase, cache, feather, or output
  pipeline after return data enters it.
- Static images must remain normal.
