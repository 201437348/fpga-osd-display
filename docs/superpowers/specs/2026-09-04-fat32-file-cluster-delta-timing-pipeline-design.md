# FAT32 File Cluster Delta Timing Pipeline

## Goal

Remove the final file-reader setup violation in the `sd_card_clk` domain. The
remaining path combines `current_cluster - 2` with multiplication by the
sectors-per-cluster value before registering the file cluster offset.

## Scope

Only the internal preparation states of `fat32_file_sector_reader` change.
The public interface, file-sector protocol, directory scanner, BMP loader,
SD-card ownership, SDRAM, clocks, constraints, video, OSD, and configuration
Flash remain out of scope.

## Design

Replace the single `ST_CALC_CLUSTER_OFFSET` preparation state with two states:

1. `ST_CALC_CLUSTER_DELTA` registers
   `current_cluster_delta = current_cluster - 2`.
2. `ST_CALC_CLUSTER_OFFSET` registers
   `current_cluster_sector_offset = current_cluster_delta * sectors_per_cluster`.
3. The existing `ST_READY` state retains its registered-offset address
   calculation, request validation, acknowledgement, and transition to
   `ST_READ_DATA`.

Initial valid metadata and a valid FAT successor both enter
`ST_CALC_CLUSTER_DELTA`. A sector advance that remains in the current cluster
continues to return directly to `ST_READY`.

Both preparation states keep `sd_sec_read` low and produce no data,
acknowledgement, completion, or error pulse. The loader holds its request
until acknowledgement, so two preparation cycles cannot lose or reorder a
logical sector request.

## Error Handling

Invalid startup metadata, nonsequential requests, invalid FAT entries,
premature end-of-chain, traversal-limit errors, and abort keep their current
behavior. They bypass or exit the new preparation states without a new
externally visible signal.

## Verification

Extend `tb_fat32_file_sector_reader` so its preparation monitor covers both
states and rejects any SD request during either. The fragmented file must
observe four preparation cycles, two for the initial cluster and two for the
valid successor, while preserving physical request order
`106, 107, 20, 134, 135` and byte order.

Run directory scanner, file reader, BMP loader, real FAT32 adapter, adapter
unit, load manager, playback control, OSD, and BMP-throttle tests, followed
by top-level Icarus structural elaboration. Request a TD GUI rebuild after
these local checks pass.

Acceptance requires no new RTL errors or simulation regression and a
nonnegative `sd_card_clk` WNS for the file reader. The known external SDRAM
global WNS remains approximately `-6.565 ns`; configuration Flash is not
programmed before JTAG-only validation passes.

## Git

This design document is not committed in this step. Git changes remain under
explicit user control.
