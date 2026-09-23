`timescale 1ns/1ps
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
          6'd0: edge_bin=9'd1;
          6'd1: edge_bin=9'd2;
          6'd2: edge_bin=9'd3;
          6'd3: edge_bin=9'd4;
          6'd4: edge_bin=9'd5;
          6'd5: edge_bin=9'd6;
          6'd6: edge_bin=9'd7;
          6'd7: edge_bin=9'd8;
          6'd8: edge_bin=9'd9;
          6'd9: edge_bin=9'd10;
          6'd10: edge_bin=9'd11;
          6'd11: edge_bin=9'd12;
          6'd12: edge_bin=9'd13;
          6'd13: edge_bin=9'd14;
          6'd14: edge_bin=9'd15;
          6'd15: edge_bin=9'd16;
          6'd16: edge_bin=9'd17;
          6'd17: edge_bin=9'd19;
          6'd18: edge_bin=9'd20;
          6'd19: edge_bin=9'd21;
          6'd20: edge_bin=9'd23;
          6'd21: edge_bin=9'd25;
          6'd22: edge_bin=9'd27;
          6'd23: edge_bin=9'd29;
          6'd24: edge_bin=9'd31;
          6'd25: edge_bin=9'd33;
          6'd26: edge_bin=9'd35;
          6'd27: edge_bin=9'd38;
          6'd28: edge_bin=9'd41;
          6'd29: edge_bin=9'd44;
          6'd30: edge_bin=9'd47;
          6'd31: edge_bin=9'd51;
          6'd32: edge_bin=9'd54;
          6'd33: edge_bin=9'd58;
          6'd34: edge_bin=9'd63;
          6'd35: edge_bin=9'd67;
          6'd36: edge_bin=9'd72;
          6'd37: edge_bin=9'd78;
          6'd38: edge_bin=9'd84;
          6'd39: edge_bin=9'd90;
          6'd40: edge_bin=9'd96;
          6'd41: edge_bin=9'd104;
          6'd42: edge_bin=9'd111;
          6'd43: edge_bin=9'd120;
          6'd44: edge_bin=9'd128;
          6'd45: edge_bin=9'd138;
          6'd46: edge_bin=9'd148;
          6'd47: edge_bin=9'd159;
          6'd48: edge_bin=9'd171;
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
