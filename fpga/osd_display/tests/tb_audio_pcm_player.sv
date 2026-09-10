`timescale 1ns/1ps

module tb_audio_pcm_player;

reg clk = 1'b0;
reg rst = 1'b1;
reg enable = 1'b1;
reg [31:0] fifo_mem [0:3];
reg [2:0] fifo_count = 3'd4;
reg [2:0] fifo_read_index = 3'd0;
wire fifo_empty = (fifo_count == 3'd0);
wire fifo_valid = !fifo_empty;
wire [9:0] fifo_rdusedw = {7'd0, fifo_count};
wire [31:0] fifo_dout = fifo_mem[fifo_read_index];
wire fifo_re;
wire audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;

integer sample_count = 0;
integer read_count = 0;
reg [47:0] captured_sample [0:95];

always #5 clk = ~clk;

audio_pcm_player #(
    .CLK_FREQ_HZ(100),
    .SAMPLE_RATE_HZ(8),
    .PREFILL_FRAMES(10'd2)
) dut (
    .clk(clk),
    .rst(rst),
    .enable(enable),
    .fifo_empty(fifo_empty),
    .fifo_valid(fifo_valid),
    .fifo_rdusedw(fifo_rdusedw),
    .fifo_dout(fifo_dout),
    .fifo_re(fifo_re),
    .audio_valid(audio_valid),
    .audio_left_data(audio_left_data),
    .audio_right_data(audio_right_data)
);

// Show-ahead FIFO model: playback samples the current word while its read
// pulse advances the memory address on the following clock edge.
always @(posedge clk) begin
    if (!rst && fifo_re && !fifo_empty) begin
        fifo_count <= fifo_count - 3'd1;
        fifo_read_index <= fifo_read_index + 3'd1;
        read_count = read_count + 1;
    end
end

always @(posedge clk) begin
    #1;
    if (audio_valid) begin
        captured_sample[sample_count] = {audio_left_data, audio_right_data};
        sample_count = sample_count + 1;
    end
end

task automatic expect_value;
    input integer actual;
    input integer expected;
    input [255:0] checkpoint;
    begin
        if (actual != expected)
            $fatal(1, "FAIL %0s: expected %0d, got %0d", checkpoint, expected, actual);
    end
endtask

task automatic expect_sample;
    input integer index;
    input [23:0] left_value;
    input [23:0] right_value;
    input [255:0] checkpoint;
    begin
        if (captured_sample[index] !== {left_value, right_value})
            $fatal(1, "FAIL %0s: expected %h, got %h", checkpoint,
                   {left_value, right_value}, captured_sample[index]);
    end
endtask

integer index;
initial begin
    fifo_mem[0] = {16'h0001, 16'h8001};
    fifo_mem[1] = {16'h7FFF, 16'hFFFF};
    fifo_mem[2] = {16'h1234, 16'h5678};
    fifo_mem[3] = {16'h8000, 16'h0000};
    for (index = 0; index < 96; index = index + 1)
        captured_sample[index] = 48'd0;

    repeat (2) @(posedge clk);
    rst = 1'b0;

    // 1000 input clocks at 100 Hz contain exactly 80 sample-enable pulses.
    repeat (1000) @(posedge clk);
    #2;
    expect_value(sample_count, 80, "fractional accumulator sample cadence");
    expect_value(read_count, 4, "four queued frames are consumed once");
    expect_sample(0, 24'd0, 24'd0, "prefill sample is silent");
    expect_sample(1, 24'h000100, 24'h800100, "first FIFO frame left alignment");
    expect_sample(2, 24'h7FFF00, 24'hFFFF00, "second FIFO frame left alignment");
    expect_sample(3, 24'h123400, 24'h567800, "third FIFO frame order");
    expect_sample(4, 24'h800000, 24'h000000, "fourth FIFO frame left alignment");
    expect_sample(5, 24'd0, 24'd0, "underflow becomes silence");
    expect_sample(79, 24'd0, 24'd0, "audio valid continues during silence");

    $display("PASS tb_audio_pcm_player");
    $finish;
end

initial begin
    #200000;
    $fatal(1, "FAIL tb_audio_pcm_player timed out");
end

endmodule
