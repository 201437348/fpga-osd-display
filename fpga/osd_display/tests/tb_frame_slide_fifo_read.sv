`timescale 1ns/1ps

module tb_frame_slide_fifo_read;

localparam integer FRAME_WIDTH = 8;
localparam integer FRAME_HEIGHT = 2;
localparam integer FEATHER_WIDTH = 4;

reg mem_clk = 1'b0;
reg rst = 1'b1;
reg Sdr_init_done = 1'b0;
reg Sdr_busy = 1'b0;
reg App_wr_busy = 1'b0;
reg Sdr_rd_en = 1'b0;
reg [31:0] Sdr_rd_dout = 32'd0;
reg read_req = 1'b0;
reg [1:0] old_buffer_index = 2'd0;
reg [1:0] new_buffer_index = 2'd1;
reg slide_active = 1'b1;
reg [9:0] slide_position = 10'd4;
reg [3:0] wrusedw = 4'd0;

wire read_req_ack;
wire read_finish;
wire fifo_aclr;
wire fifo_write_en;
wire [31:0] fifo_write_data;
wire App_rd_en;
wire [9:0] App_rd_addr;
wire read_busy;
wire read_fault;

integer trace_count = 0;
reg [9:0] trace_addr [0:127];
integer output_count = 0;
reg [31:0] output_word [0:63];
integer queue_head = 0;
integer queue_tail = 0;
integer queue_count = 0;
reg [9:0] return_queue [0:255];
integer gap_count = 0;
integer i;

always #4 mem_clk = ~mem_clk;

frame_slide_fifo_read #(
    .ADDR_BITS       (10),
    .FRAME_WIDTH     (FRAME_WIDTH),
    .FRAME_HEIGHT    (FRAME_HEIGHT),
    .FIFO_DEPTH      (16),
    .FIFO_LEVEL_BITS (4),
    .MAX_BURST       (4),
    .FEATHER_WIDTH   (FEATHER_WIDTH)
) dut (
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
    .read_addr_0      (10'd0),
    .read_addr_1      (10'd64),
    .read_addr_2      (10'd128),
    .read_addr_3      (10'd192),
    .old_buffer_index (old_buffer_index),
    .new_buffer_index (new_buffer_index),
    .slide_active     (slide_active),
    .slide_position   (slide_position),
    .fifo_aclr        (fifo_aclr),
    .wrusedw          (wrusedw),
    .fifo_write_en    (fifo_write_en),
    .fifo_write_data  (fifo_write_data),
    .App_rd_en        (App_rd_en),
    .App_rd_addr      (App_rd_addr),
    .read_busy        (read_busy),
    .read_fault       (read_fault)
);

function [31:0] memory_word;
    input [9:0] address;
    reg [7:0] offset;
    begin
        if (address >= 10'd64) begin
            offset = address - 10'd64;
            memory_word = {8'd100 + offset, 8'd50 + offset,
                           8'd200 - offset, 8'd0};
        end else begin
            offset = address;
            memory_word = {8'd10 + offset, 8'd20 + offset,
                           8'd30 + offset, 8'd0};
        end
    end
endfunction

function [7:0] mix_channel;
    input [7:0] source;
    input [7:0] target;
    input [6:0] alpha;
    integer delta;
    begin
        if (target >= source) begin
            delta = (target - source) * alpha;
            mix_channel = source + (delta >> 6);
        end else begin
            delta = (source - target) * alpha;
            mix_channel = source - (delta >> 6);
        end
    end
endfunction

function [31:0] mixed_word;
    input [31:0] source;
    input [31:0] target;
    input [6:0] alpha;
    begin
        mixed_word = {
            mix_channel(source[31:24], target[31:24], alpha),
            mix_channel(source[23:16], target[23:16], alpha),
            mix_channel(source[15:8], target[15:8], alpha),
            8'd0
        };
    end
endfunction

// Queue every accepted address and return words in order with deterministic
// gaps. This prevents the DUT from relying on a fixed SDRAM latency.
always @(negedge mem_clk) begin
    Sdr_rd_en = 1'b0;
    gap_count = gap_count + 1;

    if (App_rd_en) begin
        trace_addr[trace_count] = App_rd_addr;
        trace_count = trace_count + 1;
        return_queue[queue_tail] = App_rd_addr;
        queue_tail = (queue_tail + 1) & 255;
        queue_count = queue_count + 1;
    end

    if ((queue_count > 0) && ((gap_count % 3) != 0)) begin
        Sdr_rd_en = 1'b1;
        Sdr_rd_dout = memory_word(return_queue[queue_head]);
        queue_head = (queue_head + 1) & 255;
        queue_count = queue_count - 1;
    end
end

always @(negedge mem_clk) begin
    if (fifo_write_en) begin
        output_word[output_count] = fifo_write_data;
        output_count = output_count + 1;
    end
end

task automatic clear_observations;
    begin
        trace_count = 0;
        output_count = 0;
    end
endtask

task automatic start_read;
    begin
        @(negedge mem_clk);
        read_req = 1'b1;
        wait (read_req_ack === 1'b1);
        @(negedge mem_clk);
        read_req = 1'b0;
        wait (read_finish === 1'b1);
        @(negedge mem_clk);
    end
endtask

task automatic expect_integer;
    input integer actual;
    input integer expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic expect_word;
    input [31:0] actual;
    input [31:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %h, got %h", checkpoint, expected, actual);
    end
endtask

initial begin
    repeat (4) @(posedge mem_clk);
    Sdr_init_done = 1'b1;
    rst = 1'b0;

    clear_observations;
    slide_active = 1'b1;
    slide_position = 10'd4;
    start_read;
    expect_integer(trace_count, 24, "feathered frame read count");
    for (i = 0; i < 6; i = i + 1)
        expect_integer(trace_addr[i], i + 2, "row zero old address sequence");
    for (i = 0; i < 6; i = i + 1)
        expect_integer(trace_addr[i + 6], i + 64, "row zero new address sequence");
    expect_integer(output_count, 16, "feathered frame output count");
    expect_word(output_word[0], memory_word(10'd2), "old direct pixel zero");
    expect_word(output_word[1], memory_word(10'd3), "old direct pixel one");
    expect_word(output_word[2], mixed_word(memory_word(10'd4), memory_word(10'd64), 7'd0),
                "overlap alpha zero");
    expect_word(output_word[3], mixed_word(memory_word(10'd5), memory_word(10'd65), 7'd21),
                "overlap alpha one third");
    expect_word(output_word[4], mixed_word(memory_word(10'd6), memory_word(10'd66), 7'd43),
                "overlap alpha two thirds");
    expect_word(output_word[5], mixed_word(memory_word(10'd7), memory_word(10'd67), 7'd64),
                "overlap alpha full");
    expect_word(output_word[6], memory_word(10'd68), "new direct pixel zero");
    expect_word(output_word[7], memory_word(10'd69), "new direct pixel one");

    clear_observations;
    slide_position = 10'd0;
    start_read;
    expect_integer(trace_count, 16, "old endpoint read count");
    expect_integer(output_count, 16, "old endpoint output count");
    for (i = 0; i < 16; i = i + 1) begin
        expect_integer(trace_addr[i], i, "old endpoint address");
        expect_word(output_word[i], memory_word(i), "old endpoint output");
    end

    clear_observations;
    slide_position = 10'd8;
    start_read;
    expect_integer(trace_count, 16, "new endpoint read count");
    expect_integer(output_count, 16, "new endpoint output count");
    for (i = 0; i < 16; i = i + 1) begin
        expect_integer(trace_addr[i], i + 64, "new endpoint address");
        expect_word(output_word[i], memory_word(i + 64), "new endpoint output");
    end

    clear_observations;
    slide_active = 1'b0;
    slide_position = 10'd4;
    start_read;
    expect_integer(trace_count, 16, "steady frame read count");
    expect_integer(output_count, 16, "steady frame output count");
    for (i = 0; i < 16; i = i + 1) begin
        expect_integer(trace_addr[i], i + 64, "steady mode ignores stale old metadata");
        expect_word(output_word[i], memory_word(i + 64), "steady current-frame output");
    end
    if (read_fault !== 1'b0)
        $fatal(1, "FAIL normal frame requests latched read_fault");

    // A new frame request while returns are outstanding must latch a fault.
    slide_active = 1'b1;
    slide_position = 10'd4;
    @(negedge mem_clk);
    read_req = 1'b1;
    wait (read_req_ack === 1'b1);
    @(negedge mem_clk);
    read_req = 1'b0;
    wait (App_rd_en === 1'b1);
    @(negedge mem_clk);
    read_req = 1'b1;
    repeat (5) @(negedge mem_clk);
    if (read_fault !== 1'b1)
        $fatal(1, "FAIL incomplete frame request did not latch read_fault");

    $display("PASS tb_frame_slide_fifo_read");
    $finish;
end

endmodule
