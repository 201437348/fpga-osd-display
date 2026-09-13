`timescale 1ns/1ps

module tb_frame_read_fifo_marker;

localparam integer FRAME_WIDTH = 35;
localparam integer FRAME_HEIGHT = 2;
localparam integer MARKER_START = 26;
localparam integer MARKER_WIDTH = 5;
localparam [20:0] FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

reg clk = 1'b0;
reg rst = 1'b1;
wire [31:0] read_data;
wire [3:0] underflow_count;
integer row;
integer x;
reg [31:0] source_word;
reg [31:0] expected_word;

always #4 clk = ~clk;

frame_read_write #(
    .FRAME_WIDTH            (FRAME_WIDTH),
    .FRAME_HEIGHT           (FRAME_HEIGHT),
    .READ_FIFO_MARKER_ENABLE(1),
    .READ_FIFO_MARKER_START (MARKER_START),
    .READ_FIFO_MARKER_WIDTH (MARKER_WIDTH)
) dut (
    .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1),
    .Sdr_init_ref_vld(1'b1), .Sdr_busy(1'b0),
    .App_rd_en(), .App_rd_addr(), .Sdr_rd_en(1'b0),
    .Sdr_rd_dout(32'd0), .read_clk(clk), .read_req(1'b0),
    .read_req_ack(), .read_finish(), .read_addr_0(21'd0),
    .read_addr_1(21'd0), .read_addr_2(21'd0), .read_addr_3(21'd0),
    .read_addr_index(2'd0), .read_addr_index_old(2'd0),
    .slide_active(1'b0), .slide_position(10'd0),
    .read_len(FRAME_PIXELS), .read_en(1'b0), .display_valid(1'b0),
    .read_data(read_data), .read_fault(),
    .read_fifo_underflow_count_per_frame(underflow_count),
    .App_wr_en(), .App_wr_addr(), .App_wr_din(), .App_wr_dm(),
    .write_clk(clk), .write_req(1'b0), .write_req_ack(),
    .write_finish(), .write_addr_0(21'd0), .write_addr_1(21'd0),
    .write_addr_2(21'd0), .write_addr_3(21'd0),
    .write_addr_index(2'd0), .write_len(FRAME_PIXELS),
    .write_en(1'b0), .write_data(32'd0), .write_fifo_afull()
);

task automatic push_and_check;
    input [31:0] word;
    input [31:0] expected;
    begin
        @(negedge clk);
        dut.frame_slide_fifo_read_m0.tb_write_en = 1'b1;
        dut.frame_slide_fifo_read_m0.tb_write_data = word;
        #1;
        if (dut.read_fifo_write_data !== expected)
            $fatal(1, "FAIL row=%0d x=%0d expected %h got %h",
                   row, x, expected, dut.read_fifo_write_data);
        @(negedge clk);
        dut.frame_slide_fifo_read_m0.tb_write_en = 1'b0;
    end
endtask

initial begin
    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    for (row = 0; row < FRAME_HEIGHT; row = row + 1) begin
        for (x = 0; x < FRAME_WIDTH; x = x + 1) begin
            source_word = {8'h40 + row[7:0], x[7:0], 8'hA0 + x[7:0], 8'h00};
            expected_word = ((x >= MARKER_START) &&
                             (x < MARKER_START + MARKER_WIDTH)) ?
                            32'hFFFFFF00 : source_word;
            push_and_check(source_word, expected_word);
        end
    end

    $display("PASS tb_frame_read_fifo_marker");
    $finish;
end

initial begin
    #100000;
    $fatal(1, "FAIL timeout row=%0d x=%0d", row, x);
end

endmodule
