`timescale 1ns/1ps
module tb_video_osd_regression;
reg clk=0,rst=1,vs=0,de=0;reg [23:0] rgb=24'h123456;reg menu=0;
wire [23:0] actual,reference;integer x,y,m;
always #5 clk=~clk;
video_osd_overlay dut(.video_clk(clk),.rst(rst),.vs(vs),.de(de),.rgb_in(rgb),.display_valid(1'b1),.display_test_pattern(1'b0),.storage_ready(1'b1),.manager_state(3'd2),.load_in_progress(1'b0),.target_image_index(3'd1),.current_image_index(3'd0),.image_count(4'd8),.menu_active(menu),.brightness_value(8'd200),.contrast_value(8'd128),.menu_channel(2'd1),.audio_level(8'd64),.audio_bands({48{8'd255}}),.rgb_out(actual));
video_osd_overlay_reference ref_dut(.video_clk(clk),.rst(rst),.vs(vs),.de(de),.rgb_in(rgb),.display_valid(1'b1),.display_test_pattern(1'b0),.storage_ready(1'b1),.manager_state(3'd2),.load_in_progress(1'b0),.target_image_index(3'd1),.current_image_index(3'd0),.image_count(4'd8),.menu_active(menu),.brightness_value(8'd200),.contrast_value(8'd128),.menu_channel(2'd1),.rgb_out(reference));
initial begin
 repeat(3) @(negedge clk);rst=0;
 for(m=0;m<2;m=m+1) begin
  menu=m;vs=1;@(negedge clk);vs=0;
  for(y=0;y<480;y=y+1) begin
   de=1;
   for(x=0;x<640;x=x+1) begin
    #1;
    if(!(x>=224 && x<=415 && y>=336 && y<=416) && !(x>=512 && x<632 && y>=8 && y<16))
      if(actual!==reference) $fatal(1,"regression x=%d y=%d menu=%d",x,y,m);
    @(negedge clk);
   end
   de=0;#1;if(actual!==rgb) $fatal(1,"blanking");repeat(3) @(negedge clk);
  end
 end
 $display("PASS tb_video_osd_regression: two full frames, title/status/ticker/menu unchanged");$finish;
end
endmodule
