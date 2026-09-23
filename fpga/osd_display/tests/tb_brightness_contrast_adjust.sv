`timescale 1ns/1ps
module tb_brightness_contrast_adjust;
reg clk=0,rst=1,vs=0,toggle=0;reg [7:0] b=255,c=128;reg [23:0] rgb=0;
wire [23:0] out;wire [7:0] bq,cq;wire [1:0] ch;wire active;
integer i,j,k,bright,contrast_value,expected,d;
always #5 clk=~clk;
brightness_contrast_adjust dut(clk,rst,vs,b,c,2'd0,1'b0,toggle,rgb,out,bq,cq,ch,active);
task commit;
begin
 @(negedge clk);toggle=~toggle;repeat(3) @(negedge clk);
 vs=1;@(negedge clk);vs=0;
end endtask
initial begin
 repeat(3) @(negedge clk);rst=0;
 for(j=0;j<4;j=j+1) for(k=0;k<4;k=k+1) begin
  @(negedge clk);b=j*85;c=k*85;commit;
  for(i=0;i<256;i=i+1) begin
   rgb={8'(i),8'(i),8'(i)};#1;
   bright=i*(b+1)/256;d=bright-128;
   contrast_value=(d>=0)?(d*c/128):-((-d*c+127)/128);
   expected=contrast_value+128;if(expected<0) expected=0;if(expected>255) expected=255;
   if(out!=={8'(expected),8'(expected),8'(expected)}) $fatal(1,"RGB mismatch b=%d c=%d i=%d",b,c,i);
  end
 end
 b=255;c=128;commit;
 for(i=0;i<256;i=i+1) begin rgb={8'(i),8'(i),8'(i)};#1;if(out!==rgb) $fatal(1,"identity");end
 @(negedge clk);b=0;toggle=~toggle;repeat(5) @(negedge clk);
 if(bq!=255) $fatal(1,"midframe change");
 $display("PASS tb_brightness_contrast_adjust: 4096 RGB cases, identity, frame commit");$finish;
end
endmodule
