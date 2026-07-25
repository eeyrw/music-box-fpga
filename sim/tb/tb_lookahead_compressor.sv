module tb_lookahead_compressor;
  import synth_pkg::*;

  localparam int LOOKAHEAD_FRAMES = 4;
  localparam logic [31:0] OCTAVE_CB_Q12_20 = 32'd63130566;

  logic clk = 1'b0;
  logic rst;
  compressor_config_t config_i;
  logic signed [15:0] master_volume_i;
  logic in_valid;
  logic in_ready;
  mix_t in_l;
  mix_t in_r;
  logic out_valid;
  logic out_ready;
  pcm_t out_l;
  pcm_t out_r;
  logic enabled;
  logic primed;
  logic [15:0] delay_level_frames;
  logic [31:0] gain_reduction_cb_q12_20;
  logic [31:0] target_gain_reduction_cb_q12_20;
  logic [MIX_WIDTH-1:0] detector_peak;
  logic [31:0] max_gain_reduction_cb_q12_20;
  logic [MIX_WIDTH-1:0] max_detector_peak;
  logic [31:0] input_frame_count;
  logic [31:0] output_frame_count;
  logic [31:0] compressed_frame_count;
  logic [31:0] saturation_count;
  int errors = 0;

  always #5 clk <= ~clk;

  lookahead_compressor #(
    .LOOKAHEAD_FRAMES(LOOKAHEAD_FRAMES)
  ) dut (.*);

  task automatic reset_dut;
    begin
      rst = 1'b1;
      config_i = '0;
      master_volume_i = 16'sh7fff;
      in_valid = 1'b0;
      in_l = '0;
      in_r = '0;
      out_ready = 1'b1;
      repeat (4) @(negedge clk);
      rst = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic push_without_output(input mix_t left, input mix_t right);
    begin
      while (!in_ready) @(negedge clk);
      in_l = mix_t'(left);
      in_r = mix_t'(right);
      in_valid = 1'b1;
      @(negedge clk);
      in_valid = 1'b0;
      repeat (5) begin
        @(negedge clk);
        if (out_valid) begin
          $error("unexpected output while look-ahead delay was priming");
          errors++;
        end
      end
    end
  endtask

  task automatic push_and_expect(
    input mix_t left,
    input mix_t right,
    input int expected_l,
    input int expected_r
  );
    int timeout;
    begin
      while (!in_ready) @(negedge clk);
      in_l = mix_t'(left);
      in_r = mix_t'(right);
      in_valid = 1'b1;
      @(negedge clk);
      in_valid = 1'b0;
      timeout = 0;
      while (!out_valid && timeout < 20) begin
        @(negedge clk);
        timeout++;
      end
      if (!out_valid) begin
        $error("compressor output timeout");
        errors++;
      end else begin
        if (int'($signed(out_l)) != expected_l ||
            int'($signed(out_r)) != expected_r) begin
          $error("compressor output mismatch got %0d/%0d expected %0d/%0d",
                 $signed(out_l), $signed(out_r), expected_l, expected_r);
          errors++;
        end
        @(negedge clk);
      end
    end
  endtask

  initial begin
    reset_dut();
    push_without_output(1000, -1000);
    push_without_output(2000, -2000);
    push_without_output(3000, -3000);
    push_without_output(4000, -4000);
    if (!primed) begin
      $error("compressor did not report a full look-ahead delay");
      errors++;
    end
    if (delay_level_frames != 16'd4 || input_frame_count != 32'd4 ||
        output_frame_count != 32'd0 || detector_peak != 24'd4000 ||
        max_detector_peak != 24'd4000) begin
      $error("compressor prime diagnostics mismatch");
      errors++;
    end
    push_and_expect(5000, -5000, 1000, -1000);
    push_and_expect(6000, -6000, 2000, -2000);
    if (input_frame_count != 32'd6 || output_frame_count != 32'd2 ||
        compressed_frame_count != 32'd0 || saturation_count != 32'd0) begin
      $error("compressor bypass counters mismatch");
      errors++;
    end

    reset_dut();
    master_volume_i = 16'sh4000;
    push_without_output(10000, -10000);
    push_without_output(0, 0);
    push_without_output(0, 0);
    push_without_output(0, 0);
    push_and_expect(0, 0, 5000, -5000);

    reset_dut();
    config_i.enable = 1'b1;
    config_i.threshold_cb_q12_20 = 32'd0;
    config_i.ratio_slope_q0_16 = 16'h8000;
    config_i.attack_step_cb_q12_20 = 32'd0;
    config_i.release_step_cb_q12_20 = OCTAVE_CB_Q12_20 >> 1;
    push_without_output(10000, -10000);
    push_without_output(0, 0);
    push_without_output(0, 0);
    push_without_output(0, 0);
    push_and_expect(0, -131072, 5000, -5000);
    if (gain_reduction_cb_q12_20 != OCTAVE_CB_Q12_20) begin
      $error("2:1 compressor gain reduction mismatch: %0d",
             gain_reduction_cb_q12_20);
      errors++;
    end
    if (!enabled || target_gain_reduction_cb_q12_20 != OCTAVE_CB_Q12_20 ||
        max_gain_reduction_cb_q12_20 != OCTAVE_CB_Q12_20 ||
        detector_peak != 24'd131072 || max_detector_peak != 24'd131072 ||
        input_frame_count != 32'd5 || output_frame_count != 32'd1 ||
        compressed_frame_count != 32'd1) begin
      $error("compressor active diagnostics mismatch");
      errors++;
    end

    out_ready = 1'b0;
    while (!in_ready) @(negedge clk);
    in_l = '0;
    in_r = '0;
    in_valid = 1'b1;
    @(negedge clk);
    in_valid = 1'b0;
    wait (out_valid);
    repeat (3) begin
      @(negedge clk);
      if (!out_valid || in_ready || out_l != 0 || out_r != 0) begin
        $error("compressor did not hold output under backpressure");
        errors++;
      end
    end
    if (gain_reduction_cb_q12_20 != (OCTAVE_CB_Q12_20 -
                                      (OCTAVE_CB_Q12_20 >> 1))) begin
      $error("compressor release step mismatch: %0d", gain_reduction_cb_q12_20);
      errors++;
    end
    out_ready = 1'b1;
    @(negedge clk);

    reset_dut();
    push_without_output(100000, -100000);
    push_without_output(0, 0);
    push_without_output(0, 0);
    push_without_output(0, 0);
    push_and_expect(0, 0, 32767, -32768);
    if (saturation_count != 32'd2 || output_frame_count != 32'd1) begin
      $error("compressor saturation diagnostics mismatch");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: look-ahead compressor errors=%0d", errors);
    $display("PASS: look-ahead compressor");
    $finish;
  end
endmodule
