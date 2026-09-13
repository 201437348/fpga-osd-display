# Read Address Pattern Diagnostic Design

## Goal

Separate the SDRAM read-address sequence from the returned memory payload as
the source of the motion-only left-edge line.

## Design

Latch each chunk's first accepted address. Because the scheduler permits only
one sequential chunk in flight, the address paired with each in-order
`Sdr_rd_en` is exactly `chunk_base + return_count`. Use that address to
generate a 128-pixel-period RGB ramp instead of consuming `Sdr_rd_dout`. Both
the 640-pixel line width and the two production frame-base addresses are
multiples of 128, so the synthetic pattern has the same phase at each line and
in each buffer.

Keep commands, return timing, scheduler phases, feathering, FIFO writes, and
all downstream display logic unchanged. Apply the pattern only to accepted
slide frames; static frames use real SDRAM pixels.

## Board Interpretation

- Clean repeating ramps with no extra physical-left line: the address sequence
  and scheduler are clean; the defect is in real SDRAM returned payloads or
  their association with return-valid.
- The extra physical-left line returns: inspect the issued address sequence or
  its scheduler phase boundary.
