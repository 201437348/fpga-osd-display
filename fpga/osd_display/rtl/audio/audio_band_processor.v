`timescale 1ns/1ps
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
 // 16-bit PCM: 58 / 32768 is approximately -55 dBFS; 3 dB wake hysteresis.
 wire quiet=observed<16'd58;
 wire wake=observed>=16'd82;
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
