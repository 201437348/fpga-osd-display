# FAT32 BMP Loader Integration

## Goal

Replace the active player's assumption that each BMP occupies consecutive
physical SD-card sectors. The player will instead discover root-directory BMP
metadata from FAT32, follow the selected file's cluster chain, and deliver its
logical file sectors to a BMP decoder.

The integration must preserve the accepted playback controller, SDRAM write
path, FIFO IP, clock/reset topology, HDMI path, OSD behavior, and Flash
contents. The vendor `bmp_read.v` remains in the tree unchanged so the old
raw-sector implementation remains available as a reference.

## Chosen Architecture

Add a project-owned `fat32_bmp_loader` in the SD-card clock domain. It owns
one `fat32_file_sector_reader` instance and BMP header/pixel decoding. The
loader accepts one file's first cluster, byte size, first FAT LBA, first data
LBA, and sectors-per-cluster value. It exposes the same source-side behavior
used by the existing storage adapter:

```text
loader -> write_req, bmp_data_wr_en, bmp_data, done, error
loader -> sd_sec_read, sd_sec_read_addr
sd core -> sd_sec_read_data, sd_sec_read_data_valid, sd_sec_read_end
```

`fat32_directory_scan` will additionally expose the validated volume geometry
needed by the loader: `first_fat_lba`, `first_data_lba`, and
`sectors_per_cluster`. These values are valid when its `done` pulse reports a
successful scan. It will retain its existing first-four-file metadata outputs.

`image_storage_adapter` becomes the SD-card request owner. It uses an
adapter-local state machine to run exactly one of the directory scanner or
loader at a time, muxes that active component's raw request to `sd_card_top`,
and returns the raw response only to that same component. It snapshots four
file records and the volume geometry when scanning completes. A manager
`load_start` selects one stored record and starts the loader.

The public top-level adapter interface remains unchanged except for an
additional `source_error_pulse` routed to `image_load_manager`. The manager
will use it to abort and retry a malformed or damaged file immediately rather
than waiting for the existing ten-second source timeout. No physical-card
removal detection is added in this phase; accepted retained-frame and cold-boot
fallback behavior therefore remains unchanged.

## Header And Data Flow

A BMP's header and its first pixel bytes share logical sector zero. The
existing write-buffer allocation cannot be assumed to acknowledge within the
remaining bytes of that sector. The loader therefore uses two bounded passes:

1. Start a file-reader session and request logical sector zero. Parse and
   validate the BMP header, but do not emit pixels.
2. Once the first sector ends, abort the now-idle file-reader session, hold
   `write_req` until SDRAM acknowledges the selected write buffer, then start a
   new reader session from logical sector zero.
3. Request the file's logical sectors in order. Decode only file bytes from
   `pixel_offset` through `file_len - 1`; emit one RGB value per three bytes.
   On a sector end, request the next sector only when `write_fifo_afull` is
   low. This retains the proven boundary-only FIFO throttle behavior.

The first logical sector is intentionally read twice. This requires no 512-byte
buffer, does not depend on a timing assumption about the SDRAM acknowledgement,
and adds one SD-sector transfer per image only.

The file reader continues to follow FAT clusters and never exposes FAT lookup
bytes to the decoder. A final partial file sector is still consumed as 512
bytes, while the decoder ignores bytes at or after the BMP file length.

## Completion And Errors

The loader produces `done` only when the stream reaches the file reader's
normal `file_complete` event after a valid BMP header and all expected pixel
bytes have been processed. The adapter converts that normal completion into
the existing one-clock `source_done_pulse`.

An invalid BMP header, invalid file metadata, damaged FAT chain, or unexpected
loader termination produces a one-clock `source_error_pulse`. The adapter does
not issue `source_done_pulse` for that load. `image_load_manager` aborts the
load and follows its existing retry/skip/fallback policy immediately. The
incomplete SDRAM buffer is never committed because commit still requires both a
normal source completion and the existing write-side completion.

The loader honors `load_abort` only after its current physical SD request has
ended, matching the existing SD-core contract. The adapter prevents a new scan
or load until the active owner is idle.

## Verification

Add a focused `tb_fat32_bmp_loader` with the established 512-byte SD-sector
responder. It must cover a valid fragmented BMP, the deliberate first-sector
reread, BMP pixel ordering, a final partial sector, FIFO-full pause at a sector
boundary, invalid header rejection, and a damaged FAT chain.

Extend the directory scanner test to verify its exported volume geometry.
Replace the adapter's raw-`bmp_read` test stub with scanner and loader stubs to
verify metadata capture, SD-port ownership, normal source completion, and
source-error propagation. Extend the load-manager test for immediate
source-error retry and fallback behavior.

Run all existing project-owned tests, the new loader and directory tests, and
the top-level Icarus stub elaboration. Only after those pass will TD `syn_1`,
`phy_1`, and a JTAG-only board validation be requested. Configuration Flash is
outside this phase.
