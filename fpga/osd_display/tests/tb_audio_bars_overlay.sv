`timescale 1ns/1ps
module tb_audio_bars_overlay;
reg [9:0] x=0,y=0;reg de=1;reg [383:0] bands=0;
wire [23:0] rgb;wire bar,line_on;
integer ix,iy,mode,h,t;reg expected_bar,expected_line;reg [23:0] expected_rgb;
audio_bars_overlay dut(x,y,de,bands,rgb,bar,line_on);
initial begin
 for(mode=0;mode<3;mode=mode+1) begin
  case(mode) 0:begin bands=0;h=0;end
  1:begin bands={48{8'd3}};h=1;end
  2:begin bands={48{8'd255}};h=80;end endcase
  for(iy=0;iy<480;iy=iy+1) for(ix=0;ix<640;ix=ix+1) begin
   x=ix;y=iy;#1;
   expected_bar=ix>=224 && ix<=415 && ((ix-224)%4)<2 && h>0 && iy>=416-h && iy<=415;
   expected_line=ix>=224 && ix<=415 && (iy==416 || (iy==415 && !expected_bar));
   if(bar!==expected_bar || line_on!==expected_line) $fatal(1,"geometry x=%0d y=%0d h=%0d",ix,iy,h);
   if(expected_bar) begin
    t=416-iy;expected_rgb=((127+128*t/80)<<16)|((179+76*t/80)<<8)|(213+42*t/80);
    if(rgb!==expected_rgb) $fatal(1,"gradient");
   end
   if(expected_line && rgb!==(iy==416?24'hffffff:24'hb8c4ce)) $fatal(1,"line");
  end
 end
 // Exercise all 48 independent packed-bus indices, including last column.
 for(ix=0;ix<48;ix=ix+1) begin
  bands=0;bands[ix*8 +:8]=255;x=224+4*ix;y=336;#1;
  if(!bar) $fatal(1,"bar index %0d",ix);
 end
 de=0;#1;if(bar || line_on) $fatal(1,"blanking");
 $display("PASS tb_audio_bars_overlay: 921600 pixels, 48 indices, gradient, silence, blanking");$finish;
end
endmodule
