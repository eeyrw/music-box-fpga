module global_audio_effects_chain #(
  parameter int CHORUS_DELAY_CAPACITY = 2048,
  parameter int REVERB_PRE_DELAY_CAPACITY = 2048,
  parameter int REVERB_LINE_LENGTH_0 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[0]),
  parameter int REVERB_LINE_LENGTH_1 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[1]),
  parameter int REVERB_LINE_LENGTH_2 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[2]),
  parameter int REVERB_LINE_LENGTH_3 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[3]),
  parameter int REVERB_LINE_LENGTH_4 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[4]),
  parameter int REVERB_LINE_LENGTH_5 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[5]),
  parameter int REVERB_LINE_LENGTH_6 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[6]),
  parameter int REVERB_LINE_LENGTH_7 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[7]),
  parameter int COMPRESSOR_LOOKAHEAD_FRAMES = 48
) (
  input  logic                          clk,
  input  logic                          rst,
  input  logic [1:0]                    effect_clear_i,
  input  synth_pkg::global_audio_config_t config_i,
  input  logic                          in_valid,
  output logic                          in_ready,
  input  synth_pkg::mix_t               in_l,
  input  synth_pkg::mix_t               in_r,
  output logic                          out_valid,
  input  logic                          out_ready,
  output synth_pkg::pcm_t               out_l,
  output synth_pkg::pcm_t               out_r,
  output logic                          busy,
  output synth_pkg::audio_diagnostics_t diagnostics_o
);
  import synth_pkg::*;

  logic spatial_out_valid;
  logic spatial_out_ready;
  mix_t spatial_out_l;
  mix_t spatial_out_r;

  assign busy = diagnostics_o.effects.busy || !spatial_out_ready;

  global_effects_chain #(
    .CHORUS_DELAY_CAPACITY(CHORUS_DELAY_CAPACITY),
    .REVERB_PRE_DELAY_CAPACITY(REVERB_PRE_DELAY_CAPACITY),
    .REVERB_LINE_LENGTH_0(REVERB_LINE_LENGTH_0),
    .REVERB_LINE_LENGTH_1(REVERB_LINE_LENGTH_1),
    .REVERB_LINE_LENGTH_2(REVERB_LINE_LENGTH_2),
    .REVERB_LINE_LENGTH_3(REVERB_LINE_LENGTH_3),
    .REVERB_LINE_LENGTH_4(REVERB_LINE_LENGTH_4),
    .REVERB_LINE_LENGTH_5(REVERB_LINE_LENGTH_5),
    .REVERB_LINE_LENGTH_6(REVERB_LINE_LENGTH_6),
    .REVERB_LINE_LENGTH_7(REVERB_LINE_LENGTH_7)
  ) spatial_effects (
    .clk,
    .rst,
    .clear_i(effect_clear_i),
    .chorus_config_i(config_i.chorus),
    .reverb_config_i(config_i.reverb),
    .in_valid,
    .in_ready,
    .in_l,
    .in_r,
    .out_valid(spatial_out_valid),
    .out_ready(spatial_out_ready),
    .out_l(spatial_out_l),
    .out_r(spatial_out_r),
    .diagnostics_o(diagnostics_o.effects)
  );

  lookahead_compressor #(
    .LOOKAHEAD_FRAMES(COMPRESSOR_LOOKAHEAD_FRAMES)
  ) compressor (
    .clk,
    .rst,
    .config_i(config_i.compressor),
    .master_volume_i(config_i.master_volume),
    .in_valid(spatial_out_valid),
    .in_ready(spatial_out_ready),
    .in_l(spatial_out_l),
    .in_r(spatial_out_r),
    .out_valid,
    .out_ready,
    .out_l,
    .out_r,
    .enabled(diagnostics_o.compressor.enabled),
    .primed(diagnostics_o.compressor.primed),
    .delay_level_frames(diagnostics_o.compressor.delay_level_frames),
    .gain_reduction_cb_q12_20(
        diagnostics_o.compressor.gain_reduction_cb_q12_20),
    .target_gain_reduction_cb_q12_20(
        diagnostics_o.compressor.target_gain_reduction_cb_q12_20),
    .detector_peak(diagnostics_o.compressor.detector_peak),
    .max_gain_reduction_cb_q12_20(
        diagnostics_o.compressor.max_gain_reduction_cb_q12_20),
    .max_detector_peak(diagnostics_o.compressor.max_detector_peak),
    .input_frame_count(diagnostics_o.compressor.input_frame_count),
    .output_frame_count(diagnostics_o.compressor.output_frame_count),
    .compressed_frame_count(diagnostics_o.compressor.compressed_frame_count),
    .saturation_count(diagnostics_o.compressor.saturation_count)
  );
endmodule
