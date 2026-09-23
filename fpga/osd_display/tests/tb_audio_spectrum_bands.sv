`timescale 1ns/1ps
module tb_audio_spectrum_bands;
reg clk=0,rst=1,v=0;reg [15:0] mag=0;reg [9:0] idx=0;
wire [767:0] raw;wire done;integer i,j,k,expect_band;
always #5 clk=~clk;
audio_spectrum_bands dut(clk,rst,v,mag,idx,raw,done,,,);
initial begin
 repeat(3) @(negedge clk);rst=0;
 if(dut.edge_bin(0)!=1 || dut.edge_bin(48)!=171) $fatal(1,"endpoints");
 for(i=0;i<48;i=i+1) if(dut.edge_bin(i)>=dut.edge_bin(i+1)) $fatal(1,"zero width");
 for(k=1;k<171;k=k+1) begin
  for(j=0;j<256;j=j+1) begin
   @(negedge clk);v=1;idx=j;mag=(j==k)?12345:0;
  end
  @(negedge clk);v=0;
  if(!done) $fatal(1,"missing publish");
  for(i=0;i<48;i=i+1) begin
   if(k>=dut.edge_bin(i) && k<dut.edge_bin(i+1)) begin
    if(raw[i*16 +:16]!=12345) $fatal(1,"missing band %0d bin %0d",i,k);
   end else if(raw[i*16 +:16]!=0) $fatal(1,"leakage");
  end
 end
 // Distinct synthetic magnitudes at 187.5Hz, 3kHz, 12kHz.
 for(j=0;j<256;j=j+1) begin
  @(negedge clk);v=1;idx=j;mag=(j==2 || j==32 || j==128)?9000:0;
 end
 @(negedge clk);v=0;
 for(i=0;i<48;i=i+1) begin
  expect_band=0;
  if(2>=dut.edge_bin(i) && 2<dut.edge_bin(i+1)) expect_band=9000;
  if(32>=dut.edge_bin(i) && 32<dut.edge_bin(i+1)) expect_band=9000;
  if(128>=dut.edge_bin(i) && 128<dut.edge_bin(i+1)) expect_band=9000;
  if(raw[i*16 +:16]!==expect_band[15:0]) $fatal(1,"multi-bin");
 end
 $display("PASS tb_audio_spectrum_bands: 170 single-bin probes, 48 unique bands, multi-bin peaks");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
