# Registered Read FIFO Alignment Design

## Goal

Eliminate previous-line tail pixels leaking into the first pixels of the next
active video line.

## Design

Keep the display read FIFO in its block-RAM-friendly configuration with
`SHOW_AHEAD_EN=0` and `OUTREG_EN="OUTREG"`. Export the FIFO `valid` signal to
the video clock domain alongside `dout`.

`video_delay` requests each word at `de_d[16]`. When `valid` asserts, it pushes
the returned RGB word into a four-entry synchronous alignment queue. At
`de_d[19]`, it consumes exactly one queued word for the active pixel. Concurrent
push/pop is supported, including direct bypass if the queue is empty. Keep the
existing output timing (`de_r=de_d[20]`) unchanged. Sticky internal overflow
and underflow flags make alignment failures visible to simulation without
changing the board interface.

## Verification

The line-boundary test uses two rows with deliberately unrelated last/first
pixels and the generated FIFO model in registered-output mode. The multiframe
slide test uses the same mode, checks every displayed pixel, and requires both
alignment fault flags to remain clear. Solid red/green frames with feathering
disabled remain enabled for board verification.

The rejected show-ahead/NOREG approach passed simulation but caused TD to
expand the 512x32 FIFO into logic (`PHY-9009`, 6229 mslices versus 4900).
