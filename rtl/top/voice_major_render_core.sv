module voice_major_render_core (
  input  logic                                      clk,
  input  logic                                      rst,

  input  synth_pkg::reg_bus_req_t                   bus_req,
  output synth_pkg::reg_bus_rsp_t                   bus_rsp,
  input  logic                                      cmd_stream_valid,
  input  logic [31:0]                               cmd_stream_data,
  output logic                                      cmd_stream_ready,
  output logic [31:0]                               command_error_count,
  output logic [31:0]                               stale_generation_count,

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
  logic command_install_valid;
  logic command_install_ready;
  logic [VOICE_ID_WIDTH-1:0] command_install_voice;
  block_voice_state_snapshot_t command_install_state;
  logic command_control_event_valid;
  logic command_control_event_ready;
  block_voice_event_t command_control_event;
  logic command_control_event_done;
  logic stale_control_event;
  logic stale_params_write;
  logic stale_dynamic_write;
  logic [$clog2(1024+1)-1:0] command_word_level;
  logic command_action_pending;
  logic [TIMELINE_FRAME_WIDTH-1:0] current_frame_q;
  logic controller_block_req_ready;

  voice_major_command_plane command_plane (
    .clk,
    .rst,
    .bus_req,
    .bus_rsp,
    .cmd_stream_valid,
    .cmd_stream_data,
    .cmd_stream_ready,
    .render_busy,
    .current_frame(current_frame_q),
    .install_valid(command_install_valid),
    .install_ready(command_install_ready),
    .install_voice(command_install_voice),
    .install_state(command_install_state),
    .control_event_valid(command_control_event_valid),
    .control_event_ready(command_control_event_ready),
    .control_event(command_control_event),
    .control_event_done_pulse(command_control_event_done),
    .stale_control_event_pulse(stale_control_event),
    .command_error_count,
    .stale_generation_count,
    .word_level(command_word_level),
    .action_pending(command_action_pending)
  );

  block_voice_state_store state_store (
    .clk,
    .rst,
    .render_busy,
    .install_valid(command_install_valid),
    .install_ready(command_install_ready),
    .install_voice(command_install_voice),
    .install_state(command_install_state),
    .params_write_valid(1'b0),
    .params_write_ready(),
    .params_write_voice('0),
    .params_write_generation('0),
    .params_write_event('0),
    .params_write_env('0),
    .control_event_valid(command_control_event_valid),
    .control_event_ready(command_control_event_ready),
    .control_event(command_control_event),
    .control_event_done_pulse(command_control_event_done),
    .stale_control_event_pulse(stale_control_event),
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
    .stale_params_write_pulse(stale_params_write),
    .stale_dynamic_write_pulse(stale_dynamic_write)
  );

  voice_major_block_controller controller (
    .clk,
    .rst,
    .block_req_valid(block_req_valid && !command_action_pending),
    .block_req_ready(controller_block_req_ready),
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

  assign block_req_ready = controller_block_req_ready && !command_action_pending;

  always_ff @(posedge clk) begin
    if (rst)
      current_frame_q <= '0;
    else if (block_req_valid && block_req_ready)
      current_frame_q <= block_req.start_frame;
  end

  logic unused_control_status;
  assign unused_control_status = stale_params_write ^ stale_dynamic_write ^
      (^command_word_level) ^ command_action_pending;
endmodule
