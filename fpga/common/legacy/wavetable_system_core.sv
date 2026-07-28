module wavetable_system_core #(
  parameter int LINE_WORDS = 32,
  parameter int LOOKAHEAD_FRAMES = 48
) (
  input  logic                     clk,
  input  logic                     rst,
  input  synth_pkg::reg_bus_req_t  bus_req,
  output synth_pkg::reg_bus_rsp_t  bus_rsp,
  input  logic                     cmd_stream_valid,
  input  logic [31:0]              cmd_stream_data,
  output logic                     cmd_stream_ready,
  input  logic                     sample_tick,
  output logic                     sample_valid,
  input  logic                     sample_ready,
  output synth_pkg::pcm_t          sample_l,
  output synth_pkg::pcm_t          sample_r,
  output logic                     busy,
  output synth_pkg::audio_diagnostics_t audio_diagnostics,
  output logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  output logic [31:0]              ext_req_addr,
  input  logic                     ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0] ext_rsp_data,
  output logic                     mem_response_trace_pulse,
  output logic [15:0]              mem_response_trace_latency
);
  logic mem_req_ready;
  synth_pkg::wave_word_req_t mem_req;
  synth_pkg::wave_word_rsp_t mem_rsp;
  synth_pkg::voice_pipeline_diagnostics_t voice_diagnostics;
  logic unused_render_diagnostics;
  logic renderer_sample_valid;
  logic renderer_busy;
  synth_pkg::pcm_t renderer_sample_l;
  synth_pkg::pcm_t renderer_sample_r;
  synth_pkg::mix_t renderer_mix_l;
  synth_pkg::mix_t renderer_mix_r;
  synth_pkg::global_audio_config_t audio_config;
  logic [1:0] effect_clear;
  logic raw_mix_valid;
  synth_pkg::mix_t raw_mix_l;
  synth_pkg::mix_t raw_mix_r;
  logic effects_in_ready;
  logic effects_busy;

  assign busy = renderer_busy || raw_mix_valid || effects_busy;

  assign unused_render_diagnostics = |voice_diagnostics;

  wavetable_render_core #(
    .LINE_WORDS(LINE_WORDS)
  ) core (
    .clk,
    .rst,
    .bus_valid(bus_req.valid),
    .bus_write(bus_req.write),
    .bus_address(bus_req.address),
    .bus_wdata(bus_req.wdata),
    .bus_rdata(bus_rsp.rdata),
    .bus_ready(bus_rsp.ready),
    .bus_error(bus_rsp.error),
    .cmd_stream_valid,
    .cmd_stream_data,
    .cmd_stream_ready,
    .sample_tick,
    .sample_valid(renderer_sample_valid),
    .sample_l(renderer_sample_l),
    .sample_r(renderer_sample_r),
    .mix_l(renderer_mix_l),
    .mix_r(renderer_mix_r),
    .audio_config,
    .effect_clear,
    .busy(renderer_busy),
    .mem_req,
    .mem_req_ready,
    .mem_rsp,
    .voice_diagnostics
  );

  // The renderer emits a completion pulse. Hold the wide mix until the
  // global audio chain accepts the complete frame.
  always_ff @(posedge clk) begin
    if (rst) begin
      raw_mix_valid <= 1'b0;
      raw_mix_l <= '0;
      raw_mix_r <= '0;
    end else begin
      if (raw_mix_valid && effects_in_ready)
        raw_mix_valid <= 1'b0;

      if (renderer_sample_valid) begin
        raw_mix_valid <= 1'b1;
        raw_mix_l <= renderer_mix_l;
        raw_mix_r <= renderer_mix_r;
      end
    end
  end

  global_audio_effects_chain #(
    .COMPRESSOR_LOOKAHEAD_FRAMES(LOOKAHEAD_FRAMES)
  ) effects (
    .clk,
    .rst,
    .effect_clear_i(effect_clear),
    .config_i(audio_config),
    .in_valid(raw_mix_valid),
    .in_ready(effects_in_ready),
    .in_l(raw_mix_l),
    .in_r(raw_mix_r),
    .out_valid(sample_valid),
    .out_ready(sample_ready),
    .out_l(sample_l),
    .out_r(sample_r),
    .busy(effects_busy),
    .diagnostics_o(audio_diagnostics)
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
