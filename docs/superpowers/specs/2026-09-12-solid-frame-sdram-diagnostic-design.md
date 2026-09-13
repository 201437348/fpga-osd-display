# Solid-Frame SDRAM Diagnostic Design

## Goal

Expose any cross-buffer SDRAM read-data contamination without image texture or
camera/display motion blur obscuring the result.

## Design

Add a disabled-by-default `WRITE_BUFFER_SOLID_DIAGNOSTIC` parameter to
`frame_read_write`. At the write FIFO input only, replace buffer 0 pixels with
`32'hE0202000` and buffer 1 pixels with `32'h20E04000`. Keep write enables,
addresses, vertical flip, SDRAM commands, real SDRAM storage and return data,
the slide scheduler, asynchronous FIFO, and display backend unchanged.

Disable every read-side synthetic diagnostic in `top.v` and enable the solid
write mode. The board must therefore load and display two genuinely stored
solid-color frames through the complete memory path.

## Board Interpretation

- A left-edge line in the opposite buffer's color identifies cross-buffer
  return-data contamination or command/data association failure.
- No line means the original defect depends on intra-image pixel addressing or
  returned payload values and is masked by a spatially uniform frame.
