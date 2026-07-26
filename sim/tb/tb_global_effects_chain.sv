module tb_global_effects_chain;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic [1:0] clear_i;
  chorus_config_t chorus_config_i;
  reverb_config_t reverb_config_i;
  logic in_valid;
  logic in_ready;
  mix_t in_l;
  mix_t in_r;
  logic out_valid;
  logic out_ready;
  mix_t out_l;
  mix_t out_r;
  spatial_effect_diagnostics_t diagnostics_o;
  int errors = 0;

  always #5 clk <= ~clk;

  global_effects_chain #(
    .CHORUS_DELAY_CAPACITY(8),
    .REVERB_PRE_DELAY_CAPACITY(8),
    .REVERB_LINE_LENGTH_0(1),
    .REVERB_LINE_LENGTH_1(2),
    .REVERB_LINE_LENGTH_2(3),
    .REVERB_LINE_LENGTH_3(4),
    .REVERB_LINE_LENGTH_4(5),
    .REVERB_LINE_LENGTH_5(6),
    .REVERB_LINE_LENGTH_6(7),
    .REVERB_LINE_LENGTH_7(8)
  ) dut (.*);

  task automatic reset_dut;
    begin
      rst = 1'b1;
      clear_i = 2'b00;
      chorus_config_i = '0;
      reverb_config_i = '0;
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
      while (!out_valid && timeout < 100) begin
        @(negedge clk);
        timeout++;
      end
      if (!out_valid) begin
        $error("global effects output timeout");
        errors++;
      end else if (int'($signed(out_l)) != expected_l ||
                   int'($signed(out_r)) != expected_r) begin
        $error("global effects mismatch got %0d/%0d expected %0d/%0d",
               $signed(out_l), $signed(out_r), expected_l, expected_r);
        errors++;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    reset_dut();
    push_and_expect(123456, -234567, 123456, -234567);

    reset_dut();
    chorus_config_i.enable = 1'b1;
    chorus_config_i.base_delay_q16_8 = 24'd256;
    chorus_config_i.input_send_q1_15 = 16'h7fff;
    chorus_config_i.return_gain_q1_15 = 16'h4000;
    push_and_expect(8000, -4000, 8000, -4000);
    push_and_expect(2000, 1000, 6000, -1000);

    reset_dut();
    reverb_config_i.enable = 1'b1;
    reverb_config_i.input_send_q1_15 = 16'h7fff;
    reverb_config_i.return_gain_q1_15 = 16'h7fff;
    push_and_expect(8000, 0, 8000, 0);
    push_and_expect(0, 0, 500, 500);

    reset_dut();
    chorus_config_i.enable = 1'b1;
    chorus_config_i.base_delay_q16_8 = 24'd256;
    chorus_config_i.input_send_q1_15 = 16'h7fff;
    chorus_config_i.return_gain_q1_15 = 16'h7fff;
    push_and_expect(3000, -3000, 3000, -3000);
    while (!in_ready) @(negedge clk);
    in_l = 24'sd100;
    in_r = -24'sd100;
    in_valid = 1'b1;
    @(negedge clk);
    in_valid = 1'b0;
    chorus_config_i.return_gain_q1_15 = '0;
    wait (out_valid);
    if ($signed(out_l) != 3100 || $signed(out_r) != -3100) begin
      $error("per-frame configuration snapshot mismatch got %0d/%0d",
             $signed(out_l), $signed(out_r));
      errors++;
    end
    out_ready = 1'b0;
    repeat (4) begin
      @(negedge clk);
      if (!out_valid || in_ready || !diagnostics_o.busy || $signed(out_l) != 3100 ||
          $signed(out_r) != -3100) begin
        $error("global effects output changed under backpressure");
        errors++;
      end
    end
    if (diagnostics_o.input_frame_count != 2 ||
        diagnostics_o.output_frame_count != 1 ||
        diagnostics_o.max_processing_cycles == 0 ||
        diagnostics_o.max_processing_cycles > 96) begin
      $error("global effects frame diagnostics mismatch in=%0d out=%0d max=%0d",
             diagnostics_o.input_frame_count,
             diagnostics_o.output_frame_count,
             diagnostics_o.max_processing_cycles);
      errors++;
    end
    clear_i = 2'b01;
    @(negedge clk);
    clear_i = 2'b00;
    out_ready = 1'b1;
    if (out_valid || diagnostics_o.busy || !in_ready ||
        diagnostics_o.chorus_history_level_frames != 0 ||
        diagnostics_o.reverb_pre_delay_occupancy == 0 ||
        diagnostics_o.mixer_saturation_count != 0 ||
        diagnostics_o.input_frame_count != 0 ||
        diagnostics_o.output_frame_count != 0 ||
        diagnostics_o.max_processing_cycles != 0) begin
      $error("selective chorus clear mismatch");
      errors++;
    end
    clear_i = 2'b10;
    @(negedge clk);
    clear_i = 2'b00;
    if (diagnostics_o.reverb_valid_line_mask != 0 ||
        diagnostics_o.reverb_pre_delay_occupancy != 0) begin
      $error("selective reverb clear mismatch");
      errors++;
    end

    if (diagnostics_o.chorus_config_clamped ||
        diagnostics_o.reverb_config_clamped ||
        diagnostics_o.mixer_config_clamped ||
        diagnostics_o.chorus_saturation_count != 0 ||
        diagnostics_o.reverb_saturation_count != 0 ||
        diagnostics_o.reverb_max_processing_cycles > 16'd88) begin
      $error("global effects diagnostics mismatch");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: global effects chain errors=%0d", errors);
    $display("PASS: global effects chain");
    $finish;
  end
endmodule
