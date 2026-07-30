module tb_stereo_chorus;
  import synth_pkg::*;

  localparam int DELAY_CAPACITY = 8;
  logic clk = 1'b0;
  logic rst;
  logic clear_i;
  chorus_config_t config_i;
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
  logic [15:0] history_level_frames;
  logic [31:0] lfo_phase_q0_32;
  logic [31:0] saturation_count;
  int errors = 0;

  always #5 clk <= ~clk;
  stereo_chorus #(.DELAY_CAPACITY(DELAY_CAPACITY)) dut (.*);

  task automatic reset_dut;
    begin
      rst = 1'b1;
      clear_i = 1'b0;
      config_i = '0;
      config_i.base_delay_q16_8 = 24'd256;
      config_i.input_send_q1_15 = 16'h7fff;
      config_i.stereo_phase_offset_q0_32 = 32'h4000_0000;
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
      in_l = mix_t'(left);
      in_r = mix_t'(right);
      in_valid = 1'b1;
      @(negedge clk);
      in_valid = 1'b0;
      timeout = 0;
      while (!out_valid && timeout < 16) begin
        @(negedge clk);
        timeout++;
      end
      if (!out_valid) begin
        $error("chorus output timeout");
        errors++;
      end else if (int'($signed(out_l)) != expected_l ||
                   int'($signed(out_r)) != expected_r) begin
        $error("chorus output mismatch got %0d/%0d expected %0d/%0d",
               $signed(out_l), $signed(out_r), expected_l, expected_r);
        errors++;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    int index;
    reset_dut();
    config_i.enable = 1'b1;
    config_i.base_delay_q16_8 = 24'd512;
    config_i.stereo_phase_offset_q0_32 = '0;
    push_and_expect(100, -100, 0, 0);
    push_and_expect(200, -200, 0, 0);
    push_and_expect(300, -300, 100, -100);
    push_and_expect(400, -400, 200, -200);
    if (history_level_frames != 16'd4 || lfo_phase_q0_32 != 0) begin
      $error("chorus history diagnostics mismatch");
      errors++;
    end

    reset_dut();
    config_i.enable = 1'b1;
    config_i.base_delay_q16_8 = 24'd384;
    config_i.feedback_q1_15 = 16'sh4000;
    config_i.stereo_phase_offset_q0_32 = '0;
    push_and_expect(1000, -1000, 0, 0);
    push_and_expect(2000, -2000, 500, -500);
    push_and_expect(0, 0, 1625, -1625);

    clear_i = 1'b1;
    @(negedge clk);
    clear_i = 1'b0;
    push_and_expect(0, 0, 0, 0);
    if (history_level_frames != 16'd1 || saturation_count != 0) begin
      $error("chorus clear diagnostics mismatch");
      errors++;
    end

    reset_dut();
    config_i.enable = 1'b0;
    config_i.base_delay_q16_8 = 24'd768;
    config_i.depth_q16_8 = 24'd256;
    config_i.lfo_phase_inc_q0_32 = 32'h4000_0000;
    repeat (5) push_and_expect(100, 200, 0, 0);
    if (history_level_frames != 16'd5 || lfo_phase_q0_32 != 32'h4000_0000) begin
      $error("disabled chorus did not advance state");
      errors++;
    end

    config_i.enable = 1'b1;
    config_i.base_delay_q16_8 = 24'd0;
    config_i.depth_q16_8 = 24'hffffff;
    config_i.feedback_q1_15 = 16'sh7fff;
    config_i.input_send_q1_15 = 16'hffff;
    push_and_expect(0, 0, 100, 200);
    if (!config_clamped) begin
      $error("chorus did not report configuration clamp");
      errors++;
    end

    reset_dut();
    config_i.enable = 1'b1;
    config_i.base_delay_q16_8 = 24'd768;
    config_i.depth_q16_8 = 24'd256;
    config_i.stereo_phase_offset_q0_32 = 32'h4000_0000;
    push_and_expect(10, 100, 0, 0);
    push_and_expect(20, 110, 0, 0);
    push_and_expect(30, 120, 0, 0);
    push_and_expect(40, 130, 10, 0);
    push_and_expect(50, 140, 20, 100);

    clear_i = 1'b1;
    @(negedge clk);
    clear_i = 1'b0;
    config_i.base_delay_q16_8 = 24'd256;
    config_i.depth_q16_8 = 24'd0;
    config_i.stereo_phase_offset_q0_32 = '0;
    push_and_expect(0, 0, 0, 0);
    for (index = 1; index <= 12; index++)
      push_and_expect(mix_t'(index), mix_t'(-index),
                      index - 1, -(index - 1));

    clear_i = 1'b1;
    @(negedge clk);
    clear_i = 1'b0;
    config_i.feedback_q1_15 = 16'sh6000;
    push_and_expect(16777215, -16777216, 0, 0);
    push_and_expect(16777215, -16777216, 16777215, -16777216);
    if (saturation_count != 32'd2) begin
      $error("chorus saturation count mismatch");
      errors++;
    end

    reset_dut();
    config_i.enable = 1'b1;
    config_i.base_delay_q16_8 = 24'd256;
    config_i.stereo_phase_offset_q0_32 = '0;
    push_and_expect(1234, -2345, 0, 0);
    out_ready = 1'b0;
    while (!in_ready) @(negedge clk);
    in_l = 25'sd3456;
    in_r = -25'sd4567;
    in_valid = 1'b1;
    @(negedge clk);
    in_valid = 1'b0;
    wait (out_valid);
    repeat (4) begin
      @(negedge clk);
      if (!out_valid || in_ready || !busy || $signed(out_l) != 1234 ||
          $signed(out_r) != -2345 || history_level_frames != 16'd2) begin
        $error("chorus output/state changed under backpressure");
        errors++;
      end
    end
    out_ready = 1'b1;
    @(negedge clk);

    if (errors != 0)
      $fatal(1, "FAIL: stereo chorus errors=%0d", errors);
    $display("PASS: stereo chorus");
    $finish;
  end
endmodule
