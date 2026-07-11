module tb_i2s_tx;
  import synth_pkg::*;
  import "DPI-C" function void exit(input int code);

  logic clk = 1'b0;
  logic rst;
  logic sample_valid;
  logic sample_ready;
  pcm_t sample_l;
  pcm_t sample_r;
  logic underrun_pulse;
  logic i2s_bclk;
  logic i2s_lrclk;
  logic i2s_sdata;

  logic bclk_d;
  logic rx_lrclk;
  logic [3:0] rx_bit_count;
  logic [14:0] rx_shift;
  pcm_t rx_left;
  int matched_frames = 0;
  int decoded_frames = 0;
  int underruns = 0;
  int errors = 0;

  pcm_t expected_l [0:2];
  pcm_t expected_r [0:2];

  always #5 clk = ~clk;

  i2s_tx dut (
    .clk,
    .rst,
    .sample_valid,
    .sample_ready,
    .sample_l,
    .sample_r,
    .underrun_pulse,
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata
  );

  task automatic send_frame(input pcm_t left, input pcm_t right);
    begin
      @(posedge clk);
      while (!sample_ready) @(posedge clk);
      sample_l = left;
      sample_r = right;
      sample_valid = 1'b1;
      @(posedge clk);
      sample_valid = 1'b0;
      sample_l = '0;
      sample_r = '0;
    end
  endtask

  task automatic check_decoded_frame(input pcm_t left, input pcm_t right);
    begin
      decoded_frames++;
      if (matched_frames == 0) begin
        if (left === expected_l[0] && right === expected_r[0]) begin
          matched_frames = 1;
        end
      end else if (matched_frames < 3) begin
        if (left !== expected_l[matched_frames] || right !== expected_r[matched_frames]) begin
          $error("decoded frame %0d got L=%0d R=%0d expected L=%0d R=%0d",
                 matched_frames, left, right, expected_l[matched_frames], expected_r[matched_frames]);
          errors++;
        end
        matched_frames++;
      end
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      bclk_d <= 1'b0;
      rx_lrclk <= 1'b0;
      rx_bit_count <= '0;
      rx_shift <= '0;
      rx_left <= '0;
    end else begin
      bclk_d <= i2s_bclk;
      if (underrun_pulse)
        underruns++;

      if (!bclk_d && i2s_bclk) begin
        if ((i2s_lrclk != rx_lrclk) && (rx_bit_count != 4'd15)) begin
          rx_lrclk <= i2s_lrclk;
          rx_bit_count <= '0;
          rx_shift <= '0;
        end else begin
          rx_shift <= {rx_shift[13:0], i2s_sdata};
          if (rx_bit_count == 4'd15) begin
            if (!rx_lrclk) begin
              rx_left <= pcm_t'({rx_shift, i2s_sdata});
            end else begin
              check_decoded_frame(rx_left, pcm_t'({rx_shift, i2s_sdata}));
            end
            rx_lrclk <= i2s_lrclk;
            rx_bit_count <= '0;
            rx_shift <= '0;
          end else begin
            rx_bit_count <= rx_bit_count + 4'd1;
          end
        end
      end
    end
  end

  initial begin
    expected_l[0] = 16'sh1234;
    expected_r[0] = -16'sh2345;
    expected_l[1] = 16'sh7fff;
    expected_r[1] = -16'sh8000;
    expected_l[2] = -16'sh0101;
    expected_r[2] = 16'sh4000;

    rst = 1'b1;
    sample_valid = 1'b0;
    sample_l = '0;
    sample_r = '0;

    repeat (8) @(posedge clk);
    rst = 1'b0;

    send_frame(expected_l[0], expected_r[0]);
    send_frame(expected_l[1], expected_r[1]);
    send_frame(expected_l[2], expected_r[2]);

    repeat (8000) @(posedge clk);

    if (matched_frames != 3) begin
      $error("decoded only %0d expected frames after %0d total decoded frames", matched_frames, decoded_frames);
      errors++;
    end
    if (underruns == 0) begin
      $error("expected at least one underrun after input frames were exhausted");
      errors++;
    end

    if (errors != 0) begin
      $error("FAIL: %0d errors", errors);
      exit(1);
    end
    $display("PASS: I2S transmitter");
    $finish;
  end
endmodule
