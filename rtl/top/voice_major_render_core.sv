module voice_major_render_core #(
  parameter int CACHE_SET_COUNT = 512,
  parameter int MSHR_DEPTH = 8
) (
  input  logic                                      clk,
  input  logic                                      rst,

  input  logic                                      install_valid,
  output logic                                      install_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      install_voice,
  input  synth_pkg::block_voice_state_snapshot_t   install_state,
  input  logic                                      params_write_valid,
  output logic                                      params_write_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      params_write_voice,
  input  logic [synth_pkg::VOICE_GENERATION_WIDTH-1:0]
                                                    params_write_generation,
  input  synth_pkg::voice_event_params_t            params_write_event,
  input  synth_pkg::volume_env_params_t             params_write_env,
  output logic                                      stale_params_write_pulse,
  output logic                                      stale_dynamic_write_pulse,

  input  logic                                      block_req_valid,
  output logic                                      block_req_ready,
  input  synth_pkg::render_block_req_t              block_req,
  output logic                                      render_busy,

  output logic                                      line_req_valid,
  input  logic                                      line_req_ready,
  output synth_pkg::ordered_line_req_t              line_req,
  input  logic                                      line_rsp_valid,
  output logic                                      line_rsp_ready,
  input  synth_pkg::ordered_line_rsp_t              line_rsp,

  output logic                                      block_complete_valid,
  input  logic                                      block_complete_ready,
  output synth_pkg::render_block_complete_t         block_complete,
  input  logic                                      block_read_req_valid,
  output logic                                      block_read_req_ready,
  input  synth_pkg::render_block_read_req_t         block_read_req,
  output logic                                      block_read_rsp_valid,
  input  logic                                      block_read_rsp_ready,
  output synth_pkg::render_block_read_rsp_t         block_read_rsp,
  input  logic                                      block_release_valid,
  output logic                                      block_release_ready,
  input  logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                    block_release_buffer_id
);
  import synth_pkg::*;

  logic [NUM_VOICES-1:0] active_bitmap;
  logic state_read_req_valid;
  logic state_read_req_ready;
  logic [VOICE_ID_WIDTH-1:0] state_read_req_voice;
  logic state_read_rsp_valid;
  logic state_read_rsp_ready;
  block_voice_state_snapshot_t state_read_rsp;
  logic dynamic_write_valid;
  logic dynamic_write_ready;
  logic [VOICE_ID_WIDTH-1:0] dynamic_write_voice;
  voice_dynamic_state_t dynamic_write_data;

  block_voice_state_store state_store (
    .clk,
    .rst,
    .render_busy,
    .install_valid,
    .install_ready,
    .install_voice,
    .install_state,
    .params_write_valid,
    .params_write_ready,
    .params_write_voice,
    .params_write_generation,
    .params_write_event,
    .params_write_env,
    .control_event_valid(1'b0),
    .control_event_ready(),
    .control_event('0),
    .control_event_done_pulse(),
    .stale_control_event_pulse(),
    .state_read_req_valid,
    .state_read_req_ready,
    .state_read_req_voice,
    .state_read_rsp_valid,
    .state_read_rsp_ready,
    .state_read_rsp,
    .dynamic_write_valid,
    .dynamic_write_ready,
    .dynamic_write_voice,
    .dynamic_write_data,
    .active_bitmap,
    .stale_params_write_pulse,
    .stale_dynamic_write_pulse
  );

  voice_major_block_controller #(
    .CACHE_SET_COUNT(CACHE_SET_COUNT),
    .MSHR_DEPTH(MSHR_DEPTH)
  ) controller (
    .clk,
    .rst,
    .block_req_valid,
    .block_req_ready,
    .block_req,
    .active_bitmap,
    .render_busy,
    .state_read_req_valid,
    .state_read_req_ready,
    .state_read_req_voice,
    .state_read_rsp_valid,
    .state_read_rsp_ready,
    .state_read_rsp,
    .dynamic_write_valid,
    .dynamic_write_ready,
    .dynamic_write_voice,
    .dynamic_write_data,
    .line_req_valid,
    .line_req_ready,
    .line_req,
    .line_rsp_valid,
    .line_rsp_ready,
    .line_rsp,
    .block_complete_valid,
    .block_complete_ready,
    .block_complete,
    .block_read_req_valid,
    .block_read_req_ready,
    .block_read_req,
    .block_read_rsp_valid,
    .block_read_rsp_ready,
    .block_read_rsp,
    .block_release_valid,
    .block_release_ready,
    .block_release_buffer_id
  );
endmodule
