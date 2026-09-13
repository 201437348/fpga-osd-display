`timescale 1ns/1ps
// Clock-domain-correct behavioral replacement for the vendor async read FIFO.
// wptr only advances on clkw (mem_clk); rptr only advances on clkr (video_clk).
// empty/full/usedw are pure combinational functions of (wptr - rptr), using
// one extra pointer bit for wrap-safe occupancy math (standard async-FIFO
// pointer-difference trick). No Gray coding / CDC synchronizers are modeled
// here -- this is a functional testbench model, not a synthesizable macro --
// but each domain's pointer only ever ticks on its own clock edge, which is
// the property that matters for reproducing the real count trajectory.
module rfifo_32_32_512 #(
    parameter DEPTH = 512,
    parameter AW    = 9,
    parameter OUTREG_EN = "OUTREG"
) (
    input         clkr,
    input         clkw,
    input         rst,
    input         we,
    input         re,
    input  [31:0] di,
    output        empty_flag,
    output        full_flag,
    output [AW-1:0] wrusedw,
    output [AW-1:0] rdusedw,
    output [31:0] dout
);
    reg [31:0] mem [0:DEPTH-1];
    reg [AW:0] wptr; // AW+1 bits: extra bit disambiguates full vs empty on wrap
    reg [AW:0] rptr;
    reg [31:0] dout_r;

    initial begin
        wptr   = {(AW+1){1'b0}};
        rptr   = {(AW+1){1'b0}};
        dout_r = 32'd0;
    end

    wire [AW:0] diff       = wptr - rptr;
    assign empty_flag = (diff == {(AW+1){1'b0}});
    assign full_flag  = (diff == (DEPTH));
    // NOTE: diff needs AW+1 bits, but wrusedw/rdusedw match the vendor-style
    // AW-bit ports and can only represent 0..DEPTH-1. A naive truncation
    // aliases the full count to 0, which looks like "empty" to a consumer of
    // this bus -- that was a real bug caught via trace: it fooled the scheduler's
    // admission check (wrusedw < FIFO_START_LEVEL) into thinking there was
    // room when the FIFO was actually full, causing it to keep issuing SDRAM
    // reads whose writes then got silently dropped by the we&&!full_flag
    // gate. Saturate at the max representable value (511) when actually
    // full, matching how real FIFO megafunction usedw ports behave.
    assign wrusedw     = full_flag ? {AW{1'b1}} : diff[AW-1:0];
    assign rdusedw     = full_flag ? {AW{1'b1}} : diff[AW-1:0];
    assign dout          = dout_r;

    // ---- write side: advances only on clkw, gated only by full_flag ----
    always @(posedge clkw or posedge rst) begin
        if (rst) begin
            wptr <= {(AW+1){1'b0}};
        end else if (we && !full_flag) begin
            mem[wptr[AW-1:0]] <= di;
            wptr <= wptr + 1'b1;
        end
    end

    // ---- read side: advances only on clkr, gated only by empty_flag ----
    always @(posedge clkr or posedge rst) begin
        if (rst) begin
            rptr   <= {(AW+1){1'b0}};
            dout_r <= 32'd0;
        end else if (re && !empty_flag) begin
            dout_r <= mem[rptr[AW-1:0]];
            rptr   <= rptr + 1'b1;
        end
    end
endmodule
