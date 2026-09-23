`timescale 1ns/1ps
module tb_audio_band_processor;
reg clk=0,rst=1,vs=0,sv=0,bv=0;reg signed [23:0] l=0,r=0;
reg [15:0] bm=0;reg [5:0] bi=0;reg bvalid=0;integer lane;wire [383:0] display_bands;
integer i,start_level,low_level;reg [383:0] held;
always #5 clk=~clk;
audio_band_processor dut(clk,rst,vs,sv,l,r,bm,bi,bvalid,bv,display_bands);
task frame(input integer pcm,input integer magnitude);
begin
 @(negedge clk);l=pcm*256;r=l;sv=1;
 for(lane=0;lane<48;lane=lane+1) begin
  bm=magnitude;bi=lane;bvalid=1;@(negedge clk);
 end
 bvalid=0;bv=1;
 @(negedge clk);sv=0;bv=0;
 repeat(160) @(negedge clk);
 held=display_bands;
 if((^held)===1'bx) $fatal(1,"X output");
 vs=1;@(negedge clk);vs=0;
 repeat(160) @(negedge clk);
 held=display_bands;
 repeat(5) @(negedge clk);
 if(display_bands!==held) $fatal(1,"midframe update");
end endtask
initial begin
 repeat(3) @(negedge clk);rst=0;
 frame(20000,4096);frame(20000,4096);
 start_level=display_bands[7:0];
 if(start_level<220 || start_level>255) $fatal(1,"attack %0d",start_level);
 $display("attack=%0d",start_level);
 // First zero frame prepares targets; following eleven frames release.
 frame(20000,0);start_level=display_bands[7:0];
 for(i=0;i<11;i=i+1) frame(20000,0);
 $display("release11=%0d/%0d",display_bands[7:0],start_level);
 if(display_bands[7:0]*100<start_level*30 || display_bands[7:0]*100>start_level*40) $fatal(1,"release ratio");
 for(i=0;i<18;i=i+1) frame(0,4096);
 if(display_bands!==0) $fatal(1,"silence did not gate");
 $display("silence=zero at 18 frames");
 frame(20000,4096);frame(20000,4096);
 frame(2000,410);frame(2000,410);low_level=display_bands[7:0];
 for(i=0;i<200;i=i+1) frame(2000,410);
 $display("AGC gain_shift=%0d recovered=%0d",dut.gain,display_bands[7:0]);
 if(dut.gain<3 || display_bands[7:0]<200) $fatal(1,"AGC recovery");
 // Publish alternating zero/nonzero bands to verify lane order and frame banks.
 @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;
 for(lane=0;lane<48;lane=lane+1) begin
  bm=lane[0]?4096:0;bi=lane;bvalid=1;@(negedge clk);
 end
 bvalid=0;bv=1;l=20000*256;r=l;sv=1;@(negedge clk);bv=0;sv=0;
 repeat(2) begin
  vs=1;@(negedge clk);vs=0;repeat(160) @(negedge clk);
 end
 for(i=0;i<48;i=i+1) begin
  if(i[0] && display_bands[i*8 +:8]<220) $fatal(1,"lane order %0d",i);
  if(!i[0] && display_bands[i*8 +:8]!=0) $fatal(1,"zero lane %0d",i);
 end
 // Check actual PCM threshold and hysteresis, not merely exact-zero silence.
 frame(82,64);frame(82,64);
 for(i=0;i<20;i=i+1) frame(58,64);
 if(dut.silent || display_bands==0) $fatal(1,"-55 dB boundary muted");
 for(i=0;i<17;i=i+1) frame(57,64);
 if(dut.silent) $fatal(1,"silence gate early");
 frame(57,64);
 if(!dut.silent || display_bands!==0) $fatal(1,"-55 dB silence threshold");
 frame(81,64);
 if(!dut.silent || display_bands!==0) $fatal(1,"wake hysteresis");
 frame(82,64);
 if(dut.silent || display_bands==0) $fatal(1,"wake threshold");
 $display("PCM gate: below 58 for 18 frames mutes; 58 holds; 81 stays muted; 82 wakes");
 $display("PASS tb_audio_band_processor");$finish;
end
initial begin #3000000;$fatal(1,"timeout");end
endmodule
