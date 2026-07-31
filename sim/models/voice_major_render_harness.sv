module voice_major_render_harness (
  input  logic                                     core_clk,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic                                     ddr_clk,
  /* verilator lint_on UNUSEDSIGNAL */
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
  output logic [63:0]                              window_client_requests,
  output logic [63:0]                              window_hits,
  output logic [63:0]                              window_memory_reads,
  output logic [63:0]                              window_evictions,
  output logic [63:0]                              window_stall_cycles,
  output logic [63:0]                              window_refills,
  output logic [63:0]                              window_fallback_reads,
  output logic [31:0]                              configured_window_bytes,
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
  /* verilator lint_off UNUSEDSIGNAL */
  reg_bus_rsp_t bus_rsp;
  /* verilator lint_on UNUSEDSIGNAL */
  render_block_req_t block_req;
  render_block_complete_t block_complete;
  render_block_read_req_t block_read_req;
  render_block_read_rsp_t block_read_rsp;
  sample_window_diagnostics_t sample_window_diagnostics;
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
    window_client_requests =
        64'(sample_window_diagnostics.client_request_count);
    window_hits = 64'(sample_window_diagnostics.window_hit_count);
    window_memory_reads = 64'(sample_window_diagnostics.memory_read_count);
    window_evictions = 64'(sample_window_diagnostics.eviction_count);
    window_stall_cycles =
        64'(sample_window_diagnostics.stall_cycle_count);
    window_refills = 64'(sample_window_diagnostics.window_refill_count);
    window_fallback_reads =
        64'(sample_window_diagnostics.fallback_read_count);
    configured_window_bytes = 32'(NUM_VOICES * 32 * (PCM_WIDTH / 8));
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
    .block_release_buffer_id(block_release_buffer),
    .sample_window_diagnostics
  );

  logic unused_audio_control;
  assign unused_audio_control = (|audio_config) | (|effect_clear);

`ifdef SYNTH_SIM_QSPI
  qspi_nor_timing_model #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .LINE_WORDS(BLOCK_LINE_WORDS),
    .REQUEST_QUEUE_DEPTH(16),
    .INIT_CYCLES(8),
    .COMMAND_BITS(8),
    .COMMAND_LANES(1),
    .ADDRESS_BITS(32),
    .ADDRESS_LANES(4),
    .MODE_BITS(8),
    .MODE_LANES(4),
    .DUMMY_CYCLES(8),
    .DATA_LANES(4),
    .CS_HIGH_CYCLES(1),
    .CONTINUOUS_READ(1'b1)
  ) memory (
    .clk(core_clk),
    .rst,
    .req_valid(line_req_valid),
    .req_ready(line_req_ready),
    .req_addr(line_req.aligned_line_addr),
    .rsp_valid(line_rsp_valid),
    .rsp_ready(line_rsp_ready),
    .rsp_data(ddr_rsp_data),
    .stat_accepted(ddr_accepted),
    .stat_returned(ddr_returned),
    .stat_sequential_lines(ddr_row_hits),
    .stat_random_lines(ddr_row_misses),
    .stat_transactions(ddr_activates),
    .stat_overhead_cycles(ddr_precharges),
    .stat_data_cycles(ddr_refreshes)
  );
`elsif SYNTH_SIM_PARALLEL_NOR
  parallel_nor_timing_model #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .LINE_WORDS(BLOCK_LINE_WORDS),
    .REQUEST_QUEUE_DEPTH(16),
    .INIT_CYCLES(8),
    .PAGE_WORDS(16),
    .CLOCK_PERIOD_NS(10),
    .RANDOM_ACCESS_NS(100),
    .PAGE_ACCESS_NS(15),
    .DEVICE_WORDS(64'd64 * 1024 * 1024),
    .DEVICE_COUNT(3)
  ) memory (
    .clk(core_clk),
    .rst,
    .req_valid(line_req_valid),
    .req_ready(line_req_ready),
    .req_addr(line_req.aligned_line_addr),
    .rsp_valid(line_rsp_valid),
    .rsp_ready(line_rsp_ready),
    .rsp_data(ddr_rsp_data),
    .stat_accepted(ddr_accepted),
    .stat_returned(ddr_returned),
    .stat_page_lines(ddr_row_hits),
    .stat_random_lines(ddr_row_misses),
    .stat_transactions(ddr_activates),
    .stat_random_access_cycles(ddr_precharges),
    .stat_page_access_cycles(ddr_refreshes)
  );
`else
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
`endif
endmodule
