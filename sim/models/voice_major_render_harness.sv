module voice_major_render_harness (
  input  logic                                     core_clk,
  input  logic                                     ddr_clk,
  input  logic                                     rst,

  input  logic                                     cmd_stream_valid,
  output logic                                     cmd_stream_ready,
  input  logic [31:0]                              cmd_stream_data,

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
  output logic [31:0]                              command_error_count,
  output logic [31:0]                              stale_generation_count,
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
  output logic [63:0]                              window_refills,
  output logic [63:0]                              window_fallback_reads,
  output logic [31:0]                              configured_cache_sets,
  output logic [31:0]                              configured_cache_bytes,
  output logic [31:0]                              configured_window_words,
  output logic [31:0]                              configured_max_block_frames,
  output logic [15:0]                              active_voice_count,
  output synth_pkg::global_audio_config_t           audio_config,
  output logic [1:0]                               effect_clear,

  output logic                                     debug_plan_valid,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]     debug_plan_voice,
  output logic                                     debug_plan_first,
  output logic                                     debug_plan_last,
  output logic [31:0]                              debug_plan_addr_0,
  output logic [31:0]                              debug_plan_addr_1
);
  import synth_pkg::*;

  reg_bus_req_t bus_req;
  reg_bus_rsp_t bus_rsp;
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
  logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0] ddr_rsp_data;
  // Simulation-only trace of the unfiltered sample-address stream. Registering
  // it here makes each planner event visible for one complete core cycle.
  always_ff @(posedge core_clk) begin
    if (rst) begin
      debug_plan_valid <= 1'b0;
      debug_plan_voice <= '0;
      debug_plan_first <= 1'b0;
      debug_plan_last <= 1'b0;
      debug_plan_addr_0 <= '0;
      debug_plan_addr_1 <= '0;
    end else begin
      debug_plan_valid <= core.controller.engine.renderer.plan_store_job;
      if (core.controller.engine.renderer.plan_store_job) begin
        debug_plan_voice <= core.controller.engine.renderer.work_context_q[
            core.controller.engine.renderer.plan_q.work_id].voice_index;
        debug_plan_first <=
            core.controller.engine.renderer.plan_q.job_count == '0;
        debug_plan_last <= core.controller.engine.renderer.plan_step_finishes;
        debug_plan_addr_0 <=
            core.controller.engine.renderer.plan_q.region.base_addr +
            32'(core.controller.engine.renderer.plan_frame_0);
        debug_plan_addr_1 <=
            core.controller.engine.renderer.plan_q.region.base_addr +
            32'(core.controller.engine.renderer.plan_frame_1);
      end
    end
  end

  always_comb begin
    bus_req = '0;

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
    cache_requests = core.controller.engine.renderer.cache_stat_client_requests;
    cache_hits = core.controller.engine.renderer.cache_stat_cache_hits;
    cache_mshr_merges = core.controller.engine.renderer.cache_stat_mshr_merges;
    cache_misses = core.controller.engine.renderer.cache_stat_memory_misses;
    cache_evictions = core.controller.engine.renderer.cache_stat_evictions;
    cache_miss_stall_cycles =
        core.controller.engine.renderer.cache_stat_miss_stall_cycles;
    window_refills = core.controller.engine.renderer.cache_stat_window_refills;
    window_fallback_reads =
        core.controller.engine.renderer.cache_stat_fallback_reads;
    configured_cache_sets = '0;
    configured_cache_bytes = 32'(NUM_VOICES * 32 * (PCM_WIDTH / 8));
    configured_window_words = 32'd32;
    configured_max_block_frames = 32'(MAX_BLOCK_FRAMES);
    active_voice_count = '0;
    for (int voice = 0; voice < NUM_VOICES; voice++) begin
      active_voice_count += 16'(core.state_store.dynamic_mem[voice][
          $bits(voice_dynamic_state_t) - 1]);
    end
  end

  voice_major_render_core core (
    .clk(core_clk),
    .rst,
    .bus_req,
    .bus_rsp,
    .cmd_stream_valid,
    .cmd_stream_data,
    .cmd_stream_ready,
    .command_error_count,
    .stale_generation_count,
    .audio_config,
    .effect_clear,
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

  logic unused_audio_control;
  assign unused_audio_control = (|audio_config) | (|effect_clear);

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
