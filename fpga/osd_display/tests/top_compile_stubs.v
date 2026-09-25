// Syntax-only black boxes for elaborating the project top with Icarus.
// TD must still compile the vendor IP and encrypted HDMI/SDRAM wrappers.
module sys_pll(input refclk, input reset, output extlock, output clk0_out,
               output clk1_out, output clk2_out);
endmodule

module video_pll(input refclk, input reset, output extlock, output clk0_out,
                 output clk1_out);
endmodule

module seg_decoder(input [3:0] bin_data, output [6:0] seg_data);
endmodule

module seg_scan(input clk, input rst_n, output [5:0] seg_sel, output [7:0] seg_data,
                input [7:0] seg_data_0, input [7:0] seg_data_1, input [7:0] seg_data_2,
                input [7:0] seg_data_3, input [7:0] seg_data_4, input [7:0] seg_data_5);
endmodule

module video_timing_data(input video_clk, input rst, output read_req, input read_req_ack,
                         output hs, output vs, output de);
endmodule

module video_delay(input video_clk, input rst, output read_en, input [23:0] read_data,
                   input read_data_valid,
                   input hs, input vs, input de, output hs_r, output vs_r, output de_r,
                   output [23:0] vout_data);
endmodule

module sd_card_top #(
    parameter SPI_LOW_SPEED_DIV = 0, parameter SPI_HIGH_SPEED_DIV = 0
)(
    input clk, input rst, output SD_nCS, output SD_DCLK, output SD_MOSI, input SD_MISO,
    output sd_init_done, input sd_sec_read, input [31:0] sd_sec_read_addr,
    output [7:0] sd_sec_read_data, output sd_sec_read_data_valid, output sd_sec_read_end,
    input sd_sec_write, input [31:0] sd_sec_write_addr, input [7:0] sd_sec_write_data,
    output sd_sec_write_data_req, output sd_sec_write_end
);
endmodule

`ifndef OSD_USE_REAL_FRAME_READ_WRITE
module frame_read_write #(
    parameter WRITE_V_FLIP = 0,
    parameter WRITE_BUFFER_SOLID_DIAGNOSTIC = 0,
    parameter FRAME_WIDTH = 0,
    parameter FRAME_HEIGHT = 0, parameter SLIDE_FEATHER_ENABLE = 1,
    parameter SLIDE_FIFO_UNIFORM_DIAGNOSTIC = 0,
    parameter SLIDE_SDRAM_UNIFORM_DIAGNOSTIC = 0,
    parameter SLIDE_READ_ADDRESS_PATTERN_DIAGNOSTIC = 0,
    parameter SLIDE_PHASE_COLOR_DIAGNOSTIC = 0,
    parameter READ_CHUNK_PREROLL_WORDS = 0,
    parameter FIXED_READ_BURST_ENABLE = 0,
    parameter READ_FIFO_MARKER_ENABLE = 0,
    parameter READ_FIFO_MARKER_START = 0,
    parameter READ_FIFO_MARKER_WIDTH = 16
)(
    input mem_clk, input rst, input Sdr_init_done, input Sdr_init_ref_vld, input Sdr_busy,
    output App_rd_en, output [20:0] App_rd_addr, input Sdr_rd_en,
    input [31:0] Sdr_rd_dout, input read_clk, input read_req, output read_req_ack,
    output read_finish, input [23:0] read_addr_0, input [23:0] read_addr_1,
    input [23:0] read_addr_2, input [23:0] read_addr_3, input [23:0] read_addr_4,
    input [23:0] read_addr_5, input [2:0] read_addr_index,
    input [2:0] read_addr_index_old, input slide_active, input [9:0] slide_position,
    input [23:0] read_len, input read_en, input display_valid,
    output [31:0] read_data, output read_data_valid, output read_fault,
    output [3:0] read_fifo_underflow_count_per_frame,
    output App_wr_en,
    output [20:0] App_wr_addr, output [31:0] App_wr_din, output [3:0] App_wr_dm,
    input write_clk, input write_req, output write_req_ack, output write_finish,
    input [23:0] write_addr_0, input [23:0] write_addr_1, input [23:0] write_addr_2,
    input [23:0] write_addr_3, input [23:0] write_addr_4, input [23:0] write_addr_5,
    input [2:0] write_addr_index, input [23:0] write_len,
    input write_en, input [31:0] write_data, output write_fifo_afull
);
endmodule
`endif

module sdram(input Clk, input Clk_sft, input Rst, output Sdr_init_done,
             output Sdr_init_ref_vld, output Sdr_busy, input App_wr_en,
             input [20:0] App_wr_addr, input [3:0] App_wr_dm, input [31:0] App_wr_din,
             input App_rd_en, input [20:0] App_rd_addr, output Sdr_rd_en,
             output [31:0] Sdr_rd_dout);
endmodule

`ifndef OSD_USE_REAL_VIDEO_RGB_TO_AXIS
module video_rgb_to_axis_640x480(
    input I_clk, input I_rst, input I_vs, input I_de, input [23:0] I_rgb,
    input I_video_ready, input I_marker_enable,
    output O_video_user, output O_video_valid, output O_video_last,
    output [23:0] O_video_data, output [3:0] O_backpressure_count
);
endmodule
`endif

module startup_pulse #(parameter CNT_MAX = 0)(input I_clk, input I_rst, output O_pulse);
endmodule

module hdmi_1_4b_transmitter_core_wrapper #(
    parameter DEVICE = "", parameter HTOTAL = 0, parameter HSA = 0, parameter HFP = 0,
    parameter HBP = 0, parameter HACTIVE = 0, parameter VTOTAL = 0, parameter VSA = 0,
    parameter VFP = 0, parameter VBP = 0, parameter VACTIVE = 0, parameter VIDEO_VIC = 0,
    parameter VIDEO_TPG = "", parameter VIDEO_FORMAT = "", parameter AUDIO_SAMPLE_RATE = "",
    parameter IIC_SCL_DIV = 0
)(
    input I_pixel_clk, input I_rst, input I_edid_read_trig, output O_edid_read_valid,
    output [7:0] O_edid_read_data, input I_axis_s_user, input I_axis_s_valid,
    input I_axis_s_last, input [23:0] I_axis_s_data, output O_axis_s_ready,
    input I_audio_valid, input [23:0] I_audio_left_data, input [23:0] I_audio_right_data,
    input I_acr_valid, input [19:0] I_acr_cts, input [19:0] I_acr_n,
    output O_video_locked, output O_ddc_scl, inout IO_ddc_sda,
    output [9:0] O_ch0_tmds_data, output [9:0] O_ch1_tmds_data,
    output [9:0] O_ch2_tmds_data, output [9:0] O_clk_tmds_data
);
endmodule

module hdmi_phy_wrapper #(
    parameter DEVICE = ""
)(
    input I_pixel_clk, input I_serial_clk, input I_rst, input [9:0] I_tmds_channel_0,
    input [9:0] I_tmds_channel_1, input [9:0] I_tmds_channel_2,
    input [9:0] I_tmds_channel_clk, output O_tmds_ch0_p, output O_tmds_ch1_p,
    output O_tmds_ch2_p, output O_tmds_clk_p
);
endmodule
