`timescale 1ns/1ps
module probe_time_unit;
    reg mem_clk = 0;
    reg video_clk = 0;
    always #4  mem_clk   = ~mem_clk;   // intended 125MHz -> period 8ns
    always #20 video_clk = ~video_clk; // intended 25MHz  -> period 40ns

    integer mem_edges = 0;
    integer vid_edges = 0;
    time    t_mem_first, t_mem_last;
    time    t_vid_first, t_vid_last;

    always @(posedge mem_clk) begin
        mem_edges = mem_edges + 1;
        if (mem_edges == 1) t_mem_first = $time;
        t_mem_last = $time;
    end

    always @(posedge video_clk) begin
        vid_edges = vid_edges + 1;
        if (vid_edges == 1) t_vid_first = $time;
        t_vid_last = $time;
    end

    initial begin
        #2000; // let a bunch of edges accumulate
        $display("mem_edges=%0d  t_mem_first=%0t  t_mem_last=%0t  delta=%0d",
                  mem_edges, t_mem_first, t_mem_last, (t_mem_last - t_mem_first));
        $display("vid_edges=%0d  t_vid_first=%0t  t_vid_last=%0t  delta=%0d",
                  vid_edges, t_vid_first, t_vid_last, (t_vid_last - t_vid_first));
        $display("expected mem period(ns)=8  expected video period(ns)=20*2=40");
        $display("measured mem avg period = %0d / %0d = %f",
                  (t_mem_last - t_mem_first), (mem_edges-1),
                  1.0*(t_mem_last - t_mem_first)/(mem_edges-1));
        $display("measured video avg period = %0d / %0d = %f",
                  (t_vid_last - t_vid_first), (vid_edges-1),
                  1.0*(t_vid_last - t_vid_first)/(vid_edges-1));
        $finish;
    end
endmodule
