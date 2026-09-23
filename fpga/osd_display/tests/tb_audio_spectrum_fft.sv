`timescale 1ns/1ps
module tb_audio_spectrum_fft;
reg clk=0,rst=1,valid=0;
reg signed [23:0] l=0,r=0;
wire [15:0] mag; wire [9:0] idx; wire mv,overrun;
integer peak,peakbin,frames,n,j,amp,results[0:2];
real f; integer dc=0; integer invert_right=0;
always #20 clk=~clk;
audio_spectrum_fft dut(clk,rst,valid,l,r,mag,idx,mv,overrun);
always @(negedge clk) if(mv) begin
 if((^mag)===1'bx) $fatal(1,"X magnitude");
 if(idx==0) begin peak=0;peakbin=0; end
 if(mag>peak) begin peak=mag;peakbin=idx; end
 if(idx==255) frames=frames+1;
end
task run_tone(input real freq,input integer amplitude);
begin
 @(negedge clk);rst=1; valid=0; frames=0;peak=0;
 repeat(3) @(negedge clk); rst=0;
 for(n=0;n<1024;n=n+1) begin
  l=$rtoi(amplitude*$sin(6.283185307179586*freq*n/48000.0))*256; l=l+dc*256; r=invert_right ? -l : l;
  valid=1; @(negedge clk); valid=0;
  repeat(520) @(negedge clk);
 end
 if(frames!=2 || overrun) $fatal(1,"cadence frames=%0d overrun=%b",frames,overrun);
 $display("freq=%0f amp=%0d peak_bin=%0d magnitude=%0d frames=%0d",freq,amplitude,peakbin,peak,frames);
end endtask
initial begin
 for(j=0;j<3;j=j+1) begin
  case(j) 0:amp=16384;1:amp=1638;2:amp=164;endcase
  run_tone(1000.0,amp);
  if(peakbin<10 || peakbin>12) $fatal(1,"1k frequency");
  results[j]=peak;
 end
 if(!(results[0]>results[1] && results[1]>results[2] && results[2]>0)) $fatal(1,"monotonicity");
 run_tone(4000.0,16384);
 if(peakbin<42 || peakbin>44) $fatal(1,"4k frequency");
 run_tone(0.0,0); if(peak!=0) $fatal(1,"silence");
 dc=-12000; run_tone(0.0,0);
 if(peak>4) $fatal(1,"DC rejection %0d",peak);
 dc=0;invert_right=1;run_tone(1000.0,16384);
 if(peak!=0) $fatal(1,"signed stereo cancellation");
 $display("PASS tb_audio_spectrum_fft");$finish;
end
initial begin #300000000; $fatal(1,"timeout");end
endmodule
