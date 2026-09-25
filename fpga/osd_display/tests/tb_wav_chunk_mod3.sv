`timescale 1ns/1ps

module tb_wav_chunk_mod3;
    fat32_wav_loader dut (.clk(1'b0), .rst(1'b1));
    integer residue, byte_value, index, lane;
    reg [31:0] value;
    reg [1:0] accumulated;

    task automatic check_word(input [31:0] word_value);
        begin
            accumulated = 0;
            for (lane = 0; lane < 4; lane = lane + 1)
                accumulated = dut.add_byte_mod3(accumulated, word_value[lane*8 +: 8]);
            if (accumulated !== (word_value % 3))
                $fatal(1, "mod3 mismatch: value=%h remainder=%0d", word_value, accumulated);
            if ((!word_value[0] && accumulated == 0) !== ((word_value % 6) == 0))
                $fatal(1, "divisibility mismatch: value=%h", word_value);
        end
    endtask

    initial begin
        // Exhaust every legal accumulator/input pair, not just the sizes
        // present in the WAV fixtures. '%' is the independent test oracle.
        for (residue = 0; residue < 3; residue = residue + 1)
            for (byte_value = 0; byte_value < 256; byte_value = byte_value + 1)
                if (dut.add_byte_mod3(residue[1:0], byte_value[7:0]) !==
                    ((residue + byte_value) % 3))
                    $fatal(1, "byte reduction mismatch: %0d + %0d", residue, byte_value);
        for (index = 0; index < 65536; index = index + 1)
            check_word(index);
        for (index = 0; index < 10000; index = index + 1) begin
            value = $random;
            check_word(value);
        end
        check_word(32'hffffffff);
        check_word(32'hfffffffe);
        check_word(32'hfffffffc);
        check_word(32'h80000000);
        $display("PASS tb_wav_chunk_mod3: 768 byte/residue pairs, 75540 full-width sizes");
        $finish;
    end
endmodule
