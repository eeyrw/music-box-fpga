module tb_fdn_reverb;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic clear_i;
  reverb_config_t config_i;
  logic in_valid;
  logic in_ready;
  mix_t in_l;
  mix_t in_r;
  logic out_valid;
  logic out_ready;
  mix_t out_l;
  mix_t out_r;
  logic busy;
  logic config_clamped;
  logic [7:0] valid_line_mask;
  logic [15:0] pre_delay_occupancy;
  logic [31:0] input_frame_count;
  logic [31:0] output_frame_count;
  logic [31:0] saturation_count;
  logic [15:0] max_processing_cycles;
  int errors = 0;

  always #5 clk <= ~clk;

  fdn_reverb #(
    .PRE_DELAY_CAPACITY(8),
    .LINE_LENGTH_0(1),
    .LINE_LENGTH_1(2),
    .LINE_LENGTH_2(3),
    .LINE_LENGTH_3(4),
    .LINE_LENGTH_4(5),
    .LINE_LENGTH_5(6),
    .LINE_LENGTH_6(7),
    .LINE_LENGTH_7(8)
  ) dut (.*);

  task automatic reset_dut;
    begin
      rst = 1'b1;
      clear_i = 1'b0;
      config_i = '0;
      config_i.input_send_q1_15 = 16'h7fff;
      in_valid = 1'b0;
      in_l = '0;
      in_r = '0;
      out_ready = 1'b1;
      repeat (3) @(negedge clk);
      rst = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic push_and_expect(
    input mix_t left, input mix_t right, input int expected_l, input int expected_r
  );
    int timeout;
    begin
      while (!in_ready) @(negedge clk);
      in_l = left;
      in_r = right;
      in_valid = 1'b1;
      @(negedge clk);
      in_valid = 1'b0;
      timeout = 0;
      while (!out_valid && timeout < 88) begin
        @(negedge clk);
        timeout++;
      end
      if (!out_valid) begin
        $error("FDN output timeout");
        errors++;
      end else if (int'($signed(out_l)) != expected_l ||
                   int'($signed(out_r)) != expected_r) begin
        $error("FDN output mismatch got %0d/%0d expected %0d/%0d",
               $signed(out_l), $signed(out_r), expected_l, expected_r);
        errors++;
      end
      @(negedge clk);
    end
  endtask

  task automatic push_and_capture(
    input mix_t left, input mix_t right, output int actual_l, output int actual_r
  );
    int timeout;
    begin
      while (!in_ready) @(negedge clk);
      in_l = left;
      in_r = right;
      in_valid = 1'b1;
      @(negedge clk);
      in_valid = 1'b0;
      timeout = 0;
      while (!out_valid && timeout < 88) begin
        @(negedge clk);
        timeout++;
      end
      if (!out_valid) begin
        $error("FDN output timeout during tail test");
        errors++;
        actual_l = 0;
        actual_r = 0;
      end else begin
        actual_l = int'($signed(out_l));
        actual_r = int'($signed(out_r));
      end
      @(negedge clk);
    end
  endtask

  initial begin
    int line;
    int frame;
    int tail_l;
    int tail_r;
    int nonzero_tail_frames;
    int signs_l [0:7];
    int signs_r [0:7];
    signs_l = '{1, 1, -1, -1, 1, 1, -1, -1};
    signs_r = '{1, -1, -1, 1, 1, -1, -1, 1};

    reset_dut();
    config_i.enable = 1'b1;
    push_and_expect(8000, 0, 0, 0);
    for (line = 0; line < 8; line++)
      push_and_expect(0, 0, 500 * signs_l[line], 500 * signs_r[line]);
    if (valid_line_mask != 8'hff || input_frame_count != 32'd9 ||
        output_frame_count != 32'd9 || max_processing_cycles > 16'd88) begin
      $error("FDN warm-up/cycle diagnostics mismatch");
      errors++;
    end

    reset_dut();
    config_i.enable = 1'b1;
    config_i.feedback_gain_q1_15[0] = 16'h2000;
    push_and_expect(8000, 0, 0, 0);
    push_and_expect(0, 0, 500, 500);
    push_and_expect(0, 0, 625, -375);

    reset_dut();
    config_i.enable = 1'b0;
    config_i.pre_delay_frames = 11'd2;
    config_i.damping_q1_15 = 16'h4000;
    push_and_expect(8000, 0, 0, 0);
    push_and_expect(0, 0, 0, 0);
    push_and_expect(0, 0, 0, 0);
    config_i.enable = 1'b1;
    push_and_expect(0, 0, 250, 250);
    if (pre_delay_occupancy != 16'd4) begin
      $error("FDN pre-delay occupancy mismatch");
      errors++;
    end

    clear_i = 1'b1;
    @(negedge clk);
    clear_i = 1'b0;
    push_and_expect(0, 0, 0, 0);
    if (valid_line_mask != 8'h01 || saturation_count != 0) begin
      $error("FDN clear/warm-up mismatch");
      errors++;
    end

    config_i.damping_q1_15 = 16'hffff;
    config_i.pre_delay_frames = 11'h7ff;
    config_i.feedback_gain_q1_15 = '{default: 16'hffff};
    push_and_expect(0, 0, 0, 0);
    if (!config_clamped) begin
      $error("FDN invalid configuration was not reported");
      errors++;
    end

    reset_dut();
    config_i.enable = 1'b1;
    push_and_expect(1234, -2345, 0, 0);
    out_ready = 1'b0;
    while (!in_ready) @(negedge clk);
    in_l = 24'sd3456;
    in_r = -24'sd4567;
    in_valid = 1'b1;
    @(negedge clk);
    in_valid = 1'b0;
    wait (out_valid);
    repeat (4) begin
      @(negedge clk);
      if (!out_valid || in_ready || !busy || $signed(out_l) != -70 ||
          $signed(out_r) != -70 || input_frame_count != 32'd2 ||
          output_frame_count != 32'd1) begin
        $error("FDN output changed under backpressure");
        errors++;
      end
    end
    out_ready = 1'b1;
    @(negedge clk);
    if (output_frame_count != 32'd2) begin
      $error("FDN output handshake count mismatch");
      errors++;
    end

    reset_dut();
    config_i.enable = 1'b1;
    config_i.damping_q1_15 = 16'h4666;
    config_i.feedback_gain_q1_15 = '{default: 16'h2c00};
    push_and_capture(24'sd1048576, -24'sd1048576, tail_l, tail_r);
    nonzero_tail_frames = 0;
    for (frame = 0; frame < 4000; frame++) begin
      push_and_capture('0, '0, tail_l, tail_r);
      if (frame >= 3744 && (tail_l != 0 || tail_r != 0))
        nonzero_tail_frames++;
    end
    if (nonzero_tail_frames != 0) begin
      $error("FDN quantized tail did not converge to exact zero");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: FDN reverb errors=%0d", errors);
    $display("PASS: eight-line FDN reverb");
    $finish;
  end
endmodule
