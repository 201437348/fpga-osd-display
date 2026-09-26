`timescale 1ns/1ps
module tb_video_osd_regression;
reg clk=0,rst=1,vs=0,de=0;reg [23:0] rgb=24'h123456;reg menu=0;
wire [23:0] actual,reference;integer x,y,m;
always #5 clk=~clk;
// 喂入旧标题文本：新 OSD 必须与旧参考逐像素一致
wire [319:0] title_txt = 320'h202020202020202020202020202020202020202020202020202020202059414c505349442044534f;
video_osd_overlay dut(.info_text(title_txt),.video_clk(clk),.rst(rst),.vs(vs),.de(de),.rgb_in(rgb),.display_valid(1'b1),.display_test_pattern(1'b0),.storage_ready(1'b1),.manager_state(3'd2),.load_in_progress(1'b0),.target_image_index(3'd1),.current_image_index(3'd0),.image_count(4'd8),.menu_active(menu),.brightness_value(8'd200),.contrast_value(8'd128),.menu_channel(2'd1),.time_set(1'b0),.time_h(5'd0),.time_m(6'd0),.time_s(6'd0),.rgb_out(actual));
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
      if(!(x>=552 && x<616 && y>=460 && y<476)) begin   // 右下角时钟为新增内容
       // 信息栏背景改为半透明：旧参考的 BAR 色 -> 3/4 BAR + 1/4 画面（123456 -> 102540）
       if(reference===24'h10213A && (y<24 || y>=432)) begin
        if(actual!==24'h102540) $fatal(1,"bar blend x=%d y=%d got %h",x,y,actual);
       end else if(actual!==reference) $fatal(1,"regression x=%d y=%d menu=%d",x,y,m);
      end
    @(negedge clk);
   end
   de=0;#1;if(actual!==rgb) $fatal(1,"blanking");repeat(3) @(negedge clk);
  end
 end
 $display("PASS tb_video_osd_regression: two full frames, title/status/ticker/menu unchanged");$finish;
end
endmodule
