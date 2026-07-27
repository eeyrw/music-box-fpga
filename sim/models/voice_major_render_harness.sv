module voice_major_render_harness #(
  parameter int CACHE_SET_COUNT = 512,
  parameter int MSHR_DEPTH = 8
) (
  input  logic                                     core_clk,
  input  logic                                     ddr_clk,
  input  logic                                     rst,

  input  logic                                     install_valid,
  output logic                                     install_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]     install_voice,
  input  logic [31:0]                              install_base_addr,
  input  logic [23:0]                              install_length,
  input  logic [23:0]                              install_loop_start,
  input  logic [23:0]                              install_loop_end,
  input  logic [1:0]                               install_loop_mode,
  input  logic [31:0]                              install_phase_inc,
  input  logic signed [15:0]                       install_gain_l,
  input  logic signed [15:0]                       install_gain_r,
  input  logic                                     install_filter_enable,
  input  logic signed [15:0]                       install_filter_b0,
  input  logic signed [15:0]                       install_filter_b1,
  input  logic signed [15:0]                       install_filter_b2,
  input  logic signed [15:0]                       install_filter_a1,
  input  logic signed [15:0]                       install_filter_a2,
  input  logic [23:0]                              install_env_delay_samples,
  input  logic [31:0]                              install_env_attack_step,
  input  logic [23:0]                              install_env_hold_samples,
  input  logic [31:0]                              install_env_decay_step,
  input  logic [31:0]                              install_env_sustain_cb,
  input  logic [31:0]                              install_env_release_step,
  input  logic                                     install_active,
  input  logic [15:0]                              install_generation,

  input  logic                                     params_valid,
  output logic                                     params_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]     params_voice,
  input  logic [15:0]                              params_generation,
  input  logic [31:0]                              params_phase_inc,
  input  logic signed [15:0]                       params_gain_l,
  input  logic signed [15:0]                       params_gain_r,
  input  logic                                     params_released,
  input  logic                                     params_filter_enable,
  input  logic signed [15:0]                       params_filter_b0,
  input  logic signed [15:0]                       params_filter_b1,
  input  logic signed [15:0]                       params_filter_b2,
  input  logic signed [15:0]                       params_filter_a1,
  input  logic signed [15:0]                       params_filter_a2,
  input  logic [23:0]                              params_env_delay_samples,
  input  logic [31:0]                              params_env_attack_step,
  input  logic [23:0]                              params_env_hold_samples,
  input  logic [31:0]                              params_env_decay_step,
  input  logic [31:0]                              params_env_sustain_cb,
  input  logic [31:0]                              params_env_release_step,

  input  logic                                     block_req_valid,
  output logic                                     block_req_ready,
  input  logic [31:0]                              block_start_frame,
  input  logic [synth_pkg::BLOCK_FRAME_COUNT_WIDTH-1:0]
                                                   block_frame_count,
  output logic                                     block_complete_valid,
  input  logic                                     block_complete_ready,
  output logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                   block_complete_buffer,
  output logic [31:0]                              block_complete_start_frame,
  output logic [synth_pkg::BLOCK_FRAME_COUNT_WIDTH-1:0]
                                                   block_complete_frame_count,
  input  logic                                     block_read_req_valid,
  output logic                                     block_read_req_ready,
  input  logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                   block_read_buffer,
  input  logic [synth_pkg::BLOCK_FRAME_INDEX_WIDTH-1:0]
                                                   block_read_index,
  output logic                                     block_read_rsp_valid,
  input  logic                                     block_read_rsp_ready,
  output logic signed [synth_pkg::MIX_WIDTH-1:0]   block_read_sample_l,
  output logic signed [synth_pkg::MIX_WIDTH-1:0]   block_read_sample_r,
  input  logic                                     block_release_valid,
  output logic                                     block_release_ready,
  input  logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                   block_release_buffer,

  output logic                                     render_busy,
  output logic                                     stale_params_write,
  output logic [63:0]                              ddr_accepted,
  output logic [63:0]                              ddr_returned,
  output logic [63:0]                              ddr_row_hits,
  output logic [63:0]                              ddr_row_misses,
  output logic [63:0]                              ddr_activates,
  output logic [63:0]                              ddr_precharges,
  output logic [63:0]                              ddr_refreshes,
  output logic [63:0]                              cache_requests,
  output logic [63:0]                              cache_hits,
  output logic [63:0]                              cache_mshr_merges,
  output logic [63:0]                              cache_misses,
  output logic [63:0]                              cache_evictions,
  output logic [63:0]                              cache_miss_stall_cycles,
  output logic [31:0]                              configured_cache_sets,
  output logic [31:0]                              configured_cache_bytes,
  output logic [15:0]                              active_voice_count
);
  import synth_pkg::*;

  block_voice_state_snapshot_t install_state;
  voice_event_params_t params_event;
  volume_env_params_t params_env;
  render_block_req_t block_req;
  render_block_complete_t block_complete;
  render_block_read_req_t block_read_req;
  render_block_read_rsp_t block_read_rsp;
  logic line_req_valid;
  logic line_req_ready;
  ordered_line_req_t line_req;
  logic line_rsp_valid;
  logic line_rsp_ready;
  ordered_line_rsp_t line_rsp;
  logic stale_params_write_internal;
  logic stale_dynamic_write;
  logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0] ddr_rsp_data;

  always_comb begin
    install_state = '0;
    install_state.region.base_addr = install_base_addr;
    install_state.region.length = install_length;
    install_state.region.loop_start = install_loop_start;
    install_state.region.loop_end = install_loop_end;
    install_state.region.loop_mode = install_loop_mode;
    install_state.event_params.phase_inc = install_phase_inc;
    install_state.event_params.gain_l = install_gain_l;
    install_state.event_params.gain_r = install_gain_r;
    install_state.event_params.filter_enable = install_filter_enable;
    install_state.event_params.filter_b0 = install_filter_b0;
    install_state.event_params.filter_b1 = install_filter_b1;
    install_state.event_params.filter_b2 = install_filter_b2;
    install_state.event_params.filter_a1 = install_filter_a1;
    install_state.event_params.filter_a2 = install_filter_a2;
    install_state.env_params.delay_samples = install_env_delay_samples;
    install_state.env_params.attack_step_q0_32 = install_env_attack_step;
    install_state.env_params.hold_samples = install_env_hold_samples;
    install_state.env_params.decay_step_cb_q12_20 = install_env_decay_step;
    install_state.env_params.sustain_cb_q12_20 = install_env_sustain_cb;
    install_state.env_params.release_step_cb_q12_20 = install_env_release_step;
    install_state.dynamic.active = install_active;
    install_state.dynamic.generation = install_generation;
    install_state.dynamic.env_state.stage = ENV_DELAY;

    params_event = '0;
    params_event.phase_inc = params_phase_inc;
    params_event.gain_l = params_gain_l;
    params_event.gain_r = params_gain_r;
    params_event.released = params_released;
    params_event.filter_enable = params_filter_enable;
    params_event.filter_b0 = params_filter_b0;
    params_event.filter_b1 = params_filter_b1;
    params_event.filter_b2 = params_filter_b2;
    params_event.filter_a1 = params_filter_a1;
    params_event.filter_a2 = params_filter_a2;
    params_env.delay_samples = params_env_delay_samples;
    params_env.attack_step_q0_32 = params_env_attack_step;
    params_env.hold_samples = params_env_hold_samples;
    params_env.decay_step_cb_q12_20 = params_env_decay_step;
    params_env.sustain_cb_q12_20 = params_env_sustain_cb;
    params_env.release_step_cb_q12_20 = params_env_release_step;

    block_req.start_frame = block_start_frame;
    block_req.frame_count = block_frame_count;
    block_complete_buffer = block_complete.buffer_id;
    block_complete_start_frame = block_complete.start_frame;
    block_complete_frame_count = block_complete.frame_count;
    block_read_req.buffer_id = block_read_buffer;
    block_read_req.frame_index = block_read_index;
    block_read_sample_l = block_read_rsp.sample.l;
    block_read_sample_r = block_read_rsp.sample.r;
    line_rsp.words = ddr_rsp_data;
    stale_params_write = stale_params_write_internal;
    cache_requests = core.controller.engine.renderer.cache_stat_client_requests;
    cache_hits = core.controller.engine.renderer.cache_stat_cache_hits;
    cache_mshr_merges = core.controller.engine.renderer.cache_stat_mshr_merges;
    cache_misses = core.controller.engine.renderer.cache_stat_memory_misses;
    cache_evictions = core.controller.engine.renderer.cache_stat_evictions;
    cache_miss_stall_cycles =
        core.controller.engine.renderer.cache_stat_miss_stall_cycles;
    configured_cache_sets = 32'(CACHE_SET_COUNT);
    configured_cache_bytes = 32'(CACHE_SET_COUNT * 2 * BLOCK_LINE_WORDS *
                                 (PCM_WIDTH / 8));
    active_voice_count = 16'($countones(core.active_bitmap));
  end

  voice_major_render_core #(
    .CACHE_SET_COUNT(CACHE_SET_COUNT),
    .MSHR_DEPTH(MSHR_DEPTH)
  ) core (
    .clk(core_clk),
    .rst,
    .install_valid,
    .install_ready,
    .install_voice,
    .install_state,
    .params_write_valid(params_valid),
    .params_write_ready(params_ready),
    .params_write_voice(params_voice),
    .params_write_generation(params_generation),
    .params_write_event(params_event),
    .params_write_env(params_env),
    .stale_params_write_pulse(stale_params_write_internal),
    .stale_dynamic_write_pulse(stale_dynamic_write),
    .block_req_valid,
    .block_req_ready,
    .block_req,
    .render_busy,
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
    .block_release_buffer_id(block_release_buffer)
  );

  ordered_line_ddr3_bridge_model #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .LINE_WORDS(BLOCK_LINE_WORDS),
    .DQ_WIDTH(16),
    .BURST_LENGTH(8),
    .BANK_COUNT(8),
    .COLUMN_BITS(7),
    .REQUEST_QUEUE_DEPTH(8),
    .INIT_CYCLES(40),
    .T_RCD(6),
    .T_RP(6),
    .T_CL(6),
    .T_RAS(14),
    .T_RC(20),
    .T_CCD(4),
    .T_RTP(3),
    .T_RFC(104),
    .T_REFI(3120)
  ) memory (
    .core_clk,
    .core_rst(rst),
    .ddr_clk,
    .ddr_rst(rst),
    .req_valid(line_req_valid),
    .req_ready(line_req_ready),
    .req_addr(line_req.aligned_line_addr),
    .rsp_valid(line_rsp_valid),
    .rsp_ready(line_rsp_ready),
    .rsp_data(ddr_rsp_data),
    .stat_accepted(ddr_accepted),
    .stat_returned(ddr_returned),
    .stat_row_hits(ddr_row_hits),
    .stat_row_misses(ddr_row_misses),
    .stat_activates(ddr_activates),
    .stat_precharges(ddr_precharges),
    .stat_refreshes(ddr_refreshes)
  );
endmodule
