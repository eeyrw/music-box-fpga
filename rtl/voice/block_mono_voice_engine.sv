module block_mono_voice_engine (
  input  logic                                      clk,
  input  logic                                      rst,
  input  logic                                      start_valid,
  output logic                                      start_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      start_voice_index,
  input  logic [synth_pkg::BLOCK_FRAME_COUNT_WIDTH-1:0]
                                                    start_frame_count,
  input  synth_pkg::voice_playback_region_t         start_region,
  input  synth_pkg::voice_event_params_t            start_params,
  input  synth_pkg::volume_env_params_t             start_env_params,
  input  synth_pkg::voice_dynamic_state_t           start_dynamic,

  output logic                                      line_req_valid,
  input  logic                                      line_req_ready,
  output synth_pkg::ordered_line_req_t              line_req,
  input  logic                                      line_rsp_valid,
  output logic                                      line_rsp_ready,
  input  synth_pkg::ordered_line_rsp_t              line_rsp,

  output logic                                      contribution_valid,
  input  logic                                      contribution_ready,
  output synth_pkg::block_voice_contribution_t      contribution,

  output logic                                      result_valid,
  input  logic                                      result_ready,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]      result_voice_index,
  output synth_pkg::voice_dynamic_state_t           result_dynamic
);
  import synth_pkg::*;

  logic envelope_result_valid;
  logic envelope_result_ready;
  logic [VOICE_ID_WIDTH-1:0] envelope_result_voice_index;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] envelope_result_frame_count;
  voice_playback_region_t envelope_result_region;
  voice_event_params_t envelope_result_params;
  voice_dynamic_state_t envelope_result_dynamic;
  block_envelope_result_t envelope_result;
  logic renderer_start_ready;
  logic renderer_result_valid;
  logic renderer_result_ready;
  block_voice_dsp_result_t renderer_result;
  logic [VOICE_ID_WIDTH-1:0] renderer_result_voice_index;
  logic renderer_result_env_active;
  volume_env_state_t renderer_result_env_state;
  block_interleaved_envelope_frontend envelope (
    .clk,
    .rst,
    .start_valid,
    .start_ready,
    .start_voice_index,
    .start_frame_count,
    .start_region,
    .start_params,
    .start_env_params,
    .start_dynamic,
    .result_valid(envelope_result_valid),
    .result_ready(envelope_result_ready),
    .result_voice_index(envelope_result_voice_index),
    .result_frame_count(envelope_result_frame_count),
    .result_region(envelope_result_region),
    .result_params(envelope_result_params),
    .result_dynamic(envelope_result_dynamic),
    .result_envelope(envelope_result)
  );

  block_interleaved_voice_renderer renderer (
    .clk,
    .rst,
    .start_valid(envelope_result_valid),
    .start_ready(renderer_start_ready),
    .start_voice_index(envelope_result_voice_index),
    .start_frame_count(envelope_result_frame_count),
    .start_phase_advance_mask(envelope_result.phase_advance_mask),
    .start_render_mask(envelope_result.render_mask),
    .start_envelope_levels(envelope_result.envelope_levels),
    .start_active(envelope_result_dynamic.active),
    .start_generation(envelope_result_dynamic.generation),
    .start_phase(envelope_result_dynamic.phase),
    .start_region(envelope_result_region),
    .start_params(envelope_result_params),
    .start_filter_z1(envelope_result_dynamic.filter_z1),
    .start_filter_z2(envelope_result_dynamic.filter_z2),
    .start_env_active(envelope_result.active),
    .start_env_state(envelope_result.env_state),
    .line_req_valid,
    .line_req_ready,
    .line_req,
    .line_rsp_valid,
    .line_rsp_ready,
    .line_rsp,
    .contribution_valid,
    .contribution_ready,
    .contribution,
    .result_valid(renderer_result_valid),
    .result_ready(renderer_result_ready),
    .result(renderer_result),
    .result_voice_index(renderer_result_voice_index),
    .result_env_active(renderer_result_env_active),
    .result_env_state(renderer_result_env_state)
  );

  assign envelope_result_ready = renderer_start_ready;
  assign result_valid = renderer_result_valid;
  assign renderer_result_ready = result_ready;
  assign result_voice_index = renderer_result_voice_index;

  always_comb begin
    result_dynamic = '0;
    result_dynamic.active = renderer_result.phase_result.active &&
                            renderer_result_env_active;
    result_dynamic.generation = renderer_result.phase_result.generation;
    result_dynamic.phase = renderer_result.phase_result.phase;
    result_dynamic.env_state = renderer_result_env_state;
    result_dynamic.filter_z1 = renderer_result.filter_z1;
    result_dynamic.filter_z2 = renderer_result.filter_z2;
  end
endmodule
