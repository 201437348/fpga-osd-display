# Write Request Acknowledge CDC Design

Date: 2026-09-04

## Scope

This change repairs one specific control crossing in the existing SD image
load path. It does not alter the PLL, SDRAM hard macro, generated Soft FIFO
IP, reset topology, pin constraints, or configuration Flash contents.

`bmp_read` runs on `sd_card_clk` and raises the level request `write_req`.
`frame_fifo_write` runs on `ext_mem_clk`, already passes that request through
three local registers, and returns the level acknowledgement `write_req_ack`.
Before this change, `bmp_read` sampled that acknowledgement directly across
the two clock domains.

## Selected Design

`image_storage_adapter` will add two registers clocked by its existing `clk`
(the SD-card clock): `write_req_ack_meta` and `write_req_ack_sync`. Both reset
asynchronously with the existing `core_rst`. `bmp_read.write_req_ack` will be
connected only to the second register.

The acknowledgement is a level handshake: the memory-side state machine keeps
it high until it observes the request return low through its existing request
synchronizer. The two SD-clock latency cycles therefore cannot lose the
acknowledgement. They instead give the metastability resolution time required
before the SD-domain reader state machine consumes the signal.

## FIFO And SDRAM Boundary

This change deliberately does not change `fifo_aclr`. The generated Anlogic
Soft FIFO RTL implements asynchronous assertion with local synchronous release
on both read and write sides. IPUG012 states that this reset mode releases only
after four local clock cycles and that operations must wait for local release.
The generated FIFO already contains the corresponding local reset-release
registers. Its generated Gray-pointer timing constraints must remain intact.

The APUG011 SDRAM reference confirms that frequency and phase must be tuned for
the actual hardware and that transactions must respect SDRAM busy/refresh
status. That independent SDRAM DQ timing issue remains out of scope here.

## Verification And Acceptance

The adapter unit test will prove that an acknowledgement reaches `bmp_read`
after exactly two SD-clock edges and remains visible for two edges after the
raw input falls. Existing project-owned tests and the top-level stub compile
must still pass.

After TD `syn_1`, `phy_1`, and bit generation, program JTAG only. Do not write
configuration Flash. Board acceptance covers first image, repeated manual
next, close-spaced manual next, automatic play, TF removal/reinsertion, and
OSD visibility. Capture routed timing and confirm that the prior raw
`ext_mem_clk` acknowledgement cone no longer ends in `bmp_read` state logic.
