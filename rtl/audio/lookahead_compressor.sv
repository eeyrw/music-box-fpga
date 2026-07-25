module lookahead_compressor #(
  parameter int LOOKAHEAD_FRAMES = 48
) (
  input  logic                          clk,
  input  logic                          rst,
  input  synth_pkg::compressor_config_t config_i,
  input  logic signed [15:0]             master_volume_i,
  input  logic                          in_valid,
  output logic                          in_ready,
  input  synth_pkg::mix_t               in_l,
  input  synth_pkg::mix_t               in_r,
  output logic                          out_valid,
  input  logic                          out_ready,
  output synth_pkg::pcm_t               out_l,
  output synth_pkg::pcm_t               out_r,
  output logic                          enabled,
  output logic                          primed,
  output logic [15:0]                   delay_level_frames,
  output logic [31:0]                   gain_reduction_cb_q12_20,
  output logic [31:0]                   target_gain_reduction_cb_q12_20,
  output logic [synth_pkg::MIX_WIDTH-1:0] detector_peak,
  output logic [31:0]                   max_gain_reduction_cb_q12_20,
  output logic [synth_pkg::MIX_WIDTH-1:0] max_detector_peak,
  output logic [31:0]                   input_frame_count,
  output logic [31:0]                   output_frame_count,
  output logic [31:0]                   compressed_frame_count,
  output logic [31:0]                   saturation_count
);
  import synth_pkg::*;
  import synth_dsp_lut_pkg::*;

  localparam int DELAY_PTR_WIDTH = (LOOKAHEAD_FRAMES <= 1) ? 1 :
                                   $clog2(LOOKAHEAD_FRAMES);
  localparam int DELAY_LEVEL_WIDTH = $clog2(LOOKAHEAD_FRAMES + 1);

  typedef enum logic [2:0] {IDLE, CALC_LEVEL, LOOKUP_GAIN, SCALE, HOLD} state_t;
  state_t state;

  (* ram_style = "distributed" *) stereo_mix_t delay_line [0:LOOKAHEAD_FRAMES-1];
  logic [DELAY_PTR_WIDTH-1:0] delay_ptr;
  logic [DELAY_LEVEL_WIDTH-1:0] delay_level;
  stereo_mix_t delayed_sample;
  logic delayed_valid;
  compressor_config_t config_q;
  logic signed [15:0] master_volume_q;
  logic magnitude_zero_q;
  logic [MIX_WIDTH-1:0] peak_magnitude_q;
  logic [4:0] magnitude_exponent_q;
  logic [7:0] magnitude_mantissa_index_q;
  logic [4:0] gain_octave_q;
  logic [23:0] gain_mantissa_q;

  logic [MIX_WIDTH-1:0] magnitude_l;
  logic [MIX_WIDTH-1:0] magnitude_r;
  logic [MIX_WIDTH-1:0] peak_magnitude;
  logic magnitude_zero;
  logic [4:0] magnitude_exponent;
  logic [31:0] normalized_magnitude;
  logic [7:0] magnitude_mantissa_index;
  logic signed [32:0] level_cb_q12_20;
  logic signed [33:0] over_threshold_cb_q12_20;
  logic [47:0] target_product;
  logic [31:0] target_gain_reduction;
  logic [31:0] next_gain_reduction;
  logic [4:0] gain_octave;
  logic [31:0] gain_residual;
  logic [32:0] gain_rounded_residual;
  logic [6:0] gain_mantissa_index;
  logic signed [15:0] compressor_gain;
  logic signed [39:0] compressor_product_l;
  logic signed [39:0] compressor_product_r;
  logic signed [39:0] master_product_l;
  logic signed [39:0] master_product_r;
  logic signed [55:0] combined_product_l;
  logic signed [55:0] combined_product_r;
  logic signed [55:0] scaled_output_l;
  logic signed [55:0] scaled_output_r;
  logic output_saturated_l;
  logic output_saturated_r;

  initial begin
    if (LOOKAHEAD_FRAMES < 1)
      $error("LOOKAHEAD_FRAMES must be positive");
  end

  function automatic logic [MIX_WIDTH-1:0] abs_mix(input mix_t value);
    if (value[MIX_WIDTH-1])
      abs_mix = (~$unsigned(value)) + MIX_WIDTH'(1);
    else
      abs_mix = $unsigned(value);
  endfunction

  function automatic pcm_t saturate_pcm(input logic signed [55:0] value);
    if (value > 56'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -56'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  function automatic logic signed [15:0] mantissa_to_q15(
    input logic [23:0] mantissa,
    input logic [4:0] octave
  );
    logic [23:0] shifted;
    logic [24:0] rounded;
    begin
      shifted = mantissa >> octave;
      rounded = {1'b0, shifted} +
                25'(1 << (COMP_CB_TO_Q15_GUARD_BITS - 1));
      mantissa_to_q15 = $signed(16'(rounded >> 8));
    end
  endfunction

  function automatic logic [31:0] sat_inc(input logic [31:0] value);
    sat_inc = (value == 32'hffff_ffff) ? value : value + 32'd1;
  endfunction

  function automatic logic [31:0] sat_add_two(input logic [31:0] value);
    sat_add_two = (value >= 32'hffff_fffe) ? 32'hffff_ffff : value + 32'd2;
  endfunction

  assign in_ready = (state == IDLE) && !out_valid;
  assign enabled = config_i.enable;
  assign primed = delay_level == DELAY_LEVEL_WIDTH'(LOOKAHEAD_FRAMES);
  assign delay_level_frames = 16'(delay_level);

  always_comb begin
    magnitude_l = abs_mix(in_l);
    magnitude_r = abs_mix(in_r);
    peak_magnitude = (magnitude_l >= magnitude_r) ? magnitude_l : magnitude_r;
    magnitude_zero = peak_magnitude == '0;
    magnitude_exponent = '0;
    for (int bit_index = MIX_WIDTH-1; bit_index >= 0; bit_index--) begin
      if ((magnitude_exponent == '0) && peak_magnitude[bit_index])
        magnitude_exponent = 5'(bit_index);
    end
    normalized_magnitude = magnitude_zero ? 32'd0 :
        (32'(peak_magnitude) << (31 - magnitude_exponent));
    magnitude_mantissa_index = 8'(
        ((normalized_magnitude >> COMP_MAG_TO_CB_INDEX_SHIFT) &
         ((1 << COMP_MAG_TO_CB_MANTISSA_BITS) - 1)) +
        32'(normalized_magnitude[COMP_MAG_TO_CB_ROUND_BIT]));

    level_cb_q12_20 = -33'sd2147483648;
    if (!magnitude_zero_q) begin
      if (magnitude_exponent_q >= 5'(COMP_MAG_TO_CB_REFERENCE_EXPONENT)) begin
        level_cb_q12_20 = $signed({1'b0,
            COMP_CB_OCTAVE_Q12_20_LUT[magnitude_exponent_q -
                                      5'(COMP_MAG_TO_CB_REFERENCE_EXPONENT)]}) +
            $signed({7'd0, COMP_MAG_TO_CB_MANTISSA_LUT[magnitude_mantissa_index_q]});
      end else begin
        level_cb_q12_20 =
            -$signed({1'b0, COMP_CB_OCTAVE_Q12_20_LUT[
                5'(COMP_MAG_TO_CB_REFERENCE_EXPONENT) - magnitude_exponent_q]}) +
            $signed({7'd0, COMP_MAG_TO_CB_MANTISSA_LUT[magnitude_mantissa_index_q]});
      end
    end

    over_threshold_cb_q12_20 =
        {{1{level_cb_q12_20[32]}}, level_cb_q12_20} +
        $signed({2'b00, config_q.threshold_cb_q12_20});
    target_product = 48'd0;
    target_gain_reduction = 32'd0;
    if (config_q.enable && !magnitude_zero_q &&
        !over_threshold_cb_q12_20[33] && (over_threshold_cb_q12_20 != '0)) begin
      target_product = $unsigned(over_threshold_cb_q12_20[31:0]) *
                       config_q.ratio_slope_q0_16;
      target_gain_reduction = 32'(target_product >> 16);
    end

    next_gain_reduction = gain_reduction_cb_q12_20;
    if (!config_q.enable) begin
      next_gain_reduction = 32'd0;
    end else if (target_gain_reduction > gain_reduction_cb_q12_20) begin
      if ((config_q.attack_step_cb_q12_20 == '0) ||
          ((target_gain_reduction - gain_reduction_cb_q12_20) <=
           config_q.attack_step_cb_q12_20))
        next_gain_reduction = target_gain_reduction;
      else
        next_gain_reduction = gain_reduction_cb_q12_20 +
                              config_q.attack_step_cb_q12_20;
    end else if (target_gain_reduction < gain_reduction_cb_q12_20) begin
      if ((config_q.release_step_cb_q12_20 == '0) ||
          ((gain_reduction_cb_q12_20 - target_gain_reduction) <=
           config_q.release_step_cb_q12_20))
        next_gain_reduction = target_gain_reduction;
      else
        next_gain_reduction = gain_reduction_cb_q12_20 -
                              config_q.release_step_cb_q12_20;
    end

    gain_octave = '0;
    if (gain_reduction_cb_q12_20 >= COMP_CB_OCTAVE_Q12_20_LUT[16]) begin
      gain_octave = 5'd16;
    end else begin
      if (gain_reduction_cb_q12_20 >= COMP_CB_OCTAVE_Q12_20_LUT[8])
        gain_octave = 5'd8;
      if (gain_reduction_cb_q12_20 >=
          COMP_CB_OCTAVE_Q12_20_LUT[gain_octave + 5'd4])
        gain_octave = gain_octave + 5'd4;
      if (gain_reduction_cb_q12_20 >=
          COMP_CB_OCTAVE_Q12_20_LUT[gain_octave + 5'd2])
        gain_octave = gain_octave + 5'd2;
      if (gain_reduction_cb_q12_20 >=
          COMP_CB_OCTAVE_Q12_20_LUT[gain_octave + 5'd1])
        gain_octave = gain_octave + 5'd1;
    end
    gain_residual = gain_reduction_cb_q12_20 -
                    COMP_CB_OCTAVE_Q12_20_LUT[gain_octave];
    gain_rounded_residual = {1'b0, gain_residual} +
        33'(1 << (COMP_CB_TO_Q15_RESIDUAL_INDEX_SHIFT - 1));
    gain_mantissa_index = 7'(
        gain_rounded_residual >> COMP_CB_TO_Q15_RESIDUAL_INDEX_SHIFT);

    compressor_gain = mantissa_to_q15(gain_mantissa_q, gain_octave_q);
    compressor_product_l = delayed_sample.l * compressor_gain;
    compressor_product_r = delayed_sample.r * compressor_gain;
    master_product_l = delayed_sample.l * master_volume_q;
    master_product_r = delayed_sample.r * master_volume_q;
    combined_product_l = compressor_product_l * master_volume_q;
    combined_product_r = compressor_product_r * master_volume_q;

    if ((!config_q.enable || (gain_reduction_cb_q12_20 == '0)) &&
        (master_volume_q == 16'sh7fff)) begin
      scaled_output_l = {{(56-MIX_WIDTH){delayed_sample.l[MIX_WIDTH-1]}},
                         delayed_sample.l};
      scaled_output_r = {{(56-MIX_WIDTH){delayed_sample.r[MIX_WIDTH-1]}},
                         delayed_sample.r};
    end else if (!config_q.enable || (gain_reduction_cb_q12_20 == '0)) begin
      scaled_output_l = $signed({{16{master_product_l[39]}}, master_product_l}) >>> 15;
      scaled_output_r = $signed({{16{master_product_r[39]}}, master_product_r}) >>> 15;
    end else if (master_volume_q == 16'sh7fff) begin
      scaled_output_l =
          $signed({{16{compressor_product_l[39]}}, compressor_product_l}) >>> 15;
      scaled_output_r =
          $signed({{16{compressor_product_r[39]}}, compressor_product_r}) >>> 15;
    end else begin
      scaled_output_l = combined_product_l >>> 30;
      scaled_output_r = combined_product_r >>> 30;
    end
    output_saturated_l = (scaled_output_l > 56'sd32767) ||
                         (scaled_output_l < -56'sd32768);
    output_saturated_r = (scaled_output_r > 56'sd32767) ||
                         (scaled_output_r < -56'sd32768);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      delay_ptr <= '0;
      delay_level <= '0;
      delayed_sample <= '0;
      delayed_valid <= 1'b0;
      config_q <= '0;
      master_volume_q <= 16'sh7fff;
      magnitude_zero_q <= 1'b1;
      peak_magnitude_q <= '0;
      magnitude_exponent_q <= '0;
      magnitude_mantissa_index_q <= '0;
      gain_octave_q <= '0;
      gain_mantissa_q <= '0;
      gain_reduction_cb_q12_20 <= '0;
      target_gain_reduction_cb_q12_20 <= '0;
      detector_peak <= '0;
      max_gain_reduction_cb_q12_20 <= '0;
      max_detector_peak <= '0;
      input_frame_count <= '0;
      output_frame_count <= '0;
      compressed_frame_count <= '0;
      saturation_count <= '0;
      out_valid <= 1'b0;
      out_l <= '0;
      out_r <= '0;
    end else begin
      unique case (state)
        IDLE: begin
          if (in_valid && in_ready) begin
            delayed_sample <= delay_line[delay_ptr];
            delayed_valid <= primed;
            delay_line[delay_ptr].l <= in_l;
            delay_line[delay_ptr].r <= in_r;
            if (delay_ptr == DELAY_PTR_WIDTH'(LOOKAHEAD_FRAMES - 1))
              delay_ptr <= '0;
            else
              delay_ptr <= delay_ptr + 1'b1;
            if (!primed)
              delay_level <= delay_level + 1'b1;
            config_q <= config_i;
            master_volume_q <= master_volume_i;
            magnitude_zero_q <= magnitude_zero;
            peak_magnitude_q <= peak_magnitude;
            magnitude_exponent_q <= magnitude_exponent;
            magnitude_mantissa_index_q <= magnitude_mantissa_index;
            if (peak_magnitude > max_detector_peak)
              max_detector_peak <= peak_magnitude;
            input_frame_count <= sat_inc(input_frame_count);
            state <= CALC_LEVEL;
          end
        end
        CALC_LEVEL: begin
          gain_reduction_cb_q12_20 <= next_gain_reduction;
          target_gain_reduction_cb_q12_20 <= target_gain_reduction;
          detector_peak <= peak_magnitude_q;
          if (next_gain_reduction > max_gain_reduction_cb_q12_20)
            max_gain_reduction_cb_q12_20 <= next_gain_reduction;
          state <= LOOKUP_GAIN;
        end
        LOOKUP_GAIN: begin
          gain_octave_q <= gain_octave;
          gain_mantissa_q <= (gain_reduction_cb_q12_20 >=
                              COMP_CB_SILENCE_Q12_20) ? 24'd0 :
              COMP_CB_TO_Q15_MANTISSA_LUT[gain_mantissa_index];
          state <= SCALE;
        end
        SCALE: begin
          if (delayed_valid) begin
            out_l <= saturate_pcm(scaled_output_l);
            out_r <= saturate_pcm(scaled_output_r);
            output_frame_count <= sat_inc(output_frame_count);
            if (config_q.enable && (gain_reduction_cb_q12_20 != '0))
              compressed_frame_count <= sat_inc(compressed_frame_count);
            unique case ({output_saturated_l, output_saturated_r})
              2'b01, 2'b10: saturation_count <= sat_inc(saturation_count);
              2'b11: saturation_count <= sat_add_two(saturation_count);
              default: begin end
            endcase
            out_valid <= 1'b1;
            state <= HOLD;
          end else begin
            state <= IDLE;
          end
        end
        HOLD: begin
          if (out_valid && out_ready) begin
            out_valid <= 1'b0;
            state <= IDLE;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
