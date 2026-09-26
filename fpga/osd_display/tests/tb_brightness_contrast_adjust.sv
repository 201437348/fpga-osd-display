`timescale 1ns/1ps
module tb_brightness_contrast_adjust;
reg clk=0,rst=1,vs=0,toggle=0;reg [7:0] b=255,c=128;reg [23:0] rgb=0;reg [6:0] g=64;
wire [23:0] out;wire [7:0] bq,cq;wire [1:0] ch;wire active;
integer i,j,k,m,bright,contrast_value,expected,d,f9,ce;
integer gains [0:5];
always #5 clk=~clk;
brightness_contrast_adjust dut(clk,rst,vs,b,c,2'd0,1'b0,toggle,g,rgb,out,bq,cq,ch,active);
task commit;
begin
 @(negedge clk);toggle=~toggle;repeat(3) @(negedge clk);
 vs=1;@(negedge clk);vs=0;repeat(2) @(negedge clk);   // 淡入淡出标量再晚一拍
end endtask
function integer ref_out(input integer x,input integer bb,input integer cc,input integer gg);
 begin
  f9=((bb+1)*gg)/64;
  ce=(cc>=128)?cc:cc+((128-cc)*(64-gg))/64;
  bright=x*f9/256;d=bright-128;
  contrast_value=(d>=0)?(d*ce/128):-((-d*ce+127)/128);
  ref_out=contrast_value+128;if(ref_out<0) ref_out=0;if(ref_out>255) ref_out=255;
 end
endfunction
initial begin
 gains[0]=64;gains[1]=63;gains[2]=32;gains[3]=10;gains[4]=1;gains[5]=0;
 repeat(3) @(negedge clk);rst=0;
 for(m=0;m<6;m=m+1) for(j=0;j<4;j=j+1) for(k=0;k<4;k=k+1) begin
  @(negedge clk);b=j*85;c=k*85;g=gains[m];commit;
  for(i=0;i<256;i=i+1) begin
   rgb={8'(i),8'(i),8'(i)};#1;
   expected=ref_out(i,b,c,g);
   // g=64 时必须与原式 x*(b+1)/256 逐位一致
   if(g==64 && expected!=ref_out(i,b,c,64)) $fatal(1,"ref");
   if(out!=={8'(expected),8'(expected),8'(expected)}) $fatal(1,"RGB mismatch b=%0d c=%0d g=%0d i=%0d out=%0d exp=%0d",b,c,g,i,out[7:0],expected);
   if(g==0 && out!==24'd0) $fatal(1,"fade bottom not black b=%0d c=%0d i=%0d",b,c,i);
  end
 end
 g=64;b=255;c=128;commit;
 for(i=0;i<256;i=i+1) begin rgb={8'(i),8'(i),8'(i)};#1;if(out!==rgb) $fatal(1,"identity");end
 @(negedge clk);b=0;toggle=~toggle;repeat(5) @(negedge clk);
 if(bq!=255) $fatal(1,"midframe change");
 $display("PASS tb_brightness_contrast_adjust: 24576 RGB cases (6 fade gains), identity, frame commit, black at gain 0");$finish;
end
endmodule
