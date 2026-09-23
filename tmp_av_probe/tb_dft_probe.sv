`timescale 1ns/1ps
// Probe: drive the current audio_spectrum_dft with realistic amplitudes and
// print the resulting 8-bin spectrum.  Used only to characterize the defect.
module tb_dft_probe;
  reg clk = 0, rst = 1, valid = 0;
  reg signed [23:0] left = 0, right = 0;
  wire done;
  wire [63:0] spectrum;
  integer i, frame;
  real amp_frac;
  integer amp;

  always #5 clk = ~clk;

  audio_spectrum_dft #(.N(32), .BINS(8), .SAMPLE_W(16)) dut (
    .clk(clk), .rst(rst), .sample_valid(valid),
    .sample_left(left), .sample_right(right),
    .spectrum_valid(done), .spectrum(spectrum));

  // 1 kHz-ish tone at 48 kHz: period 48 samples -> integer cycle in 48 samples
  task automatic run_frame(input integer a);
    integer k;
    reg signed [15:0] s;
    begin
      for (k = 0; k < 32; k = k + 1) begin
        // 4-sample period tone (12 kHz) keeps the math simple
        s = ((k % 4) < 2) ? a[15:0] : -a[15:0];
        @(negedge clk);
        left  = {s, 8'd0};
        right = {s, 8'd0};
        valid = 1'b1;
        @(negedge clk);
        valid = 1'b0;
      end
      wait (done);
      @(negedge clk);
    end
  endtask

  initial begin
    repeat (4) @(posedge clk);
    rst = 0;
    repeat (4) @(posedge clk);
    // amplitude sweep: 16384 (50% FS) down to 8 LSB (0.02% FS)
    for (frame = 0; frame < 8; frame = frame + 1) begin
      amp = 16384 >> frame;
      run_frame(amp);
      $display("amp=%0d (%0.4f%% FS) spectrum=%h bins=[%0d %0d %0d %0d %0d %0d %0d %0d]",
               amp, (amp * 100.0) / 32768.0,
               spectrum,
               spectrum[7:0], spectrum[15:8], spectrum[23:16], spectrum[31:24],
               spectrum[39:32], spectrum[47:40], spectrum[55:48], spectrum[63:56]);
    end
    $finish;
  end

  initial begin
    amp_frac = 0.0;
  end
endmodule
