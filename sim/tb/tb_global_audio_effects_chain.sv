module tb_global_audio_effects_chain;
  import synth_pkg::*;

  localparam int OUTPUT_TIMEOUT_CYCLES = 128;

  logic clk = 1'b0;
  logic rst;
  logic [1:0] effect_clear_i;
  global_audio_config_t config_i;
  logic in_valid;
  logic in_ready;
  mix_t in_l;
  mix_t in_r;
  logic out_valid;
  logic out_ready;
  pcm_t out_l;
  pcm_t out_r;
/* verilator lint_off UNUSEDSIGNAL */
  logic busy;
/* verilator lint_on UNUSEDSIGNAL */
  audio_diagnostics_t diagnostics_o;
  int errors = 0;

  always #5 clk <= ~clk;

  global_audio_effects_chain #(
    .CHORUS_DELAY_CAPACITY(8),
    .REVERB_PRE_DELAY_CAPACITY(8),
    .REVERB_LINE_LENGTH_0(1), .REVERB_LINE_LENGTH_1(2),
    .REVERB_LINE_LENGTH_2(3), .REVERB_LINE_LENGTH_3(4),
    .REVERB_LINE_LENGTH_4(5), .REVERB_LINE_LENGTH_5(6),
    .REVERB_LINE_LENGTH_6(7), .REVERB_LINE_LENGTH_7(8),
    .COMPRESSOR_LOOKAHEAD_FRAMES(2)
  ) dut (.*);

  task automatic push(input mix_t left, input mix_t right);
    begin
      while (!in_ready) @(negedge clk);
      in_l = left;
      in_r = right;
      in_valid = 1'b1;
      @(negedge clk);
      in_valid = 1'b0;
    end
  endtask

  task automatic expect_output(input int left, input int right);
    int timeout;
    begin
      timeout = 0;
      while (!out_valid && timeout < OUTPUT_TIMEOUT_CYCLES) begin
        @(negedge clk);
        timeout++;
      end
      if (!out_valid || int'($signed(out_l)) != left ||
          int'($signed(out_r)) != right) begin
        $error("global audio effects mismatch got %0d/%0d expected %0d/%0d",
               $signed(out_l), $signed(out_r), left, right);
        errors++;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    rst = 1'b1;
    effect_clear_i = 2'b00;
    config_i = '0;
    config_i.master_volume = 16'sh7fff;
    in_valid = 1'b0;
    in_l = '0;
    in_r = '0;
    out_ready = 1'b1;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    @(negedge clk);

    push(1000, -1000);
    while (!in_ready) @(negedge clk);
    if (out_valid) begin
      $error("compressor emitted before look-ahead primed");
      errors++;
    end
    push(2000, -2000);
    while (!in_ready) @(negedge clk);
    if (out_valid) begin
      $error("compressor emitted on final priming frame");
      errors++;
    end
    push(3000, -3000);
    expect_output(1000, -1000);

    push(4000, -4000);
    wait (out_valid);
    out_ready = 1'b0;
    repeat (4) begin
      @(negedge clk);
      if (!out_valid || $signed(out_l) != 2000 || $signed(out_r) != -2000) begin
        $error("compressor output changed under backpressure");
        errors++;
      end
    end
    out_ready = 1'b1;
    @(negedge clk);

    if (!diagnostics_o.compressor.primed ||
        diagnostics_o.compressor.delay_level_frames != 2 ||
        diagnostics_o.compressor.input_frame_count != 4 ||
        diagnostics_o.compressor.output_frame_count != 2 ||
        diagnostics_o.compressor.enabled ||
        diagnostics_o.effects.input_frame_count != 4 ||
        diagnostics_o.effects.output_frame_count != 4 ||
        diagnostics_o.effects.max_processing_cycles == 0 ||
        diagnostics_o.effects.max_processing_cycles > 96 ||
        diagnostics_o.effects.busy ||
        diagnostics_o.effects.chorus_history_level_frames != 4 ||
        diagnostics_o.effects.chorus_lfo_phase_q0_32 != 0 ||
        diagnostics_o.effects.reverb_valid_line_mask != 8'h0f ||
        diagnostics_o.effects.reverb_pre_delay_occupancy != 4 ||
        diagnostics_o.effects.reverb_max_processing_cycles > 88 ||
        diagnostics_o.effects.chorus_config_clamped ||
        diagnostics_o.effects.reverb_config_clamped ||
        diagnostics_o.effects.mixer_config_clamped ||
        diagnostics_o.effects.chorus_saturation_count != 0 ||
        diagnostics_o.effects.reverb_saturation_count != 0 ||
        diagnostics_o.effects.mixer_saturation_count != 0 ||
        diagnostics_o.compressor.saturation_count != 0 ||
        diagnostics_o.compressor.gain_reduction_cb_q12_20 != 0 ||
        diagnostics_o.compressor.target_gain_reduction_cb_q12_20 != 0 ||
        diagnostics_o.compressor.detector_peak != 4000 ||
        diagnostics_o.compressor.max_gain_reduction_cb_q12_20 != 0 ||
        diagnostics_o.compressor.max_detector_peak != 4000 ||
        diagnostics_o.compressor.compressed_frame_count != 0) begin
      $error("global audio effects diagnostics mismatch");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: global audio effects chain errors=%0d", errors);
    $display("PASS: global audio effects chain including compressor");
    $finish;
  end
endmodule
