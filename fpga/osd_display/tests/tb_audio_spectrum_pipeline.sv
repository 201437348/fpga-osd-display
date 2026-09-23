`timescale 1ns/1ps
module tb_audio_spectrum_pipeline;
reg clk=0,rst=1,sv=0;reg signed [23:0] l=0,r=0;
wire [15:0] mag;wire [9:0] idx;wire mv,overrun,bv;
wire [767:0] raw;wire [383:0] display_bands;
wire [15:0] bm;wire [5:0] bi;wire bvalid;
reg vs=0;integer n,i,count=0;reg [15:0] p2,p32,p128;
always #20 clk=~clk;
audio_spectrum_fft fft(clk,rst,sv,l,r,mag,idx,mv,overrun);
audio_spectrum_bands bands(clk,rst,mv,mag,idx,raw,bv,bm,bi,bvalid);
audio_band_processor proc(clk,rst,vs,sv,l,r,bm,bi,bvalid,bv,display_bands);
always @(negedge clk) if(bv) count=count+1;
initial begin
 repeat(3) @(negedge clk);rst=0;
 for(n=0;n<1536;n=n+1) begin
  l=$rtoi(5000*$sin(6.283185307179586*187.5*n/48000.0)+5000*$sin(6.283185307179586*3000*n/48000.0)+5000*$sin(6.283185307179586*12000*n/48000.0))*256;r=l;
  sv=1;@(negedge clk);sv=0;repeat(520) @(negedge clk);
 end
 if(count<4 || overrun) $fatal(1,"pipeline cadence");
 p2=raw[1*16 +:16];p32=raw[24*16 +:16];p128=raw[44*16 +:16];
 $display("multi-tone band peaks: %0d %0d %0d",p2,p32,p128);
 if(p2<800 || p32<1000 || p128<1000) $fatal(1,"missing tones");
 if(raw[15*16 +:16]>100 || raw[40*16 +:16]>100) $fatal(1,"unexpected remote-band energy");
 // One frame builds processor targets, next frame commits them.
 repeat(2) begin vs=1;@(negedge clk);vs=0;repeat(160) @(negedge clk);end
 if((^display_bands)===1'bx || display_bands==0) $fatal(1,"pipeline output");
 $display("PASS tb_audio_spectrum_pipeline");$finish;
end
initial begin #100000000;$fatal(1,"timeout");end
endmodule
