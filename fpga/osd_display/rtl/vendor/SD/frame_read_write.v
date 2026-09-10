`timescale 1ns/1ps
module frame_read_write
#
(
	parameter MEM_DATA_BITS          = 32,
	parameter READ_DATA_BITS         = 32,
	parameter WRITE_DATA_BITS        = 32,
	parameter ADDR_BITS              = 21,
	parameter BURST_BITS             = 9,
	parameter BURST_SIZE             = 256,
	parameter READ_BURST_SIZE        = 128,
	parameter READ_FIFO_DEPTH        = 512,
	parameter WRITE_V_FLIP           = 1,
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480
)
(
	input                            rst,
	input                            mem_clk,
	input                            Sdr_init_done,
	input                            Sdr_init_ref_vld,
	input                            Sdr_busy,

	output                           App_rd_en,
	output [ADDR_BITS - 1:0]         App_rd_addr,
	input                            Sdr_rd_en,
	input [MEM_DATA_BITS - 1:0]      Sdr_rd_dout,

	input                            read_clk,
	input                            read_req,
	output                           read_req_ack,
	output                           read_finish,
	input [ADDR_BITS - 1:0]          read_addr_0,
	input [ADDR_BITS - 1:0]          read_addr_1,
	input [ADDR_BITS - 1:0]          read_addr_2,
	input [ADDR_BITS - 1:0]          read_addr_3,
	input [1:0]                      read_addr_index,
	input [1:0]                      read_addr_index_old,
	input                            slide_active,
	input [9:0]                      slide_position,
	input [ADDR_BITS - 1:0]          read_len,
	input                            read_en,
	input                            display_valid,
	output [READ_DATA_BITS - 1:0]    read_data,
	output                           read_fault,
	output [3:0]                     read_fifo_underflow_count_per_frame,

	output                           App_wr_en,
	output [ADDR_BITS - 1:0]         App_wr_addr,
	output [MEM_DATA_BITS - 1:0]     App_wr_din,
	output [3:0]                     App_wr_dm,

	input                            write_clk,
	input                            write_req,
	output                           write_req_ack,
	output                           write_finish,
	input [ADDR_BITS - 1:0]          write_addr_0,
	input [ADDR_BITS - 1:0]          write_addr_1,
	input [ADDR_BITS - 1:0]          write_addr_2,
	input [ADDR_BITS - 1:0]          write_addr_3,
	input [1:0]                      write_addr_index,
	input [ADDR_BITS - 1:0]          write_len,
	input                            write_en,
	input [WRITE_DATA_BITS - 1:0]    write_data,
	output                           write_fifo_afull
);

wire [BURST_BITS - 1:0] wrusedw;
wire [BURST_BITS - 1:0] rdusedw;
wire App_rd_busy;
wire App_wr_busy;
wire read_fifo_aclr;
wire write_fifo_aclr;
wire O_wr_busy;
wire O_rd_busy;
wire read_fifo_write_en;
wire [MEM_DATA_BITS - 1:0] read_fifo_write_data;
wire read_fifo_empty;
wire read_fifo_underflow_now;
reg  read_fifo_underflow_prev;
reg  read_req_prev;
reg  [3:0] read_fifo_underflow_count_running;
reg  [3:0] read_fifo_underflow_count_frame_r;

// Gated by display_valid: before the first committed frame (or briefly at
// power-on before Sdr_init_done), video_delay.read_en still pulses every
// active line even though nothing has been written to the FIFO yet, and
// that expected startup emptiness is harmless (the display mux ignores
// read_data and shows black/test-pattern instead). Without this gate the
// count would include this harmless startup gap.
assign read_fifo_underflow_now = display_valid && read_en && read_fifo_empty;

// Per-frame episode counter, snapshotted once per video frame rather than
// accumulated forever: read_en stays high for an entire active video line,
// so a stall that empties the FIFO for several consecutive cycles must
// count as one episode, not one per cycle -- edge-detecting the gated
// condition counts distinct underflow episodes within the CURRENT frame.
// At each frame boundary (read_req's rising edge, already in this read_clk
// domain), the just-finished frame's tally is latched into a stable
// snapshot register and the running counter restarts at 0. A single
// forever-sticky counter can only ever answer "did this happen at least
// once since power-on"; this per-frame version answers the more useful
// question -- does the count keep hitting the same high value EVERY frame
// (a chronic per-frame throughput problem) or only for the first frame or
// two after the image commits (a one-time startup transient)? Both the
// running and the snapshot counters saturate at 4'hF rather than wrapping.
always @(posedge read_clk or posedge rst) begin
	if (rst) begin
		read_fifo_underflow_prev          <= 1'b0;
		read_req_prev                     <= 1'b0;
		read_fifo_underflow_count_running <= 4'd0;
		read_fifo_underflow_count_frame_r <= 4'd0;
	end else begin
		read_fifo_underflow_prev <= read_fifo_underflow_now;
		read_req_prev            <= read_req;

		if (read_req && !read_req_prev) begin
			read_fifo_underflow_count_frame_r <= read_fifo_underflow_count_running;
			read_fifo_underflow_count_running <= 4'd0;
		end else if (read_fifo_underflow_now && !read_fifo_underflow_prev &&
		             (read_fifo_underflow_count_running != 4'hF)) begin
			read_fifo_underflow_count_running <= read_fifo_underflow_count_running + 4'd1;
		end
	end
end

assign read_fifo_underflow_count_per_frame = read_fifo_underflow_count_frame_r;

assign App_wr_busy = O_wr_busy;
assign App_rd_busy = O_rd_busy;
assign App_wr_dm = 4'b0000;

wfifo_32_32_512 #(
	.AL_FULL_NUM (256)
) write_buf (
	.clkr       (mem_clk),
	.clkw       (write_clk),
	.rst        (write_fifo_aclr),
	.we         (write_en),
	.re         (App_wr_en),
	.di         (write_data),
	.empty_flag (),
	.full_flag  (),
	.afull      (write_fifo_afull),
	.wrusedw    (),
	.rdusedw    (rdusedw),
	.dout       (App_wr_din)
);

frame_fifo_write #(
	.MEM_DATA_BITS (MEM_DATA_BITS),
	.ADDR_BITS     (ADDR_BITS),
	.BURST_BITS    (BURST_BITS),
	.BURST_SIZE    (BURST_SIZE),
	.WRITE_V_FLIP  (WRITE_V_FLIP),
	.FRAME_WIDTH   (FRAME_WIDTH),
	.FRAME_HEIGHT  (FRAME_HEIGHT)
) frame_fifo_write_m0 (
	.rst              (rst),
	.mem_clk          (mem_clk),
	.Sdr_init_done    (Sdr_init_done),
	.Sdr_init_ref_vld (Sdr_init_ref_vld),
	.Sdr_busy         (Sdr_busy),
	.App_rd_busy      (App_rd_busy),
	.O_wr_busy        (O_wr_busy),
	.App_wr_en        (App_wr_en),
	.App_wr_addr      (App_wr_addr),
	.write_req        (write_req),
	.write_req_ack    (write_req_ack),
	.write_finish     (write_finish),
	.write_addr_0     (write_addr_0),
	.write_addr_1     (write_addr_1),
	.write_addr_2     (write_addr_2),
	.write_addr_3     (write_addr_3),
	.write_addr_index (write_addr_index),
	.write_len        (write_len),
	.fifo_aclr        (write_fifo_aclr),
	.rdusedw          (rdusedw)
);

rfifo_32_32_512 read_buf (
	.clkr       (read_clk),
	.clkw       (mem_clk),
	.rst        (read_fifo_aclr),
	.we         (read_fifo_write_en),
	.re         (read_en),
	.di         (read_fifo_write_data),
	.empty_flag (read_fifo_empty),
	.full_flag  (),
	.wrusedw    (wrusedw),
	.rdusedw    (),
	.dout       (read_data)
);

frame_slide_fifo_read #(
	.ADDR_BITS       (ADDR_BITS),
	.FRAME_WIDTH     (FRAME_WIDTH),
	.FRAME_HEIGHT    (FRAME_HEIGHT),
	.FIFO_DEPTH      (READ_FIFO_DEPTH),
	.FIFO_LEVEL_BITS (BURST_BITS),
	.MAX_BURST       (READ_BURST_SIZE),
	.FEATHER_WIDTH   (32)
) frame_slide_fifo_read_m0 (
	.mem_clk          (mem_clk),
	.rst              (rst),
	.Sdr_init_done    (Sdr_init_done),
	.Sdr_busy         (Sdr_busy),
	.App_wr_busy      (App_wr_busy),
	.Sdr_rd_en        (Sdr_rd_en),
	.Sdr_rd_dout      (Sdr_rd_dout),
	.read_req         (read_req),
	.read_req_ack     (read_req_ack),
	.read_finish      (read_finish),
	.read_addr_0      (read_addr_0),
	.read_addr_1      (read_addr_1),
	.read_addr_2      (read_addr_2),
	.read_addr_3      (read_addr_3),
	.old_buffer_index (read_addr_index_old),
	.new_buffer_index (read_addr_index),
	.slide_active     (slide_active),
	.slide_position   (slide_position),
	.fifo_aclr        (read_fifo_aclr),
	.wrusedw          (wrusedw),
	.fifo_write_en    (read_fifo_write_en),
	.fifo_write_data  (read_fifo_write_data),
	.App_rd_en        (App_rd_en),
	.App_rd_addr      (App_rd_addr),
	.read_busy        (O_rd_busy),
	.read_fault       (read_fault)
);

endmodule
