`timescale 1ns/1ps

// Focused test for frame_read_write's per-frame read_fifo_underflow_count_
// per_frame diagnostic. Replaces the vendor-generated FIFOs and the
// write/read schedulers with minimal behavioral stand-ins (this compilation
// unit only) so the counter logic can be exercised without the proprietary
// IP sources, which are not checked into this repository.

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
    assign wrusedw    = 9'd0;
    assign rdusedw    = 9'd0;
    assign dout       = 32'd0;
endmodule

module rfifo_32_32_512 #(
    parameter SHOW_AHEAD_EN = 1'b0,
    parameter OUTREG_EN = "NOREG"
) (
    input         clkr,
    input         clkw,
    input         rst,
    input         we,
    input         re,
    input  [31:0] di,
    output        empty_flag,
    output        full_flag,
    output [8:0]  wrusedw,
    output [8:0]  rdusedw,
    output        valid,
    output [31:0] dout
);
    localparam DEPTH = 512;

    reg [31:0] mem [0:DEPTH-1];
    reg [9:0]  count;
    reg [8:0]  wptr;
    reg [8:0]  rptr;
    reg [31:0] dout_r;

    // This stand-in's rst input is driven by the scheduler stub's fifo_aclr,
    // which stays low for this focused test (only frame_read_write's new
    // sticky logic is under test). Initialize state directly instead of
    // relying on a reset pulse that never arrives here.
    initial begin
        count  = 10'd0;
        wptr   = 9'd0;
        rptr   = 9'd0;
        dout_r = 32'd0;
    end

    assign empty_flag = (count == 10'd0);
    assign full_flag  = (count == DEPTH);
    assign wrusedw    = count[8:0];
    assign rdusedw    = count[8:0];
    assign valid      = 1'b0;
    assign dout       = dout_r;

    always @(posedge clkw or posedge rst) begin
        if (rst) begin
            wptr <= 9'd0;
        end else if (we && !full_flag) begin
            mem[wptr] <= di;
            wptr <= wptr + 9'd1;
        end
    end

    always @(posedge clkr or posedge rst) begin
        if (rst) begin
            rptr   <= 9'd0;
            dout_r <= 32'd0;
        end else if (re && !empty_flag) begin
            dout_r <= mem[rptr];
            rptr   <= rptr + 9'd1;
        end
    end

    always @(posedge clkw or posedge rst) begin
        if (rst)
            count <= 10'd0;
        else if ((we && !full_flag) && !(re && !empty_flag))
            count <= count + 10'd1;
        else if (!(we && !full_flag) && (re && !empty_flag))
            count <= count - 10'd1;
    end
endmodule

module frame_fifo_write #(
    parameter MEM_DATA_BITS = 32,
    parameter ADDR_BITS     = 21,
    parameter BURST_BITS    = 9,
    parameter BURST_SIZE    = 256,
    parameter WRITE_V_FLIP  = 1,
    parameter FRAME_WIDTH   = 640,
    parameter FRAME_HEIGHT  = 480
) (
    input                        rst,
    input                        mem_clk,
    input                        Sdr_init_done,
    input                        Sdr_init_ref_vld,
    input                        Sdr_busy,
    input                        App_rd_busy,
    output                       O_wr_busy,
    output                       App_wr_en,
    output [ADDR_BITS - 1:0]     App_wr_addr,
    input                        write_req,
    output                       write_req_ack,
    output                       write_finish,
    input  [ADDR_BITS - 1:0]     write_addr_0,
    input  [ADDR_BITS - 1:0]     write_addr_1,
    input  [ADDR_BITS - 1:0]     write_addr_2,
    input  [ADDR_BITS - 1:0]     write_addr_3,
    input  [1:0]                 write_addr_index,
    input  [ADDR_BITS - 1:0]     write_len,
    output                       fifo_aclr,
    input  [BURST_BITS - 1:0]    rdusedw
);
    assign O_wr_busy     = 1'b0;
    assign App_wr_en     = 1'b0;
    assign App_wr_addr   = {ADDR_BITS{1'b0}};
    assign write_req_ack = 1'b0;
    assign write_finish  = 1'b0;
    assign fifo_aclr     = 1'b0;
endmodule

module frame_slide_fifo_read #(
    parameter ADDR_BITS       = 21,
    parameter FRAME_WIDTH     = 640,
    parameter FRAME_HEIGHT    = 480,
    parameter FIFO_DEPTH      = 512,
    parameter FIFO_LEVEL_BITS = 9,
    parameter MAX_BURST       = 128,
    parameter FEATHER_WIDTH   = 32,
    parameter FEATHER_ENABLE  = 1,
    parameter SLIDE_FIFO_UNIFORM_DIAGNOSTIC = 0,
    parameter SLIDE_SDRAM_UNIFORM_DIAGNOSTIC = 0,
    parameter SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC = 0,
    parameter SLIDE_PHASE_COLOR_DIAGNOSTIC = 0,
    parameter READ_CHUNK_PREROLL_WORDS = 0,
    parameter FIXED_READ_BURST_ENABLE = 0
) (
    input                             mem_clk,
    input                             rst,
    input                             Sdr_init_done,
    input                             Sdr_busy,
    input                             App_wr_busy,
    input                             Sdr_rd_en,
    input  [31:0]                     Sdr_rd_dout,
    input                             read_req,
    output                            read_req_ack,
    output                            read_finish,
    input  [ADDR_BITS - 1:0]          read_addr_0,
    input  [ADDR_BITS - 1:0]          read_addr_1,
    input  [ADDR_BITS - 1:0]          read_addr_2,
    input  [ADDR_BITS - 1:0]          read_addr_3,
    input  [1:0]                      old_buffer_index,
    input  [1:0]                      new_buffer_index,
    input                             slide_active,
    input  [9:0]                      slide_position,
    output                            fifo_aclr,
    input  [FIFO_LEVEL_BITS - 1:0]    wrusedw,
    output                            fifo_write_en,
    output [31:0]                     fifo_write_data,
    output                            App_rd_en,
    output [ADDR_BITS - 1:0]          App_rd_addr,
    output                            read_busy,
    output                            read_fault
);
    // Testbench drives these directly via a hierarchical reference
    // (dut.frame_slide_fifo_read_m0.tb_write_en / tb_write_data) to load
    // known words into the read FIFO, standing in for the real scheduler.
    reg        tb_write_en   = 1'b0;
    reg [31:0] tb_write_data = 32'd0;

    assign fifo_aclr       = 1'b0;
    assign fifo_write_en   = tb_write_en;
    assign fifo_write_data = tb_write_data;
    assign App_rd_en       = 1'b0;
    assign App_rd_addr     = {ADDR_BITS{1'b0}};
    assign read_busy       = 1'b0;
    assign read_fault      = 1'b0;
    assign read_req_ack    = 1'b0;
    assign read_finish     = 1'b0;
endmodule

module tb_frame_read_write_underflow;

localparam ADDR_BITS = 21;

reg clk = 1'b0;
reg rst = 1'b1;
reg read_en = 1'b0;
reg display_valid = 1'b0;
reg read_req = 1'b0;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [31:0] App_wr_din;
wire [3:0] App_wr_dm;
wire read_req_ack;
wire read_finish;
wire [31:0] read_data;
wire read_fault;
wire [3:0] read_fifo_underflow_count_per_frame;
wire write_req_ack;
wire write_finish;
wire write_fifo_afull;

always #4 clk = ~clk;

frame_read_write #(
    .WRITE_V_FLIP (1),
    .FRAME_WIDTH  (640),
    .FRAME_HEIGHT (480)
) dut (
    .rst                      (rst),
    .mem_clk                  (clk),
    .Sdr_init_done            (1'b1),
    .Sdr_init_ref_vld         (1'b1),
    .Sdr_busy                 (1'b0),
    .App_rd_en                (App_rd_en),
    .App_rd_addr              (App_rd_addr),
    .Sdr_rd_en                (1'b0),
    .Sdr_rd_dout              (32'd0),
    .read_clk                 (clk),
    .read_req                 (read_req),
    .read_req_ack             (read_req_ack),
    .read_finish              (read_finish),
    .read_addr_0              (21'd0),
    .read_addr_1              (21'd307200),
    .read_addr_2              (21'd0),
    .read_addr_3              (21'd0),
    .read_addr_index          (2'd0),
    .read_addr_index_old      (2'd0),
    .slide_active             (1'b0),
    .slide_position           (10'd0),
    .read_len                 (21'd307200),
    .read_en                  (read_en),
    .display_valid            (display_valid),
    .read_data                (read_data),
    .read_fault               (read_fault),
    .read_fifo_underflow_count_per_frame (read_fifo_underflow_count_per_frame),
    .App_wr_en                (App_wr_en),
    .App_wr_addr              (App_wr_addr),
    .App_wr_din               (App_wr_din),
    .App_wr_dm                (App_wr_dm),
    .write_clk                (clk),
    .write_req                (1'b0),
    .write_req_ack            (write_req_ack),
    .write_finish             (write_finish),
    .write_addr_0             (21'd0),
    .write_addr_1             (21'd307200),
    .write_addr_2             (21'd0),
    .write_addr_3             (21'd0),
    .write_addr_index         (2'd0),
    .write_len                (21'd307200),
    .write_en                 (1'b0),
    .write_data               (32'd0),
    .write_fifo_afull         (write_fifo_afull)
);

integer i;

task push_word(input [31:0] word);
    begin
        @(negedge clk);
        dut.frame_slide_fifo_read_m0.tb_write_en   = 1'b1;
        dut.frame_slide_fifo_read_m0.tb_write_data = word;
        @(negedge clk);
        dut.frame_slide_fifo_read_m0.tb_write_en   = 1'b0;
    end
endtask

task pulse_read;
    begin
        @(negedge clk);
        read_en = 1'b1;
        @(negedge clk);
        read_en = 1'b0;
    end
endtask

// Holds read_en high across several consecutive cycles, modeling a real
// active video line (video_delay.read_en stays high for the whole line, not
// a single-cycle pulse). A stall that keeps the FIFO empty across this
// whole span must still count as exactly one underflow episode.
task hold_read(input integer cycles);
    integer j;
    begin
        @(negedge clk);
        read_en = 1'b1;
        for (j = 0; j < cycles; j = j + 1)
            @(negedge clk);
        read_en = 1'b0;
    end
endtask

// A frame boundary is a rising edge of read_req in the read_clk domain
// (matching video_timing_data's once-per-frame behavior on the real vsync
// edge). frame_read_write's counter logic only needs the edge itself, not
// a full ack handshake, so a short pulse is enough for this focused test.
task frame_boundary;
    begin
        @(negedge clk);
        read_req = 1'b1;
        @(negedge clk);
        read_req = 1'b0;
        @(negedge clk);
    end
endtask

initial begin
    rst = 1'b1;
    read_en = 1'b0;
    display_valid = 1'b0;
    read_req = 1'b0;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    // Pre-first-frame gating: video_delay.read_en pulses every active line
    // regardless of whether Sdr_init_done/the scheduler has ever written
    // anything, and that startup emptiness is harmless because display_valid
    // is low (the display mux shows black/test-pattern, not read_data).
    // These empty reads must NOT increment the running counter, and the
    // displayed per-frame value must stay 0.
    repeat (4) begin
        pulse_read;
    end
    if (read_fifo_underflow_count_per_frame !== 4'd0)
        $fatal(1, "FAIL pre-first-frame empty reads affected displayed count");

    // First frame boundary: latches the (empty, pre-commit) frame's tally
    // (0) and starts the running counter fresh for the new frame.
    frame_boundary;
    if (read_fifo_underflow_count_per_frame !== 4'd0)
        $fatal(1, "FAIL first frame boundary produced a nonzero displayed count");

    // Normal rhythm: always write before reading. The running counter must
    // never increment when the FIFO genuinely has data queued.
    display_valid = 1'b1;
    for (i = 0; i < 8; i = i + 1) begin
        push_word(32'hA5A5_0000 + i);
    end
    for (i = 0; i < 8; i = i + 1) begin
        pulse_read;
    end
    if (read_fifo_underflow_count_per_frame !== 4'd0)
        $fatal(1, "FAIL normal write-before-read affected displayed count");

    // Two isolated underflow episodes, plus one held multi-cycle episode
    // (counting once, not once per cycle), all within the CURRENT frame.
    // None of this should move the DISPLAYED value yet -- it only updates
    // at the next frame boundary, so mid-frame activity does not make the
    // digit flicker.
    pulse_read;
    pulse_read;
    hold_read(20);
    if (read_fifo_underflow_count_per_frame !== 4'd0)
        $fatal(1, "FAIL mid-frame underflow episodes changed displayed count early");

    // Next frame boundary: the just-finished frame had exactly 3 episodes
    // (2 isolated + 1 held), so the displayed value should now show 3, and
    // the running counter should restart at 0 for the new frame.
    frame_boundary;
    if (read_fifo_underflow_count_per_frame !== 4'd3)
        $fatal(1, "FAIL displayed count did not show completed frame's tally of 3");

    // Saturation within a single frame: enough distinct episodes to reach
    // 4'hF and confirm the running counter stops there instead of
    // wrapping. Still must not affect the displayed (previous-frame) value
    // until the next boundary.
    for (i = 0; i < 20; i = i + 1) begin
        pulse_read;
    end
    if (read_fifo_underflow_count_per_frame !== 4'd3)
        $fatal(1, "FAIL displayed count changed before the frame boundary");

    frame_boundary;
    if (read_fifo_underflow_count_per_frame !== 4'hF)
        $fatal(1, "FAIL displayed count did not show the saturated frame's tally");

    // A completely clean frame (no underflow at all) must bring the
    // displayed value back down to 0 -- proving this is a per-frame
    // snapshot, not a forever-sticky latch.
    for (i = 0; i < 8; i = i + 1) begin
        push_word(32'hBEEF_0000 + i);
        pulse_read;
    end
    frame_boundary;
    if (read_fifo_underflow_count_per_frame !== 4'd0)
        $fatal(1, "FAIL displayed count did not return to 0 after a clean frame");

    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    if (read_fifo_underflow_count_per_frame !== 4'd0)
        $fatal(1, "FAIL underflow counter did not clear on reset");

    $display("PASS tb_frame_read_write_underflow");
    $finish;
end

endmodule
