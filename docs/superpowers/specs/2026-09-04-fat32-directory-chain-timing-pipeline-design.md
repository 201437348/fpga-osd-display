# FAT32 Directory Chain Timing Pipeline

## Goal

Remove the remaining setup-time violation in the `sd_card_clk` domain of
`fat32_directory_scan`. The affected path calculates the next root-directory
cluster LBA after a FAT lookup. Existing SD-card behavior and FAT32 error
handling must remain unchanged.

## Scope

Only the valid successor-cluster branch of `ST_PARSE_FAT` changes. The boot
sector layout pipeline, file-sector reader, BMP loader, adapter, SDRAM, clocks,
constraints, video path, and OSD are out of scope.

## Design

The current valid successor branch calculates this value in one clock:

```text
first_data_lba + ((fat_next_cluster - 2) * sectors_per_cluster)
```

Add two states after a valid FAT successor is confirmed:

1. `ST_PARSE_FAT` registers `next_dir_cluster` and
   `next_dir_cluster_delta = fat_next_cluster - 2`, then enters
   `ST_CALC_NEXT_DIR_OFFSET`.
2. `ST_CALC_NEXT_DIR_OFFSET` registers
   `next_dir_sector_offset = next_dir_cluster_delta * sectors_per_cluster`.
   It keeps `sd_sec_read` low.
3. `ST_START_NEXT_DIR` calculates `first_data_lba + next_dir_sector_offset`,
   assigns the existing directory-LBA and SD-request-address registers,
   assigns the current cluster and traversal counters, then enters the
   existing `ST_READ_DIR` state.

The new states add two `sd_card_clk` cycles only when the root directory moves
to a successor cluster. A one-cluster root directory is unaffected.

## Error Handling

End-of-chain completion, invalid-cluster rejection, bad-cluster rejection,
and the root-directory traversal limit remain in `ST_PARSE_FAT` and bypass
the new states. The new states do not report `done` or `error` and do not
start an SD-card request.

## Verification

Extend `tb_fat32_directory_scan` with a counter for the two successor-address
preparation cycles and an assertion that `sd_sec_read` remains low in both
states. The existing multi-cluster root scan must retain its five-request
sequence and four discovered files. Empty-root, invalid-BPB, and cyclic-root
coverage remains required.

Run directory-scanner, FAT32 loader, FAT32 adapter, storage-adapter,
load-manager, playback-control, OSD, and BMP-throttle simulations, followed
by top-level Icarus structural elaboration. Request a TD GUI rebuild only
after local tests pass.

Acceptance requires no new RTL errors, no simulation regression, and
`sd_card_clk` WNS at or above zero for the directory scanner. The known
external SDRAM global WNS remains approximately `-6.565 ns`; configuration
Flash is not programmed before JTAG-only validation passes.

## Git

This design document is not committed in this step. Git changes remain under
explicit user control.
