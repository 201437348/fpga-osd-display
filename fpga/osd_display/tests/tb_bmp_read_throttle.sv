`timescale 1ns/1ps

module tb_bmp_read_throttle;

reg clk = 1'b0;
reg rst = 1'b1;
reg sd_init_done = 1'b0;
reg sd_sec_read_end = 1'b0;
reg write_fifo_afull = 1'b0;

wire ready;
wire [3:0] state_code;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;

always #5 clk = ~clk;

bmp_read dut (
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (ready),
    .scan_start             (1'b0),
    .scan_start_sector      (32'd0),
    .scan_max_sector        (32'd0),
    .scan_target_count      (3'd0),
    .scan_done              (),
    .scan_found_valid       (),
    .scan_found_sector      (),
    .scan_found_total       (),
    .load_start             (1'b0),
    .load_abort             (1'b0),
    .load_sector            (32'd0),
    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (16'd640),
    .bmp_height             (16'd480),
    .write_req              (),
    .write_req_ack          (1'b0),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (8'd0),
    .sd_sec_read_data_valid (1'b0),
    .sd_sec_read_end        (sd_sec_read_end),
    .write_fifo_afull       (write_fifo_afull),
    .bmp_data_wr_en         (),
    .bmp_data               ()
);

task automatic tick;
    begin
        @(posedge clk);
        #1;
    end
endtask

task automatic expect_bit;
    input actual;
    input expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0b, got %0b", checkpoint, expected, actual);
    end
endtask

task automatic expect_value;
    input [31:0] actual;
    input [31:0] expected;
    input [255:0] checkpoint;
    begin
        if (actual !== expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

initial begin
    tick();
    rst = 1'b0;
    sd_init_done = 1'b1;

    // Start at a non-final sector boundary with two pending pixel bytes.
    @(negedge clk);
    dut.state            = 3'd4;
    dut.sd_sec_read      = 1'b1;
    dut.sd_sec_read_addr = 32'd900;
    dut.bmp_len_cnt      = 32'd512;
    dut.bmp_byte_idx     = 2'd2;
    dut.file_len         = 32'd307200;
    write_fifo_afull     = 1'b1;
    sd_sec_read_end      = 1'b1;

    tick();
    expect_value(dut.state, 32'd5, "full boundary enters pause");
    expect_bit(sd_sec_read, 1'b0, "pause stops the next sector request");
    expect_value(sd_sec_read_addr, 32'd900, "pause does not advance sector address");
    expect_value(dut.bmp_len_cnt, 32'd512, "pause preserves byte count");
    expect_value({30'd0, dut.bmp_byte_idx}, 32'd2, "pause preserves RGB byte alignment");

    sd_sec_read_end = 1'b0;
    tick();
    expect_value(dut.state, 32'd5, "high-water pause holds state");
    expect_bit(sd_sec_read, 1'b0, "high-water pause has no read request");
    expect_value(sd_sec_read_addr, 32'd900, "high-water pause holds address");

    write_fifo_afull = 1'b0;
    tick();
    expect_value(dut.state, 32'd4, "cleared high-water resumes load state");
    expect_value(sd_sec_read_addr, 32'd901, "resume advances exactly one sector");
    expect_bit(sd_sec_read, 1'b0, "resume waits one cycle before issuing read");

    tick();
    expect_bit(sd_sec_read, 1'b1, "resumed load starts the next sector");
    expect_value(state_code, 32'd4, "pause keeps the existing load diagnostic code");

    $display("PASS tb_bmp_read_throttle");
    $finish;
end

endmodule
