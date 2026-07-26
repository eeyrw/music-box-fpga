module tb_effect_return_mixer;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic clear_i;
  chorus_config_t chorus_config_i;
  reverb_config_t reverb_config_i;
  mix_t dry_l_i;
  mix_t dry_r_i;
  mix_t chorus_wet_l_i;
  mix_t chorus_wet_r_i;
  mix_t reverb_input_l_o;
  mix_t reverb_input_r_o;
  logic reverb_input_saturated_l_o;
  logic reverb_input_saturated_r_o;
  logic reverb_input_commit_i;
  logic in_valid;
  logic in_ready;
  mix_t reverb_wet_l_i;
  mix_t reverb_wet_r_i;
  logic out_valid;
  logic out_ready;
  mix_t out_l;
  mix_t out_r;
  logic config_clamped;
  logic [31:0] saturation_count;
  int errors = 0;

  always #5 clk <= ~clk;

  effect_return_mixer dut (.*);

  task automatic reset_dut;
    begin
      rst = 1'b1;
      clear_i = 1'b0;
      chorus_config_i = '0;
      reverb_config_i = '0;
      dry_l_i = '0;
      dry_r_i = '0;
      chorus_wet_l_i = '0;
      chorus_wet_r_i = '0;
      reverb_wet_l_i = '0;
      reverb_wet_r_i = '0;
      reverb_input_commit_i = 1'b0;
      in_valid = 1'b0;
      out_ready = 1'b1;
      repeat (3) @(negedge clk);
      rst = 1'b0;
      @(negedge clk);
    end
  endtask

  task automatic accept_mix(input int expected_l, input int expected_r);
    begin
      if (!in_ready) begin
        $error("effect mixer was not ready for a new sample");
        errors++;
      end
      in_valid = 1'b1;
      @(negedge clk);
      in_valid = 1'b0;
      @(negedge clk);
      if (!out_valid || int'($signed(out_l)) != expected_l ||
          int'($signed(out_r)) != expected_r) begin
        $error("effect mix mismatch got %0d/%0d expected %0d/%0d",
               $signed(out_l), $signed(out_r), expected_l, expected_r);
        errors++;
      end
      @(negedge clk);
    end
  endtask

  initial begin
    reset_dut();

    dry_l_i = 24'sd100;
    dry_r_i = -24'sd100;
    chorus_wet_l_i = -24'sd40;
    chorus_wet_r_i = 24'sd40;
    reverb_config_i.input_send_q1_15 = 16'h7fff;
    reverb_config_i.chorus_to_reverb_q1_15 = 16'h4000;
    reverb_input_commit_i = 1'b1;
    @(negedge clk);
    reverb_input_commit_i = 1'b0;
    #1;
    if ($signed(reverb_input_l_o) != 80 ||
        $signed(reverb_input_r_o) != -80) begin
      $error("reverb route mismatch got %0d/%0d expected 80/-80",
             $signed(reverb_input_l_o), $signed(reverb_input_r_o));
      errors++;
    end

    chorus_config_i.return_gain_q1_15 = 16'h4000;
    reverb_config_i.return_gain_q1_15 = 16'h4000;
    reverb_wet_l_i = 24'sd10;
    reverb_wet_r_i = -24'sd10;
    accept_mix(85, -85);

    dry_l_i = 24'sh7fffff;
    dry_r_i = 24'sh800000;
    chorus_wet_l_i = 24'sh7fffff;
    chorus_wet_r_i = 24'sh800000;
    reverb_wet_l_i = 24'sh7fffff;
    reverb_wet_r_i = 24'sh800000;
    chorus_config_i.return_gain_q1_15 = 16'h7fff;
    reverb_config_i.return_gain_q1_15 = 16'h7fff;
    reverb_config_i.input_send_q1_15 = 16'h7fff;
    reverb_config_i.chorus_to_reverb_q1_15 = 16'h7fff;
    reverb_input_commit_i = 1'b1;
    in_valid = 1'b1;
    @(negedge clk);
    reverb_input_commit_i = 1'b0;
    in_valid = 1'b0;
    @(negedge clk);
    if (!out_valid || $signed(out_l) != 8388607 ||
        $signed(out_r) != -8388608) begin
      $error("saturated effect mix mismatch got %0d/%0d",
             $signed(out_l), $signed(out_r));
      errors++;
    end
    @(negedge clk);
    if (saturation_count != 32'd4) begin
      $error("saturation count mismatch got %0d expected 4", saturation_count);
      errors++;
    end
    if (!reverb_input_saturated_l_o || !reverb_input_saturated_r_o) begin
      $error("reverb route saturation flags missing");
      errors++;
    end
    reverb_config_i.input_send_q1_15 = 16'hffff;
    dry_l_i = 24'sd111;
    dry_r_i = -24'sd222;
    reverb_input_commit_i = 1'b1;
    @(negedge clk);
    reverb_input_commit_i = 1'b0;
    #1;
    if ($signed(reverb_input_l_o) != 8388607 ||
        $signed(reverb_input_r_o) != -8388608) begin
      $error("clamped gain route mismatch");
      errors++;
    end
    if (!config_clamped) begin
      $error("invalid mixer gain was not reported");
      errors++;
    end

    dry_l_i = 24'sd1234;
    dry_r_i = -24'sd2345;
    chorus_config_i.return_gain_q1_15 = '0;
    reverb_config_i.return_gain_q1_15 = '0;
    out_ready = 1'b0;
    in_valid = 1'b1;
    @(negedge clk);
    in_valid = 1'b0;
    @(negedge clk);
    repeat (4) begin
      @(negedge clk);
      if (!out_valid || $signed(out_l) != 1234 ||
          $signed(out_r) != -2345) begin
        $error("effect mixer output changed under backpressure");
        errors++;
      end
    end
    clear_i = 1'b1;
    @(negedge clk);
    clear_i = 1'b0;
    if (out_valid || saturation_count != 0 || config_clamped) begin
      $error("effect mixer clear mismatch");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: effect return mixer errors=%0d", errors);
    $display("PASS: effect return mixer");
    $finish;
  end
endmodule
