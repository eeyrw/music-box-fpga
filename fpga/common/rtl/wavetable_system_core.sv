module wavetable_system_core #(
  parameter int LINE_WORDS = 32,
  parameter int LOOKAHEAD_FRAMES = 48
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     bus_valid,
  input  logic                     bus_write,
  input  logic [15:0]              bus_address,
  input  logic [31:0]              bus_wdata,
  output logic [31:0]              bus_rdata,
  output logic                     bus_ready,
  output logic                     bus_error,
  input  logic                     cmd_stream_valid,
  input  logic [31:0]              cmd_stream_data,
  output logic                     cmd_stream_ready,
  input  logic                     sample_tick,
  output logic                     sample_valid,
  input  logic                     sample_ready,
  output synth_pkg::pcm_t          sample_l,
  output synth_pkg::pcm_t          sample_r,
  output logic                     busy,
  output logic                     compressor_enabled,
  output logic                     compressor_primed,
  output logic [15:0]              compressor_delay_level,
  output logic [31:0]              compressor_gain_reduction,
  output logic [31:0]              compressor_target_gain_reduction,
  output logic [synth_pkg::MIX_WIDTH-1:0] compressor_detector_peak,
  output logic [31:0]              compressor_max_gain_reduction,
  output logic [synth_pkg::MIX_WIDTH-1:0] compressor_max_detector_peak,
  output logic [31:0]              compressor_input_frame_count,
  output logic [31:0]              compressor_output_frame_count,
  output logic [31:0]              compressor_compressed_frame_count,
  output logic [31:0]              compressor_saturation_count,
  output logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  output logic [31:0]              ext_req_addr,
  input  logic                     ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0] ext_rsp_data,
  output logic                     mem_response_trace_pulse,
  output logic [15:0]              mem_response_trace_latency
);
  logic mem_req_valid;
  logic [synth_pkg::VOICE_ID_WIDTH-1:0] mem_req_voice;
  logic [synth_pkg::STREAM_ID_WIDTH-1:0] mem_req_stream_id;
  logic [31:0] mem_req_addr;
  logic mem_req_ready;
  logic mem_rsp_valid;
  synth_pkg::pcm_t mem_rsp_data;
  synth_pkg::wave_word_req_t mem_req;
  synth_pkg::wave_word_rsp_t mem_rsp;
  logic endpoint_cross_line_pair_pulse;
  logic endpoint_fetch_slot_pressure_pulse;
  logic endpoint_memory_stall_pulse;
  logic [2:0] endpoint_fetch_slot_occupancy;
  logic [2:0] endpoint_fetch_slot_max_occupancy;
  logic [4:0] endpoint_word_req_occupancy;
  logic [4:0] endpoint_word_req_max_occupancy;
  logic [4:0] endpoint_rsp_meta_occupancy;
  logic [4:0] endpoint_rsp_meta_max_occupancy;
  logic [2:0] dsp_context_queue_occupancy;
  logic [2:0] dsp_context_queue_max_occupancy;
  logic dsp_ready_no_context_pulse;
  logic unused_render_diagnostics;
  logic renderer_sample_valid;
  logic renderer_busy;
  synth_pkg::pcm_t renderer_sample_l;
  synth_pkg::pcm_t renderer_sample_r;
  synth_pkg::mix_t renderer_mix_l;
  synth_pkg::mix_t renderer_mix_r;
  synth_pkg::compressor_config_t compressor_config;
  logic signed [15:0] master_volume;
  logic raw_mix_valid;
  synth_pkg::mix_t raw_mix_l;
  synth_pkg::mix_t raw_mix_r;
  logic compressor_in_ready;

  assign busy = renderer_busy || raw_mix_valid || !compressor_in_ready;

  assign mem_req.valid = mem_req_valid;
  assign mem_req.voice = mem_req_voice;
  assign mem_req.stream_id = mem_req_stream_id;
  assign mem_req.addr = mem_req_addr;
  assign mem_rsp_valid = mem_rsp.valid;
  assign mem_rsp_data = mem_rsp.data;
  assign unused_render_diagnostics = endpoint_cross_line_pair_pulse |
                                     endpoint_fetch_slot_pressure_pulse |
                                     endpoint_memory_stall_pulse |
                                     (|endpoint_fetch_slot_occupancy) |
                                     (|endpoint_fetch_slot_max_occupancy) |
                                     (|endpoint_word_req_occupancy) |
                                     (|endpoint_word_req_max_occupancy) |
                                     (|endpoint_rsp_meta_occupancy) |
                                     (|endpoint_rsp_meta_max_occupancy) |
                                     (|dsp_context_queue_occupancy) |
                                     (|dsp_context_queue_max_occupancy) |
                                     dsp_ready_no_context_pulse;

  wavetable_render_core #(
    .LINE_WORDS(LINE_WORDS)
  ) core (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .cmd_stream_valid,
    .cmd_stream_data,
    .cmd_stream_ready,
    .sample_tick,
    .sample_valid(renderer_sample_valid),
    .sample_l(renderer_sample_l),
    .sample_r(renderer_sample_r),
    .mix_l(renderer_mix_l),
    .mix_r(renderer_mix_r),
    .compressor_config,
    .master_volume,
    .busy(renderer_busy),
    .mem_req_valid,
    .mem_req_voice,
    .mem_req_stream_id,
    .mem_req_addr,
    .mem_req_ready,
    .mem_rsp_valid,
    .mem_rsp_data,
    .endpoint_cross_line_pair_pulse,
    .endpoint_fetch_slot_pressure_pulse,
    .endpoint_memory_stall_pulse,
    .endpoint_fetch_slot_occupancy,
    .endpoint_fetch_slot_max_occupancy,
    .endpoint_word_req_occupancy,
    .endpoint_word_req_max_occupancy,
    .endpoint_rsp_meta_occupancy,
    .endpoint_rsp_meta_max_occupancy,
    .dsp_context_queue_occupancy,
    .dsp_context_queue_max_occupancy,
    .dsp_ready_no_context_pulse
  );

  // The renderer emits a completion pulse. Hold the wide mix until the
  // compressor accepts the complete frame.
  always_ff @(posedge clk) begin
    if (rst) begin
      raw_mix_valid <= 1'b0;
      raw_mix_l <= '0;
      raw_mix_r <= '0;
    end else begin
      if (raw_mix_valid && compressor_in_ready)
        raw_mix_valid <= 1'b0;

      if (renderer_sample_valid) begin
        raw_mix_valid <= 1'b1;
        raw_mix_l <= renderer_mix_l;
        raw_mix_r <= renderer_mix_r;
      end
    end
  end

  lookahead_compressor #(
    .LOOKAHEAD_FRAMES(LOOKAHEAD_FRAMES)
  ) compressor (
    .clk,
    .rst,
    .config_i(compressor_config),
    .master_volume_i(master_volume),
    .in_valid(raw_mix_valid),
    .in_ready(compressor_in_ready),
    .in_l(raw_mix_l),
    .in_r(raw_mix_r),
    .out_valid(sample_valid),
    .out_ready(sample_ready),
    .out_l(sample_l),
    .out_r(sample_r),
    .enabled(compressor_enabled),
    .primed(compressor_primed),
    .delay_level_frames(compressor_delay_level),
    .gain_reduction_cb_q12_20(compressor_gain_reduction),
    .target_gain_reduction_cb_q12_20(compressor_target_gain_reduction),
    .detector_peak(compressor_detector_peak),
    .max_gain_reduction_cb_q12_20(compressor_max_gain_reduction),
    .max_detector_peak(compressor_max_detector_peak),
    .input_frame_count(compressor_input_frame_count),
    .output_frame_count(compressor_output_frame_count),
    .compressed_frame_count(compressor_compressed_frame_count),
    .saturation_count(compressor_saturation_count)
  );

  wave_memory_subsystem #(.LINE_WORDS(LINE_WORDS)) memory (
    .clk,
    .rst,
    .core_req(mem_req),
    .core_req_ready(mem_req_ready),
    .core_rsp(mem_rsp),
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .response_trace_pulse(mem_response_trace_pulse),
    .response_trace_latency(mem_response_trace_latency)
  );

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_renderer_pcm;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_renderer_pcm = (|renderer_sample_l) | (|renderer_sample_r);
endmodule
