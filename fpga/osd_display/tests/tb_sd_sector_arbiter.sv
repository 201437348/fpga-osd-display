`timescale 1ns/1ps

module tb_sd_sector_arbiter;

reg clk = 1'b0;
reg rst = 1'b1;
reg scan_req = 1'b0;
reg [31:0] scan_addr = 32'd11;
reg audio_req = 1'b0;
reg [31:0] audio_addr = 32'd22;
reg image_req = 1'b0;
reg [31:0] image_addr = 32'd33;
wire scan_grant;
wire audio_grant;
wire image_grant;
wire sd_sec_read;
wire [31:0] sd_sec_read_addr;

always #5 clk = ~clk;

sd_sector_arbiter dut (
    .clk(clk),
    .rst(rst),
    .scan_req(scan_req),
    .scan_addr(scan_addr),
    .audio_req(audio_req),
    .audio_addr(audio_addr),
    .image_req(image_req),
    .image_addr(image_addr),
    .scan_grant(scan_grant),
    .audio_grant(audio_grant),
    .image_grant(image_grant),
    .sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr)
);

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
    repeat (2) @(posedge clk);
    rst = 1'b0;

    // A simultaneous idle-boundary request uses scan > audio > image priority.
    @(negedge clk);
    scan_req = 1'b1;
    audio_req = 1'b1;
    image_req = 1'b1;
    @(posedge clk);
    #1;
    expect_bit(scan_grant, 1'b1, "scan wins initial priority");
    expect_bit(sd_sec_read, 1'b1, "granted scan request reaches SD core");
    expect_value(sd_sec_read_addr, 32'd11, "scan address reaches SD core");

    // A higher-priority scan request cannot displace an in-flight audio sector.
    @(negedge clk);
    scan_req = 1'b0;
    @(posedge clk);
    #1;
    expect_bit(scan_grant, 1'b0, "released owner drops its grant");
    expect_bit(sd_sec_read, 1'b0, "handoff gap drives SD request low");
    @(posedge clk);
    #1;
    expect_bit(audio_grant, 1'b1, "audio receives next boundary");
    expect_value(sd_sec_read_addr, 32'd22, "audio address reaches SD core");

    @(negedge clk);
    scan_req = 1'b1;
    @(posedge clk);
    #1;
    expect_bit(audio_grant, 1'b1, "active audio sector is never preempted");
    expect_bit(scan_grant, 1'b0, "waiting scan does not preempt audio");

    @(negedge clk);
    audio_req = 1'b0;
    @(posedge clk);
    #1;
    expect_bit(sd_sec_read, 1'b0, "second handoff gap drives request low");
    @(posedge clk);
    #1;
    expect_bit(scan_grant, 1'b1, "scan priority applies at next boundary");
    expect_value(sd_sec_read_addr, 32'd11, "second scan address reaches SD core");

    @(negedge clk);
    scan_req = 1'b0;
    image_req = 1'b0;
    @(posedge clk);
    @(posedge clk);
    #1;
    expect_bit(scan_grant | audio_grant | image_grant, 1'b0, "arbiter returns idle");
    expect_bit(sd_sec_read, 1'b0, "idle arbiter holds SD request low");

    $display("PASS tb_sd_sector_arbiter");
    $finish;
end

initial begin
    #10000;
    $fatal(1, "FAIL tb_sd_sector_arbiter timed out");
end

endmodule
