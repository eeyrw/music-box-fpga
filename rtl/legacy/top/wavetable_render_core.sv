module wavetable_render_core #(
  parameter int LINE_WORDS = 32
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
  output synth_pkg::pcm_t          sample_l,
  output synth_pkg::pcm_t          sample_r,
  output synth_pkg::mix_t          mix_l,
  output synth_pkg::mix_t          mix_r,
  output synth_pkg::global_audio_config_t audio_config,
  output logic [1:0]                effect_clear,
  output logic                     busy,
  output synth_pkg::wave_word_req_t mem_req,
  input  logic                     mem_req_ready,
  input  synth_pkg::wave_word_rsp_t mem_rsp,
  output synth_pkg::voice_pipeline_diagnostics_t voice_diagnostics
);
  localparam int VOICE_INDEX_WIDTH = $clog2(synth_pkg::NUM_VOICES);

  synth_pkg::voice_config_t render_config;
  synth_pkg::voice_runtime_t render_runtime;
  logic [VOICE_INDEX_WIDTH-1:0] voice_read_index;
  logic [synth_pkg::NUM_VOICES-1:0] config_valid;
  logic [synth_pkg::NUM_VOICES-1:0] commit_pulse;
  logic voices_busy;
  logic frame_request;
  logic frame_start;
  logic control_busy;
  logic [31:0] sample_counter;
  logic [31:0] current_render_sample;
  logic runtime_snapshot_prepare;
  logic [VOICE_INDEX_WIDTH-1:0] runtime_snapshot_voice;
  logic runtime_snapshot_valid;
  synth_pkg::reg_bus_req_t bus_req;
  synth_pkg::reg_bus_rsp_t bus_rsp;

  assign frame_request = sample_tick && !voices_busy && !control_busy;
  assign busy = voices_busy || control_busy;
  assign bus_req.valid = bus_valid;
  assign bus_req.write = bus_write;
  assign bus_req.address = bus_address;
  assign bus_req.wdata = bus_wdata;
  assign bus_rdata = bus_rsp.rdata;
  assign bus_ready = bus_rsp.ready;
  assign bus_error = bus_rsp.error;

  synth_control_plane control_plane (
    .clk,
    .rst,
    .bus_req,
    .cmd_stream_valid,
    .cmd_stream_data,
    .cmd_stream_ready,
    .frame_request,
    .renderer_busy(voices_busy),
    .frame_start,
    .control_busy,
    .bus_rsp,
    .render_voice_index(voice_read_index),
    .runtime_snapshot_prepare,
    .runtime_snapshot_voice,
    .runtime_snapshot_valid,
    .current_sample(current_render_sample),
    .render_config,
    .render_runtime,
    .audio_config,
    .effect_clear,
    .config_valid,
    .commit_pulse
  );

  multi_voice_pipeline #(
    .LINE_WORDS(LINE_WORDS)
  ) voices (
    .clk,
    .rst,
    .voice_read_index,
    .runtime_snapshot_prepare,
    .runtime_snapshot_voice,
    .runtime_snapshot_valid,
    .voice_config(render_config),
    .voice_runtime(render_runtime),
    .config_valid,
    .config_commit(commit_pulse),
    .sample_tick(frame_start),
    .busy(voices_busy),
    .sample_valid,
    .sample_l,
    .sample_r,
    .mix_l,
    .mix_r,
    .mem_req,
    .mem_req_ready,
    .mem_rsp,
    .diagnostics_o(voice_diagnostics)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      sample_counter <= 32'd0;
      current_render_sample <= 32'd0;
    end else if (frame_start) begin
      current_render_sample <= sample_counter;
      sample_counter <= sample_counter + 32'd1;
    end
  end
endmodule
