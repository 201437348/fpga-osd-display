from pathlib import Path
import math
base=Path('fpga/osd_display')
edges=list(range(1,14))
for k in range(1,37): edges.append(max(edges[-1]+1,round(13*(171/13)**(k/36))))
assert len(edges)==49 and edges[-1]==171
rom='\n'.join(f"          6'd{i}: edge_bin=9'd{v};" for i,v in enumerate(edges))
(base/'rtl/audio/audio_spectrum_bands.v').write_text('''`timescale 1ns/1ps
// Half-open bands: [edge[i],edge[i+1]); bins 1..170 at 93.75 Hz.
// Preserve 16-bit magnitudes until log compression; truncating here loses quiet tones.
module audio_spectrum_bands(
 input wire clk,rst,mag_valid,
 input wire [15:0] mag,
 input wire [9:0] mag_index,
 output reg [767:0] bands_raw,
 output reg bands_valid,
 output reg [15:0] band_mag,
 output reg [5:0] band_index,
 output reg band_valid
);
 reg [767:0] work;
 reg [5:0] band;
 reg [15:0] peak;
 function [8:0] edge_bin;
 input [5:0] i;
 begin case(i)
'''+rom+'''
 default:edge_bin=171;
 endcase end endfunction
 wire [15:0] next_peak=mag>peak ? mag : peak;
 always @(posedge clk or posedge rst) begin
  if(rst) begin work<=0;bands_raw<=0;bands_valid<=0;band<=0;peak<=0;band_mag<=0;band_index<=0;band_valid<=0;end
  else begin
   bands_valid<=0;band_valid<=0;
   if(mag_valid) begin
    if(mag_index==0) begin band<=0;peak<=0;work<=0;end
    else if(band<48 && mag_index>=edge_bin(band) && mag_index<edge_bin(band+1'b1)) begin
     if(mag_index==edge_bin(band+1'b1)-1) begin
      band_mag<=next_peak;band_index<=band;band_valid<=1;
      work[band*16 +:16]<=next_peak;peak<=0;band<=band+1'b1;
     end else peak<=next_peak;
    end
    if(mag_index==255) begin bands_raw<=work;bands_valid<=1;end
   end
  end
 end
endmodule
''')
(base/'rtl/audio/audio_band_processor.v').write_text('''`timescale 1ns/1ps
module audio_band_processor(
 input wire clk,rst,vs,sample_valid,
 input wire signed [23:0] sample_left,sample_right,
 input wire [15:0] band_mag,
 input wire [5:0] band_index,
 input wire band_valid,bands_valid,
 output reg [383:0] bands_display
);
 reg vs_d;
 wire frame_start=vs && !vs_d;
 wire signed [16:0] stereo=$signed({sample_left[23],sample_left[23:8]})+
                                 $signed({sample_right[23],sample_right[23:8]});
 wire signed [15:0] mono=stereo >>> 1;
 wire [15:0] abs_sample=mono[15] ? -mono : mono;
 reg [15:0] frame_peak,agc_peak;
 reg [4:0] quiet_frames;
 reg silent;

 reg [5:0] index;
 reg [383:0] work;
 (* ram_style = "block" *) reg [15:0] band_mem [0:127];
 reg write_bank,ready_bank,read_bank,have_bands;
 reg [15:0] band_q;
 reg [1:0] scan_phase;
 always @(posedge clk) begin
  if(!rst && band_valid) band_mem[{write_bank,band_index}]<=band_mag;
  band_q<=band_mem[{read_bank,index}];
 end

 reg busy;
 reg [2:0] gain;
 integer i;
 wire [15:0] observed=sample_valid && abs_sample>frame_peak ? abs_sample : frame_peak;
 wire quiet=observed<16'd184;
 wire wake=observed>=16'd260;
 // Bounded 0..30 dB gain, powers of two, target ~85% PCM full scale.
 function [2:0] gain_shift;
 input [15:0] peak;
 begin
  if(peak<870) gain_shift=5;
  else if(peak<1740) gain_shift=4;
  else if(peak<3481) gain_shift=3;
  else if(peak<6963) gain_shift=2;
  else if(peak<13926) gain_shift=1;
  else gain_shift=0;
 end endfunction
 function [7:0] log_level;
 input [15:0] magnitude;
 input [2:0] boost;
 integer b;
 reg [3:0] exponent,fraction;
 reg signed [9:0] q,v;
 reg [15:0] normalized;
 begin
  exponent=0;
  for(b=0;b<16;b=b+1) if(magnitude[b]) exponent=b;
  normalized=magnitude << (15-exponent);
  // log2(1 + m/16), rounded to Q4, 16-entry fractional ROM.
  case(normalized[14:11])
   0:fraction=0;1:fraction=1;2:fraction=3;3:fraction=4;
   4:fraction=5;5:fraction=6;6:fraction=7;7:fraction=8;
   8:fraction=9;9:fraction=10;10:fraction=11;11:fraction=12;
   12:fraction=13;13:fraction=14;14:fraction=15;15:fraction=15;
  endcase
  // FFT /512, Hann coherent gain /2: full-scale sine bin ~8192 (2^13).
  q=$signed({2'b0,exponent,4'b0})+$signed({6'b0,fraction})+$signed({3'b0,boost,4'b0})-10'sd48;
  v=(q<<1)-(q>>2)-(q>>3);
  if(magnitude==0 || q<=0) log_level=0;
  else if(v>255) log_level=255;
  else log_level=v[7:0];
 end endfunction
 function [7:0] release_level;
 input [7:0] old_level,new_level;
 reg [8:0] decay;
 begin
  decay=({1'b0,old_level}>>3)-({1'b0,old_level}>>5)+1;
  if(new_level>=old_level) release_level=new_level;
  else if(old_level<=decay) release_level=new_level;
  else if(old_level-decay<new_level) release_level=new_level;
  else release_level=old_level-decay;
 end endfunction
 // Rotate the private working vector once per band. Only the display copy
 // is exposed to pixels, so no variable-index feedback mux or tearing.
 wire [7:0] next_level=release_level(work[7:0],log_level(band_q,gain));
 always @(posedge clk or posedge rst) begin
  if(rst) work<=0;
  else if(busy && !frame_start && scan_phase==2)
   work<={next_level,work[383:8]};
 end
 always @(posedge clk or posedge rst) begin
  if(rst) begin
   vs_d<=0;frame_peak<=0;agc_peak<=0;quiet_frames<=0;silent<=1;
   index<=0;busy<=0;gain<=0;bands_display<=0;
   write_bank<=0;ready_bank<=1;read_bank<=1;have_bands<=0;scan_phase<=0;
  end else begin
   vs_d<=vs;
   if(bands_valid) begin
    ready_bank<=write_bank;write_bank<=~write_bank;have_bands<=1;
   end

   if(sample_valid && abs_sample>frame_peak) frame_peak<=abs_sample;
   if(frame_start) begin
    frame_peak<=0;
    if(observed>agc_peak) agc_peak<=observed;
    else agc_peak<=agc_peak-(agc_peak>>6);
    gain<=gain_shift(observed>agc_peak ? observed : agc_peak);
    if(wake) begin quiet_frames<=0;silent<=0;end
    else if(quiet) begin
     if(quiet_frames<18) quiet_frames<=quiet_frames+1'b1;
     if(quiet_frames>=17) silent<=1;
    end else quiet_frames<=0;
    if((silent && !wake) || (quiet && quiet_frames>=17)) bands_display<=0;
    else bands_display<=work;
    index<=0;busy<=have_bands || bands_valid;scan_phase<=0;
    read_bank<=bands_valid ? write_bank : ready_bank;
   end else if(busy) begin
    if(scan_phase==2) begin
     scan_phase<=0;
     if(index==47) busy<=0;
     else index<=index+1'b1;
    end else scan_phase<=scan_phase+1'b1;
   end
  end
 end
endmodule
''')
# Lookup mapping 0..255 to 0..80 avoids multipliers in pixel combinational path.
height='\n'.join(f"   8'd{i}: height=7'd{(i*80+127)//255};" for i in range(256))
grad='\n'.join(f"   7'd{i}: gradient=24'h{127+128*i//80:02x}{179+76*i//80:02x}{213+42*i//80:02x};" for i in range(81))
(base/'rtl/video/audio_bars_overlay.v').write_text('''`timescale 1ns/1ps
module audio_bars_overlay #(
 parameter [9:0] LINE_X0=224, LINE_X1=415
)(
 input wire [9:0] x,y,
 input wire de,
 input wire [383:0] bands_display,
 output reg [23:0] bars_rgb,
 output reg bars_active,line_active
);
 wire [9:0] dx=x-LINE_X0;
 wire [7:0] column=dx[9:2];
 wire [9:0] t=10'd416-y;
 reg [7:0] level;
 reg [6:0] h;
 function [6:0] height;
 input [7:0] v;
 begin case(v)
'''+height+'''
 default:height=0;
 endcase end endfunction
 function [23:0] gradient;
 input [6:0] v;
 begin case(v)
'''+grad+'''
 default:gradient=24'hffffff;
 endcase end endfunction
 always @* begin
  level=0;h=0;bars_rgb=0;bars_active=0;line_active=0;
  if(de && x>=LINE_X0 && x<=LINE_X1) begin
   if(column<48) level=bands_display[column*8 +:8];
   h=height(level);
   if(y==416) begin line_active=1;bars_rgb=24'hffffff;end
   else begin
    if(y==415) begin line_active=1;bars_rgb=24'hb8c4ce;end
    if(column<48 && !dx[1] && y>=336 && y<=415 && t<={3'b0,h} && h!=0) begin
     bars_active=1;line_active=0;bars_rgb=gradient(t[6:0]);
    end
   end
  end
 end
endmodule
''')
print('512-point edges:',edges)
