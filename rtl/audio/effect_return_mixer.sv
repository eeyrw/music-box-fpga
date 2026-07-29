module effect_return_mixer (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       clear_i,
  /* verilator lint_off UNUSEDSIGNAL */
  input  synth_pkg::chorus_config_t  chorus_config_i,
  input  synth_pkg::reverb_config_t  reverb_config_i,
  /* verilator lint_on UNUSEDSIGNAL */
  input  synth_pkg::mix_t            dry_l_i,
  input  synth_pkg::mix_t            dry_r_i,
  input  synth_pkg::mix_t            chorus_wet_l_i,
  input  synth_pkg::mix_t            chorus_wet_r_i,
  output synth_pkg::mix_t            reverb_input_l_o,
  output synth_pkg::mix_t            reverb_input_r_o,
  output logic                       reverb_input_saturated_l_o,
  output logic                       reverb_input_saturated_r_o,
  input  logic                       reverb_input_commit_i,
  input  logic                       in_valid,
  output logic                       in_ready,
  input  synth_pkg::mix_t            reverb_wet_l_i,
  input  synth_pkg::mix_t            reverb_wet_r_i,
  output logic                       out_valid,
  input  logic                       out_ready,
  output synth_pkg::mix_t            out_l,
  output synth_pkg::mix_t            out_r,
  output logic                       config_clamped,
  output logic [31:0]                saturation_count
);
  import synth_pkg::*;

  logic signed [47:0] reverb_dry_scaled_l;
  logic signed [47:0] reverb_dry_scaled_r;
  logic signed [47:0] chorus_route_scaled_l;
  logic signed [47:0] chorus_route_scaled_r;
  logic signed [47:0] reverb_dry_scaled_l_q;
  logic signed [47:0] reverb_dry_scaled_r_q;
  logic signed [47:0] chorus_route_scaled_l_q;
  logic signed [47:0] chorus_route_scaled_r_q;
  logic signed [49:0] reverb_input_wide_l;
  logic signed [49:0] reverb_input_wide_r;
  logic signed [47:0] chorus_return_scaled_l;
  logic signed [47:0] chorus_return_scaled_r;
  logic signed [47:0] reverb_return_scaled_l;
  logic signed [47:0] reverb_return_scaled_r;
  logic signed [49:0] effect_mix_wide_l;
  logic signed [49:0] effect_mix_wide_r;
  logic effect_stage_valid;
  logic signed [49:0] effect_mix_wide_l_q;
  logic signed [49:0] effect_mix_wide_r_q;
  logic output_slot_ready;
  logic reverb_event_pending_q;
  logic [2:0] diagnostic_events;

  function automatic logic signed [47:0] scale_q1_15(
    input mix_t sample,
    input logic [15:0] gain
  );
    logic signed [41:0] product;
    begin
      product = sample * $signed({1'b0, gain});
      if (gain >= 16'h7fff)
        scale_q1_15 = {{23{sample[MIX_WIDTH-1]}}, sample};
      else
        scale_q1_15 = $signed({{6{product[41]}}, product}) >>> 15;
    end
  endfunction

  function automatic mix_t saturate_mix(input logic signed [49:0] value);
    if (value > 50'sd16777215)
      saturate_mix = 25'sh0ffffff;
    else if (value < -50'sd16777216)
      saturate_mix = 25'sh1000000;
    else
      saturate_mix = mix_t'(value);
  endfunction

  function automatic logic [31:0] sat_add(
    input logic [31:0] value,
    input logic [2:0] amount
  );
    logic [32:0] sum;
    begin
      sum = {1'b0, value} + 33'(amount);
      sat_add = sum[32] ? 32'hffff_ffff : sum[31:0];
    end
  endfunction

  assign output_slot_ready = !out_valid || out_ready;
  assign in_ready = !effect_stage_valid || output_slot_ready;

  always_comb begin
    reverb_dry_scaled_l = scale_q1_15(dry_l_i, reverb_config_i.input_send_q1_15);
    reverb_dry_scaled_r = scale_q1_15(dry_r_i, reverb_config_i.input_send_q1_15);
    chorus_route_scaled_l = scale_q1_15(
        chorus_wet_l_i, reverb_config_i.chorus_to_reverb_q1_15);
    chorus_route_scaled_r = scale_q1_15(
        chorus_wet_r_i, reverb_config_i.chorus_to_reverb_q1_15);
    reverb_input_wide_l = $signed({{2{reverb_dry_scaled_l_q[47]}},
                                   reverb_dry_scaled_l_q}) +
                          $signed({{2{chorus_route_scaled_l_q[47]}},
                                   chorus_route_scaled_l_q});
    reverb_input_wide_r = $signed({{2{reverb_dry_scaled_r_q[47]}},
                                   reverb_dry_scaled_r_q}) +
                          $signed({{2{chorus_route_scaled_r_q[47]}},
                                   chorus_route_scaled_r_q});
    reverb_input_l_o = saturate_mix(reverb_input_wide_l);
    reverb_input_r_o = saturate_mix(reverb_input_wide_r);
    reverb_input_saturated_l_o = (reverb_input_wide_l > 50'sd16777215) ||
                                 (reverb_input_wide_l < -50'sd16777216);
    reverb_input_saturated_r_o = (reverb_input_wide_r > 50'sd16777215) ||
                                 (reverb_input_wide_r < -50'sd16777216);

    chorus_return_scaled_l = scale_q1_15(
        chorus_wet_l_i, chorus_config_i.return_gain_q1_15);
    chorus_return_scaled_r = scale_q1_15(
        chorus_wet_r_i, chorus_config_i.return_gain_q1_15);
    reverb_return_scaled_l = scale_q1_15(
        reverb_wet_l_i, reverb_config_i.return_gain_q1_15);
    reverb_return_scaled_r = scale_q1_15(
        reverb_wet_r_i, reverb_config_i.return_gain_q1_15);
    effect_mix_wide_l = $signed({{25{dry_l_i[MIX_WIDTH-1]}}, dry_l_i}) +
                        $signed({{2{chorus_return_scaled_l[47]}},
                                 chorus_return_scaled_l}) +
                        $signed({{2{reverb_return_scaled_l[47]}},
                                 reverb_return_scaled_l});
    effect_mix_wide_r = $signed({{25{dry_r_i[MIX_WIDTH-1]}}, dry_r_i}) +
                        $signed({{2{chorus_return_scaled_r[47]}},
                                 chorus_return_scaled_r}) +
                        $signed({{2{reverb_return_scaled_r[47]}},
                                 reverb_return_scaled_r});
    diagnostic_events = 3'd0;
    if (reverb_event_pending_q)
      diagnostic_events = diagnostic_events +
          {2'd0, ((reverb_input_wide_l > 50'sd16777215) ||
                  (reverb_input_wide_l < -50'sd16777216))} +
          {2'd0, ((reverb_input_wide_r > 50'sd16777215) ||
                  (reverb_input_wide_r < -50'sd16777216))};
    if (effect_stage_valid && output_slot_ready)
      diagnostic_events = diagnostic_events +
          {2'd0, ((effect_mix_wide_l_q > 50'sd16777215) ||
                  (effect_mix_wide_l_q < -50'sd16777216))} +
          {2'd0, ((effect_mix_wide_r_q > 50'sd16777215) ||
                  (effect_mix_wide_r_q < -50'sd16777216))};
  end

  always_ff @(posedge clk) begin
    if (rst || clear_i) begin
      out_valid <= 1'b0;
      out_l <= '0;
      out_r <= '0;
      effect_stage_valid <= 1'b0;
      effect_mix_wide_l_q <= '0;
      effect_mix_wide_r_q <= '0;
      reverb_event_pending_q <= 1'b0;
      reverb_dry_scaled_l_q <= '0;
      reverb_dry_scaled_r_q <= '0;
      chorus_route_scaled_l_q <= '0;
      chorus_route_scaled_r_q <= '0;
      config_clamped <= 1'b0;
      saturation_count <= '0;
    end else begin
      if (output_slot_ready) begin
        if (effect_stage_valid) begin
          out_l <= saturate_mix(effect_mix_wide_l_q);
          out_r <= saturate_mix(effect_mix_wide_r_q);
          out_valid <= 1'b1;
        end else begin
          out_valid <= 1'b0;
        end
      end
      if (in_valid && in_ready) begin
        effect_mix_wide_l_q <= effect_mix_wide_l;
        effect_mix_wide_r_q <= effect_mix_wide_r;
        effect_stage_valid <= 1'b1;
      end else if (output_slot_ready) begin
        effect_stage_valid <= 1'b0;
      end
      reverb_event_pending_q <= reverb_input_commit_i;
      if (reverb_input_commit_i) begin
        reverb_dry_scaled_l_q <= reverb_dry_scaled_l;
        reverb_dry_scaled_r_q <= reverb_dry_scaled_r;
        chorus_route_scaled_l_q <= chorus_route_scaled_l;
        chorus_route_scaled_r_q <= chorus_route_scaled_r;
      end
      if (diagnostic_events != 0)
        saturation_count <= sat_add(saturation_count, diagnostic_events);
      if ((reverb_input_commit_i &&
           (reverb_config_i.input_send_q1_15 > 16'h7fff ||
            reverb_config_i.chorus_to_reverb_q1_15 > 16'h7fff)) ||
          (in_valid && in_ready &&
           (chorus_config_i.return_gain_q1_15 > 16'h7fff ||
            reverb_config_i.return_gain_q1_15 > 16'h7fff)))
        config_clamped <= 1'b1;
    end
  end
endmodule
