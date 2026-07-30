module voice_major_render_effects_harness (
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
  output logic                                     renderer_complete_valid,
  output logic                                     block_complete_valid,
  input  logic                                     block_complete_ready,
  output logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                   block_complete_buffer,
  output logic [31:0]                              block_complete_start_frame,
  output logic [synth_pkg::BLOCK_FRAME_COUNT_WIDTH-1:0]
                                                   block_complete_frame_count,

  input  logic                                     effect_flush_valid,
  output logic                                     effect_flush_ready,
  output logic                                     effect_output_valid,
  input  logic                                     effect_output_ready,
  output logic signed [synth_pkg::PCM_WIDTH-1:0]   effect_output_l,
  output logic signed [synth_pkg::PCM_WIDTH-1:0]   effect_output_r,
  output logic                                     effects_busy,
  output logic [15:0]                              effects_max_processing_cycles,
  output logic [31:0]                              effects_input_frame_count,
  output logic [31:0]                              effects_output_frame_count,
  output logic [63:0]                              overlap_total_renderer_cycles,
  output logic [63:0]                              overlap_max_renderer_cycles,
  output logic [63:0]                              overlap_max_renderer_utilization_ppm,
  output logic [31:0]                              overlap_renderer_deadline_misses,
  output logic [63:0]                              overlap_total_release_cycles,
  output logic [63:0]                              overlap_max_release_cycles,
  output logic [63:0]                              overlap_max_initiation_cycles,
  output logic [63:0]                              overlap_max_release_utilization_ppm,
  output logic [31:0]                              overlap_release_deadline_misses,

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

  output logic                                     debug_plan_valid,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]     debug_plan_voice,
  output logic                                     debug_plan_first,
  output logic                                     debug_plan_last,
  output logic [31:0]                              debug_plan_addr_0,
  output logic [31:0]                              debug_plan_addr_1
);
  import synth_pkg::*;

  logic base_block_req_valid;
  logic base_block_req_ready;
  logic base_block_complete_valid;
  logic base_block_complete_ready;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] base_block_complete_buffer;
  logic [31:0] base_block_complete_start_frame;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] base_block_complete_frame_count;
  logic base_block_read_req_valid;
  logic base_block_read_req_ready;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] base_block_read_buffer;
  logic [BLOCK_FRAME_INDEX_WIDTH-1:0] base_block_read_index;
  logic base_block_read_rsp_valid;
  logic base_block_read_rsp_ready;
  mix_t base_block_read_sample_l;
  mix_t base_block_read_sample_r;
  logic base_block_release_valid;
  logic base_block_release_ready;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] base_block_release_buffer;
  global_audio_config_t audio_config;
  logic [1:0] effect_clear;
  audio_diagnostics_t audio_diagnostics;
  logic effects_input_valid;
  logic effects_input_ready;
  mix_t effects_input_l;
  mix_t effects_input_r;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] output_buffer_q;
  logic [31:0] output_start_frame_q;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] output_frame_count_q;
  render_block_req_t manager_request;
  render_block_req_t manager_block_req;
  render_block_complete_t manager_block_complete;
  render_block_read_req_t manager_block_read_req;
  logic manager_block_req_valid;
  logic manager_block_read_req_valid;
  logic manager_block_read_rsp_ready;
  logic manager_block_release_valid;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] manager_block_release_buffer;
  logic manager_sample_valid;
  logic manager_block_pipeline_busy;
  logic manager_release_accepted_pulse;
  logic manager_request_accepted_pulse;
  logic manager_renderer_complete_pulse;
  logic manager_render_deadline_miss_pulse;
  logic [15:0] manager_render_latency_cycles;
  logic [63:0] core_cycle_q;
  logic [63:0] request_start_cycle_q;
  logic [63:0] output_start_cycle_q;
  logic [63:0] last_request_cycle_q;
  logic have_last_request_q;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] request_frame_count_q;

  assign renderer_complete_valid = manager_renderer_complete_pulse;

  assign manager_request.start_frame = block_start_frame;
  assign manager_request.frame_count = block_frame_count;
  assign base_block_req_valid = manager_block_req_valid;
  assign base_block_read_req_valid = manager_block_read_req_valid;
  assign base_block_read_buffer = manager_block_read_req.buffer_id;
  assign base_block_read_index = manager_block_read_req.frame_index;
  assign base_block_read_rsp_ready = manager_block_read_rsp_ready;
  assign base_block_release_valid = manager_block_release_valid;
  assign base_block_release_buffer = manager_block_release_buffer;
  assign manager_block_complete.buffer_id = base_block_complete_buffer;
  assign manager_block_complete.start_frame = base_block_complete_start_frame;
  assign manager_block_complete.frame_count = base_block_complete_frame_count;

  assign effects_input_valid =
      manager_sample_valid ||
      (!manager_block_pipeline_busy && effect_flush_valid);
  assign effects_input_l = manager_sample_valid ?
                           base_block_read_sample_l : '0;
  assign effects_input_r = manager_sample_valid ?
                           base_block_read_sample_r : '0;
  assign effect_flush_ready = !manager_block_pipeline_busy &&
                              effects_input_ready;
  assign effects_max_processing_cycles =
      audio_diagnostics.effects.max_processing_cycles;
  assign effects_input_frame_count =
      audio_diagnostics.effects.input_frame_count;
  assign effects_output_frame_count =
      audio_diagnostics.compressor.output_frame_count;

  voice_major_render_harness renderer (
    .core_clk,
    .ddr_clk,
    .rst,
    .cmd_stream_valid,
    .cmd_stream_ready,
    .cmd_stream_data,
    .block_req_valid(base_block_req_valid),
    .block_req_ready(base_block_req_ready),
    .block_start_frame(manager_block_req.start_frame),
    .block_frame_count(manager_block_req.frame_count),
    .block_complete_valid(base_block_complete_valid),
    .block_complete_ready(base_block_complete_ready),
    .block_complete_buffer(base_block_complete_buffer),
    .block_complete_start_frame(base_block_complete_start_frame),
    .block_complete_frame_count(base_block_complete_frame_count),
    .block_read_req_valid(base_block_read_req_valid),
    .block_read_req_ready(base_block_read_req_ready),
    .block_read_buffer(base_block_read_buffer),
    .block_read_index(base_block_read_index),
    .block_read_rsp_valid(base_block_read_rsp_valid),
    .block_read_rsp_ready(base_block_read_rsp_ready),
    .block_read_sample_l(base_block_read_sample_l),
    .block_read_sample_r(base_block_read_sample_r),
    .block_release_valid(base_block_release_valid),
    .block_release_ready(base_block_release_ready),
    .block_release_buffer(base_block_release_buffer),
    .render_busy,
    .command_error_count,
    .stale_generation_count,
    .ddr_accepted,
    .ddr_returned,
    .ddr_row_hits,
    .ddr_row_misses,
    .ddr_activates,
    .ddr_precharges,
    .ddr_refreshes,
    .window_client_requests,
    .window_hits,
    .window_memory_reads,
    .window_evictions,
    .window_stall_cycles,
    .window_refills,
    .window_fallback_reads,
    .configured_window_bytes,
    .configured_window_words,
    .configured_max_block_frames,
    .active_voice_count,
    .audio_config,
    .effect_clear,
    .debug_plan_valid,
    .debug_plan_voice,
    .debug_plan_first,
    .debug_plan_last,
    .debug_plan_addr_0,
    .debug_plan_addr_1
  );

  global_audio_effects_chain effects (
    .clk(core_clk),
    .rst,
    .effect_clear_i(effect_clear),
    .config_i(audio_config),
    .in_valid(effects_input_valid),
    .in_ready(effects_input_ready),
    .in_l(effects_input_l),
    .in_r(effects_input_r),
    .out_valid(effect_output_valid),
    .out_ready(effect_output_ready),
    .out_l(effect_output_l),
    .out_r(effect_output_r),
    .busy(effects_busy),
    .diagnostics_o(audio_diagnostics)
  );

  /* verilator lint_off PINCONNECTEMPTY */
  voice_major_block_output_manager manager (
    .clk(core_clk),
    .rst,
    .request_valid(block_req_valid),
    .request_ready(block_req_ready),
    .request(manager_request),
    .request_accepted_pulse(manager_request_accepted_pulse),
    .block_req_valid(manager_block_req_valid),
    .block_req_ready(base_block_req_ready),
    .block_req(manager_block_req),
    .renderer_busy(render_busy),
    .block_complete_valid(base_block_complete_valid),
    .block_complete_ready(base_block_complete_ready),
    .block_complete(manager_block_complete),
    .renderer_complete_pulse(manager_renderer_complete_pulse),
    .completion_accepted_pulse(),
    .block_read_req_valid(manager_block_read_req_valid),
    .block_read_req_ready(base_block_read_req_ready),
    .block_read_req(manager_block_read_req),
    .block_read_rsp_valid(base_block_read_rsp_valid),
    .block_read_rsp_ready(manager_block_read_rsp_ready),
    .block_release_valid(manager_block_release_valid),
    .block_release_ready(base_block_release_ready),
    .block_release_buffer_id(manager_block_release_buffer),
    .release_accepted_pulse(manager_release_accepted_pulse),
    .sample_valid(manager_sample_valid),
    .sample_ready(effects_input_ready),
    .effects_busy,
    .drain_busy(),
    .block_pipeline_busy(manager_block_pipeline_busy),
    .render_inflight(),
    .render_deadline_miss_pulse(manager_render_deadline_miss_pulse),
    .render_latency_cycles(manager_render_latency_cycles)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  always_ff @(posedge core_clk) begin
    if (rst) begin
      block_complete_valid <= 1'b0;
      block_complete_buffer <= '0;
      block_complete_start_frame <= '0;
      block_complete_frame_count <= '0;
      output_buffer_q <= '0;
      output_start_frame_q <= '0;
      output_frame_count_q <= '0;
      core_cycle_q <= '0;
      request_start_cycle_q <= '0;
      output_start_cycle_q <= '0;
      last_request_cycle_q <= '0;
      have_last_request_q <= 1'b0;
      request_frame_count_q <= '0;
      overlap_total_renderer_cycles <= '0;
      overlap_max_renderer_cycles <= '0;
      overlap_max_renderer_utilization_ppm <= '0;
      overlap_renderer_deadline_misses <= '0;
      overlap_total_release_cycles <= '0;
      overlap_max_release_cycles <= '0;
      overlap_max_initiation_cycles <= '0;
      overlap_max_release_utilization_ppm <= '0;
      overlap_release_deadline_misses <= '0;
    end else begin
      logic [63:0] release_cycles;
      logic [63:0] release_utilization_ppm;
      logic [63:0] renderer_utilization_ppm;

      core_cycle_q <= core_cycle_q + 1'b1;

      if (block_complete_valid && block_complete_ready)
        block_complete_valid <= 1'b0;

      if (manager_request_accepted_pulse) begin
        request_start_cycle_q <= core_cycle_q;
        request_frame_count_q <= manager_request.frame_count;
        if (have_last_request_q &&
            core_cycle_q - last_request_cycle_q >
            overlap_max_initiation_cycles)
          overlap_max_initiation_cycles <=
              core_cycle_q - last_request_cycle_q;
        last_request_cycle_q <= core_cycle_q;
        have_last_request_q <= 1'b1;
      end

      if (manager_renderer_complete_pulse) begin
        renderer_utilization_ppm =
            (64'(manager_render_latency_cycles) * 64'(48_000) *
             64'(1_000_000)) /
            (64'(request_frame_count_q) * 64'(100_000_000));
        overlap_total_renderer_cycles <= overlap_total_renderer_cycles +
                                         64'(manager_render_latency_cycles);
        if (64'(manager_render_latency_cycles) > overlap_max_renderer_cycles)
          overlap_max_renderer_cycles <= 64'(manager_render_latency_cycles);
        if (renderer_utilization_ppm >
            overlap_max_renderer_utilization_ppm)
          overlap_max_renderer_utilization_ppm <= renderer_utilization_ppm;
        if (manager_render_deadline_miss_pulse)
          overlap_renderer_deadline_misses <=
              overlap_renderer_deadline_misses + 1'b1;
      end

      if (base_block_complete_valid && base_block_complete_ready) begin
        output_buffer_q <= base_block_complete_buffer;
        output_start_frame_q <= base_block_complete_start_frame;
        output_frame_count_q <= base_block_complete_frame_count;
        output_start_cycle_q <= request_start_cycle_q;
      end

      if (manager_release_accepted_pulse) begin
        release_cycles = core_cycle_q - output_start_cycle_q;
        release_utilization_ppm =
            (release_cycles * 64'(48_000) * 64'(1_000_000)) /
            (64'(output_frame_count_q) * 64'(100_000_000));
        block_complete_buffer <= output_buffer_q;
        block_complete_start_frame <= output_start_frame_q;
        block_complete_frame_count <= output_frame_count_q;
        block_complete_valid <= 1'b1;
        overlap_total_release_cycles <=
            overlap_total_release_cycles + release_cycles;
        if (release_cycles > overlap_max_release_cycles)
          overlap_max_release_cycles <= release_cycles;
        if (release_utilization_ppm > overlap_max_release_utilization_ppm)
          overlap_max_release_utilization_ppm <= release_utilization_ppm;
        if (release_utilization_ppm > 64'(1_000_000))
          overlap_release_deadline_misses <=
              overlap_release_deadline_misses + 1'b1;
      end
    end
  end
endmodule
