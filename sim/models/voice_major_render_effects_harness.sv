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

  typedef enum logic [2:0] {
    OUTPUT_IDLE,
    OUTPUT_WAIT_RENDER,
    OUTPUT_READ_REQUEST,
    OUTPUT_READ_RESPONSE,
    OUTPUT_RELEASE,
    OUTPUT_COMPLETE
  } output_state_t;

  output_state_t output_state_q;
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
  logic [BLOCK_FRAME_INDEX_WIDTH-1:0] output_index_q;

  assign base_block_req_valid = block_req_valid &&
                                (output_state_q == OUTPUT_IDLE);
  assign block_req_ready = base_block_req_ready &&
                           (output_state_q == OUTPUT_IDLE);
  assign base_block_complete_ready = output_state_q == OUTPUT_WAIT_RENDER;
  assign base_block_read_req_valid = output_state_q == OUTPUT_READ_REQUEST;
  assign base_block_read_buffer = block_complete_buffer;
  assign base_block_read_index = output_index_q;
  assign base_block_read_rsp_ready =
      (output_state_q == OUTPUT_READ_RESPONSE) && effects_input_ready;
  assign base_block_release_valid = output_state_q == OUTPUT_RELEASE;
  assign base_block_release_buffer = block_complete_buffer;

  assign effects_input_valid =
      ((output_state_q == OUTPUT_READ_RESPONSE) &&
       base_block_read_rsp_valid) ||
      ((output_state_q == OUTPUT_IDLE) && effect_flush_valid);
  assign effects_input_l = (output_state_q == OUTPUT_READ_RESPONSE) ?
                           base_block_read_sample_l : '0;
  assign effects_input_r = (output_state_q == OUTPUT_READ_RESPONSE) ?
                           base_block_read_sample_r : '0;
  assign effect_flush_ready = (output_state_q == OUTPUT_IDLE) &&
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
    .block_start_frame,
    .block_frame_count,
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

  always_ff @(posedge core_clk) begin
    if (rst) begin
      output_state_q <= OUTPUT_IDLE;
      renderer_complete_valid <= 1'b0;
      block_complete_valid <= 1'b0;
      block_complete_buffer <= '0;
      block_complete_start_frame <= '0;
      block_complete_frame_count <= '0;
      output_index_q <= '0;
    end else begin
      renderer_complete_valid <= 1'b0;
      unique case (output_state_q)
        OUTPUT_IDLE: begin
          if (base_block_req_valid && base_block_req_ready)
            output_state_q <= OUTPUT_WAIT_RENDER;
        end
        OUTPUT_WAIT_RENDER: begin
          if (base_block_complete_valid && base_block_complete_ready) begin
            renderer_complete_valid <= 1'b1;
            block_complete_buffer <= base_block_complete_buffer;
            block_complete_start_frame <= base_block_complete_start_frame;
            block_complete_frame_count <= base_block_complete_frame_count;
            output_index_q <= '0;
            output_state_q <= OUTPUT_READ_REQUEST;
          end
        end
        OUTPUT_READ_REQUEST: begin
          if (base_block_read_req_valid && base_block_read_req_ready)
            output_state_q <= OUTPUT_READ_RESPONSE;
        end
        OUTPUT_READ_RESPONSE: begin
          if (base_block_read_rsp_valid && base_block_read_rsp_ready) begin
            if (BLOCK_FRAME_COUNT_WIDTH'(output_index_q) + 1'b1 >=
                block_complete_frame_count) begin
              output_state_q <= OUTPUT_RELEASE;
            end else begin
              output_index_q <= output_index_q + 1'b1;
              output_state_q <= OUTPUT_READ_REQUEST;
            end
          end
        end
        OUTPUT_RELEASE: begin
          if (base_block_release_valid && base_block_release_ready) begin
            block_complete_valid <= 1'b1;
            output_state_q <= OUTPUT_COMPLETE;
          end
        end
        OUTPUT_COMPLETE: begin
          if (block_complete_valid && block_complete_ready) begin
            block_complete_valid <= 1'b0;
            output_state_q <= OUTPUT_IDLE;
          end
        end
        default: output_state_q <= OUTPUT_IDLE;
      endcase
    end
  end
endmodule
