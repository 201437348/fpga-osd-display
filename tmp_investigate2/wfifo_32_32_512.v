`timescale 1ns/1ps
// Placeholder write-side FIFO. The write path (write_req/write_en) is never
// driven in this steady-state read-only testbench, so this stub only needs
// to keep frame_read_write.v / frame_fifo_write.v elaborating cleanly without
// producing X-propagation into signals the read path depends on.
module wfifo_32_32_512 #(
    parameter AL_FULL_NUM = 256
) (
    input         clkr,
    input         clkw,
    input         rst,
    input         we,
    input         re,
    input  [31:0] di,
    output        empty_flag,
    output        full_flag,
    output        afull,
    output [8:0]  wrusedw,
    output [8:0]  rdusedw,
    output [31:0] dout
);
    assign empty_flag = 1'b1;
    assign full_flag  = 1'b0;
    assign afull      = 1'b0;
    assign wrusedw     = 9'd0;
    assign rdusedw     = 9'd0;
    assign dout          = 32'd0;
endmodule
