`timescale 1ns/1ps

module tb_frame_write_solid_diagnostic;

reg clk = 1'b0;
reg rst = 1'b1;
reg [1:0] write_addr_index = 2'd0;
reg [31:0] write_data = 32'h12345600;

always #4 clk = ~clk;

frame_read_write #(
    .WRITE_BUFFER_SOLID_DIAGNOSTIC (1)
) dut (
    .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1),
    .Sdr_init_ref_vld(1'b1), .Sdr_busy(1'b0),
    .App_rd_en(), .App_rd_addr(), .Sdr_rd_en(1'b0),
    .Sdr_rd_dout(32'd0), .read_clk(clk), .read_req(1'b0),
    .read_req_ack(), .read_finish(), .read_addr_0(21'd0),
    .read_addr_1(21'd0), .read_addr_2(21'd0), .read_addr_3(21'd0),
    .read_addr_index(2'd0), .read_addr_index_old(2'd0),
    .slide_active(1'b0), .slide_position(10'd0),
    .read_len(21'd0), .read_en(1'b0), .display_valid(1'b0),
    .read_data(), .read_fault(), .read_fifo_underflow_count_per_frame(),
    .App_wr_en(), .App_wr_addr(), .App_wr_din(), .App_wr_dm(),
    .write_clk(clk), .write_req(1'b0), .write_req_ack(), .write_finish(),
    .write_addr_0(21'd0), .write_addr_1(21'd0),
    .write_addr_2(21'd0), .write_addr_3(21'd0),
    .write_addr_index(write_addr_index), .write_len(21'd0),
    .write_en(1'b0), .write_data(write_data), .write_fifo_afull()
);

frame_read_write dut_passthrough (
    .rst(rst), .mem_clk(clk), .Sdr_init_done(1'b1),
    .Sdr_init_ref_vld(1'b1), .Sdr_busy(1'b0),
    .App_rd_en(), .App_rd_addr(), .Sdr_rd_en(1'b0),
    .Sdr_rd_dout(32'd0), .read_clk(clk), .read_req(1'b0),
    .read_req_ack(), .read_finish(), .read_addr_0(21'd0),
    .read_addr_1(21'd0), .read_addr_2(21'd0), .read_addr_3(21'd0),
    .read_addr_index(2'd0), .read_addr_index_old(2'd0),
    .slide_active(1'b0), .slide_position(10'd0),
    .read_len(21'd0), .read_en(1'b0), .display_valid(1'b0),
    .read_data(), .read_fault(), .read_fifo_underflow_count_per_frame(),
    .App_wr_en(), .App_wr_addr(), .App_wr_din(), .App_wr_dm(),
    .write_clk(clk), .write_req(1'b0), .write_req_ack(), .write_finish(),
    .write_addr_0(21'd0), .write_addr_1(21'd0),
    .write_addr_2(21'd0), .write_addr_3(21'd0),
    .write_addr_index(write_addr_index), .write_len(21'd0),
    .write_en(1'b0), .write_data(write_data), .write_fifo_afull()
);

task automatic expect_fifo_input;
    input [1:0] index;
    input [31:0] expected;
    begin
        write_addr_index = index;
        #1;
        if (dut.write_fifo_data !== expected)
            $fatal(1, "FAIL index %0d expected %h got %h",
                   index, expected, dut.write_fifo_data);
    end
endtask

initial begin
    expect_fifo_input(2'd0, 32'hE0202000);
    expect_fifo_input(2'd1, 32'h20E04000);
    expect_fifo_input(2'd2, 32'h2040E000);
    expect_fifo_input(2'd3, 32'hE0E02000);
    if (dut_passthrough.write_fifo_data !== write_data)
        $fatal(1, "FAIL default mode expected passthrough %h got %h",
               write_data, dut_passthrough.write_fifo_data);
    $display("PASS tb_frame_write_solid_diagnostic");
    $finish;
end

endmodule
