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
	parameter WRITE_BUFFER_SOLID_DIAGNOSTIC = 0,
	parameter FRAME_WIDTH            = 640,
	parameter FRAME_HEIGHT           = 480,
	parameter SLIDE_FEATHER_ENABLE   = 1,
	parameter SLIDE_FIFO_UNIFORM_DIAGNOSTIC = 0,
	parameter SLIDE_SDRAM_UNIFORM_DIAGNOSTIC = 0,
	parameter SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC = 0,
	parameter SLIDE_PHASE_COLOR_DIAGNOSTIC = 0,
	parameter READ_CHUNK_PREROLL_WORDS = 0,
	parameter FIXED_READ_BURST_ENABLE = 0,
	parameter READ_FIFO_MARKER_ENABLE = 0,
	parameter READ_FIFO_MARKER_START  = 0,
	parameter READ_FIFO_MARKER_WIDTH  = 16,
	// Background scrub read every SCRUB_INTERVAL mem_clk cycles (0 = off).
	parameter SCRUB_INTERVAL         = 512,
	parameter SCRUB_READS            = 4,     // reads per scrub, same address (like a chunk preroll)
	parameter SCRUB_GUARD            = 16,    // idle cycles before issuing and after the last return
	// Issue an SDRAM AUTO REFRESH (App_ref_req) in every 2nd scrub window (0 = off).
	parameter REFRESH_ENABLE         = 1
)
(
	input                            rst,
	input                            mem_clk,
	input                            Sdr_init_done,
	input                            Sdr_init_ref_vld,
	input                            Sdr_busy,
	output reg                       App_ref_req,       // 1-cycle refresh request to sdr_as_ram

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
	input [ADDR_BITS - 1:0]          read_addr_4,
	input [ADDR_BITS - 1:0]          read_addr_5,
	input [2:0]                      read_addr_index,       // 槽号 0..5
	input [2:0]                      read_addr_index_old,
	input                            slide_active,
	input [9:0]                      slide_position,
	input [ADDR_BITS - 1:0]          read_len,
	input                            read_en,
	input                            display_valid,
	output [READ_DATA_BITS - 1:0]    read_data,
	output                           read_data_valid,
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
	input [ADDR_BITS - 1:0]          write_addr_4,
	input [ADDR_BITS - 1:0]          write_addr_5,
	input [2:0]                      write_addr_index,
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
wire [MEM_DATA_BITS - 1:0] slide_fifo_write_data;
wire [MEM_DATA_BITS - 1:0] read_fifo_write_data;
wire [WRITE_DATA_BITS - 1:0] write_fifo_data;
reg  [15:0] read_fifo_marker_x;
wire read_fifo_empty;
wire read_fifo_underflow_now;
reg  read_fifo_underflow_prev;
reg  read_req_prev;
reg  [3:0] read_fifo_underflow_count_running;
reg  [3:0] read_fifo_underflow_count_frame_r;

assign read_fifo_write_data =
	(READ_FIFO_MARKER_ENABLE &&
	 (read_fifo_marker_x >= READ_FIFO_MARKER_START) &&
	 (read_fifo_marker_x <
	  READ_FIFO_MARKER_START + READ_FIFO_MARKER_WIDTH)) ?
	32'hFFFFFF00 : slide_fifo_write_data;

assign write_fifo_data = WRITE_BUFFER_SOLID_DIAGNOSTIC ?
	(write_addr_index == 3'd0) ? 32'hE0202000 :
	(write_addr_index == 3'd1) ? 32'h20E04000 :
	(write_addr_index == 3'd2) ? 32'h2040E000 :
	                            32'hE0E02000 : write_data;

always @(posedge mem_clk or posedge rst) begin
	if (rst) begin
		read_fifo_marker_x <= 16'd0;
	end else if (read_fifo_aclr) begin
		read_fifo_marker_x <= 16'd0;
	end else if (read_fifo_write_en) begin
		if (read_fifo_marker_x == FRAME_WIDTH - 1)
			read_fifo_marker_x <= 16'd0;
		else
			read_fifo_marker_x <= read_fifo_marker_x + 16'd1;
	end
end

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

// ---------------------------------------------------------------------------
// Background scrub reads (software refresh).
// The controller's auto refresh is unusable here (enabling it corrupts the
// display), so SDRAM rows are kept alive by ACTIVATE instead: every
// SCRUB_INTERVAL cycles the next {row, bank} (col 0) is read. 8192 bank-rows
// * 512 cycles = 33.5 ms per sweep at 125 MHz, inside the 64 ms retention.
// The controller returns data for an address two commands late, so a lone
// read is not guaranteed to touch its own row and its return may land after
// the schedulers resume. The scrub therefore mimics a chunk preroll:
//   hold both schedulers -> SCRUB_GUARD idle cycles -> SCRUB_READS reads of
//   the same address -> wait for all returns -> SCRUB_GUARD more cycles with
//   Sdr_rd_en still masked from the read scheduler -> release.
//
// Controller auto refresh: global_def.v's SELF_REFRESH_INTERVAL expands to
// 64000000/1000000000/125000000/2**11 = 0 (no parentheses), so sdr_init_ref
// never raises its own refresh request. Instead of fixing the interval (the
// controller would then refresh at arbitrary times, colliding with the write
// scheduler that does not look at Sdr_busy), sdram.v sets
// self_refresh_open = 0 and the refresh is requested here, inside the scrub
// hold window where both schedulers are known idle:
//   ... scrub reads -> guard -> App_ref_req pulse -> wait for
//   Sdr_init_ref_vld (refresh commands on the bus, ~20 cycles) to rise and
//   fall -> SCRUB_GUARD cycles -> release.
// Every 2nd window: ~1100 cycles apart = ~7000 refreshes per 64 ms (spec 4096).
// ---------------------------------------------------------------------------
localparam [2:0] SC_COUNT = 3'd0;
localparam [2:0] SC_HOLD  = 3'd1;
localparam [2:0] SC_ISSUE = 3'd2;
localparam [2:0] SC_WAIT  = 3'd3;
localparam [2:0] SC_GUARD = 3'd4;
localparam [2:0] SC_REF   = 3'd5;
localparam [2:0] SC_RWAIT = 3'd6;
localparam [2:0] SC_RGRD  = 3'd7;

reg  [2:0]             scrub_state;
reg  [15:0]            scrub_timer;
reg  [7:0]             scrub_wait_cnt;
reg  [3:0]             scrub_issue_cnt;
reg  [3:0]             scrub_ret_cnt;
reg  [12:0]            scrub_row_bank;       // {row[10:0], bank[1:0]}
reg                    scrub_hold;           // registered: blocks both schedulers
reg                    scrub_sel;            // scrub owns the read address / return
reg                    ref_seen;             // Sdr_init_ref_vld went high after App_ref_req
wire                   sched_rd_en;
wire [ADDR_BITS - 1:0] sched_rd_addr;
wire                   scrub_idle_now = !O_rd_busy && !O_wr_busy && !App_wr_en && !Sdr_busy;
// Same command-side backpressure rule as the read scheduler.
wire                   scrub_en = (scrub_state == SC_ISSUE) && !Sdr_busy;

always @(posedge mem_clk or posedge rst) begin
	if (rst) begin
		scrub_state     <= SC_COUNT;
		scrub_timer     <= 16'd0;
		scrub_wait_cnt  <= 8'd0;
		scrub_issue_cnt <= 4'd0;
		scrub_ret_cnt   <= 4'd0;
		scrub_row_bank  <= 13'd0;
		scrub_hold      <= 1'b0;
		scrub_sel       <= 1'b0;
		ref_seen        <= 1'b0;
		App_ref_req     <= 1'b0;
	end else begin
		App_ref_req <= 1'b0;
		case (scrub_state)
			SC_COUNT: begin
				if ((SCRUB_INTERVAL != 0) && Sdr_init_done) begin
					if (scrub_timer >= SCRUB_INTERVAL - 1) begin
						scrub_timer    <= 16'd0;
						scrub_wait_cnt <= 8'd0;
						scrub_hold     <= 1'b1;
						scrub_state    <= SC_HOLD;
					end else begin
						scrub_timer <= scrub_timer + 16'd1;
					end
				end
			end
			// scrub_hold has been visible to both schedulers since this state
			// was entered, so once both report idle neither can start. Require
			// SCRUB_GUARD consecutive idle cycles before the first read.
			SC_HOLD: begin
				if (!scrub_idle_now) begin
					scrub_wait_cnt <= 8'd0;
				end else if (scrub_wait_cnt >= SCRUB_GUARD) begin
					scrub_wait_cnt  <= 8'd0;
					scrub_issue_cnt <= 4'd0;
					scrub_ret_cnt   <= 4'd0;
					scrub_sel       <= 1'b1;
					scrub_state     <= SC_ISSUE;
				end else begin
					scrub_wait_cnt <= scrub_wait_cnt + 8'd1;
				end
			end
			SC_ISSUE: begin
				if (Sdr_rd_en)
					scrub_ret_cnt <= scrub_ret_cnt + 4'd1;
				if (scrub_en) begin
					scrub_issue_cnt <= scrub_issue_cnt + 4'd1;
					if (scrub_issue_cnt == SCRUB_READS - 1)
						scrub_state <= SC_WAIT;
				end
			end
			SC_WAIT: begin
				scrub_wait_cnt <= scrub_wait_cnt + 8'd1;
				if (Sdr_rd_en)
					scrub_ret_cnt <= scrub_ret_cnt + 4'd1;
				if ((scrub_ret_cnt + Sdr_rd_en >= SCRUB_READS) || (scrub_wait_cnt == 8'hFF)) begin
					scrub_wait_cnt <= 8'd0;
					scrub_state    <= SC_GUARD;
				end
			end
			// Late or extra returns are still masked here.
			SC_GUARD: begin
				scrub_wait_cnt <= scrub_wait_cnt + 8'd1;
				if (scrub_wait_cnt >= SCRUB_GUARD) begin
					scrub_row_bank <= scrub_row_bank + 13'd1;
					scrub_sel      <= 1'b0;
					scrub_wait_cnt <= 8'd0;
					if ((REFRESH_ENABLE != 0) && scrub_row_bank[0]) begin
						scrub_state <= SC_REF;
					end else begin
						scrub_hold  <= 1'b0;
						scrub_state <= SC_COUNT;
					end
				end
			end
			// Schedulers are still held (scrub_hold) and idle for > SCRUB_GUARD cycles.
			SC_REF: begin
				App_ref_req    <= 1'b1;
				ref_seen       <= 1'b0;
				scrub_wait_cnt <= 8'd0;
				scrub_state    <= SC_RWAIT;
			end
			// Wait for the refresh commands to go on and off the bus. Timeout
			// keeps the display alive if the controller never shows them.
			SC_RWAIT: begin
				scrub_wait_cnt <= scrub_wait_cnt + 8'd1;
				if (Sdr_init_ref_vld)
					ref_seen <= 1'b1;
				if ((ref_seen && !Sdr_init_ref_vld && !Sdr_busy) ||
				    (!ref_seen && !Sdr_init_ref_vld && (scrub_wait_cnt == 8'd63)) ||
				    (scrub_wait_cnt == 8'hFF)) begin
					scrub_wait_cnt <= 8'd0;
					scrub_state    <= SC_RGRD;
				end
			end
			SC_RGRD: begin
				scrub_wait_cnt <= scrub_wait_cnt + 8'd1;
				if (scrub_wait_cnt >= SCRUB_GUARD) begin
					scrub_hold  <= 1'b0;
					scrub_state <= SC_COUNT;
				end
			end
			default: scrub_state <= SC_COUNT;
		endcase
	end
end

assign App_rd_en   = sched_rd_en | scrub_en;
assign App_rd_addr = scrub_sel ? {scrub_row_bank, 8'd0} : sched_rd_addr;

assign App_wr_busy = O_wr_busy | scrub_hold;   // seen by the read scheduler
assign App_rd_busy = O_rd_busy | scrub_hold;   // seen by the write scheduler
assign App_wr_dm = 4'b0000;

wfifo_32_32_512 #(
	.AL_FULL_NUM (256)
) write_buf (
	.clkr       (mem_clk),
	.clkw       (write_clk),
	.rst        (write_fifo_aclr),
	.we         (write_en),
	.re         (App_wr_en),
	.di         (write_fifo_data),
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
	.write_addr_4     (write_addr_4),
	.write_addr_5     (write_addr_5),
	.write_addr_index (write_addr_index),
	.write_len        (write_len),
	.fifo_aclr        (write_fifo_aclr),
	.rdusedw          (rdusedw)
);

rfifo_32_32_512 #(
	.SHOW_AHEAD_EN (1'b0),
	.OUTREG_EN     ("OUTREG")
) read_buf (
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
	.valid      (read_data_valid),
	.dout       (read_data)
);

frame_slide_fifo_read #(
	.ADDR_BITS       (ADDR_BITS),
	.FRAME_WIDTH     (FRAME_WIDTH),
	.FRAME_HEIGHT    (FRAME_HEIGHT),
	.FIFO_DEPTH      (READ_FIFO_DEPTH),
	.FIFO_LEVEL_BITS (BURST_BITS),
	.MAX_BURST       (READ_BURST_SIZE),
	.FEATHER_WIDTH   (32),
	.FEATHER_ENABLE  (SLIDE_FEATHER_ENABLE),
	.SLIDE_FIFO_UNIFORM_DIAGNOSTIC (SLIDE_FIFO_UNIFORM_DIAGNOSTIC),
	.SLIDE_SDRAM_UNIFORM_DIAGNOSTIC (SLIDE_SDRAM_UNIFORM_DIAGNOSTIC),
	.SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC (SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC),
	.SLIDE_PHASE_COLOR_DIAGNOSTIC (SLIDE_PHASE_COLOR_DIAGNOSTIC),
	.READ_CHUNK_PREROLL_WORDS (READ_CHUNK_PREROLL_WORDS),
	.FIXED_READ_BURST_ENABLE (FIXED_READ_BURST_ENABLE)
) frame_slide_fifo_read_m0 (
	.mem_clk          (mem_clk),
	.rst              (rst),
	.Sdr_init_done    (Sdr_init_done),
	.Sdr_busy         (Sdr_busy),
	.App_wr_busy      (App_wr_busy),
	.Sdr_rd_en        (Sdr_rd_en & ~scrub_sel),
	.Sdr_rd_dout      (Sdr_rd_dout),
	.read_req         (read_req),
	.read_req_ack     (read_req_ack),
	.read_finish      (read_finish),
	.read_addr_0      (read_addr_0),
	.read_addr_1      (read_addr_1),
	.read_addr_2      (read_addr_2),
	.read_addr_3      (read_addr_3),
	.read_addr_4      (read_addr_4),
	.read_addr_5      (read_addr_5),
	.old_buffer_index (read_addr_index_old),
	.new_buffer_index (read_addr_index),
	.slide_active     (slide_active),
	.slide_position   (slide_position),
	.fifo_aclr        (read_fifo_aclr),
	.wrusedw          (wrusedw),
	.fifo_write_en    (read_fifo_write_en),
	.fifo_write_data  (slide_fifo_write_data),
	.App_rd_en        (sched_rd_en),
	.App_rd_addr      (sched_rd_addr),
	.read_busy        (O_rd_busy),
	.read_fault       (read_fault)
);

endmodule
