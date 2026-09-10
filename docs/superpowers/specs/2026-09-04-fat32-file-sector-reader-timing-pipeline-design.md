# FAT32 File Sector Reader Timing Pipeline

## Goal

Remove the remaining `sd_card_clk` setup-time violation in
`fat32_file_sector_reader`. The affected path calculates a physical SD-sector
address from the current FAT32 cluster, data-region base, and sector index.
Logical-sector ordering, file bytes, loader handshakes, and error behavior
must remain unchanged.

## Scope

Only the file-reader address preparation changes. Directory scanning, BMP
header and pixel decoding, SD-card ownership, SDRAM, clocks, constraints,
video, OSD, and configuration Flash are out of scope.

## Design

The current `ST_READY` state computes this expression in one clock:

```text
first_data_lba + ((current_cluster - 2) * sectors_per_cluster) + sector_in_cluster
```

Add `ST_CALC_CLUSTER_OFFSET` between cluster selection and `ST_READY`.
It registers:

```text
current_cluster_sector_offset = (current_cluster - 2) * sectors_per_cluster
```

`ST_READY` then uses the registered offset to assign the existing physical
sector address. It retains the existing sequential-index validation,
`file_sec_read_ack`, final-sector detection, and transition to
`ST_READ_DATA`.

`ST_IDLE` enters the new state after accepting valid initial file metadata.
`ST_PARSE_FAT` enters it only after accepting a valid successor cluster.
When another sector remains in the current cluster, `ST_READ_DATA` continues
to return directly to `ST_READY`; no extra cycle is added for that case.

The BMP loader keeps `file_sec_read` asserted until `file_sec_read_ack`, so
the extra preparation cycle cannot drop or reorder a request.

## Error Handling

Invalid startup metadata, nonsequential file-sector requests, premature FAT
end-of-chain, invalid FAT entries, traversal-limit failures, and abort retain
their existing states and externally visible pulses. The new state does not
issue an SD request or emit data, completion, or error pulses.

## Verification

Extend `tb_fat32_file_sector_reader` with a preparation-cycle counter and an
assertion that `sd_sec_read` is low in `ST_CALC_CLUSTER_OFFSET`. The fragmented
file test must observe one preparation cycle for the initial cluster and one
for its valid successor, while retaining physical request order
`106, 107, 20, 134, 135`.

Run the file-reader, BMP-loader, real FAT32 adapter, adapter unit,
load-manager, playback-control, OSD, and BMP-throttle tests, followed by
top-level Icarus structural elaboration. Then request a TD GUI rebuild.

Acceptance requires no simulation regression and no new RTL errors. The
file-reader must no longer be the `sd_card_clk` timing violation. The known
external SDRAM global WNS remains approximately `-6.565 ns`. Do not program
configuration Flash before JTAG-only validation passes.

## Git

This design document is not committed in this step. Git changes remain under
explicit user control.
