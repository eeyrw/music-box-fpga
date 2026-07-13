module wavetable_core (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     bus_valid,
  input  logic                     bus_write,
  input  logic [15:0]              bus_address,
  input  logic [31:0]              bus_wdata,
  output logic [31:0]              bus_rdata,
  output logic                     bus_ready,
  output logic                     bus_error,
  input  logic                     sample_tick,
  output logic                     sample_valid,
  output synth_pkg::pcm_t          sample_l,
  output synth_pkg::pcm_t          sample_r,
  output logic                     busy,
  output logic                     mem_req_valid,
  output logic [31:0]              mem_req_addr,
  input  logic                     mem_req_ready,
  input  logic                     mem_rsp_valid,
  input  synth_pkg::pcm_t          mem_rsp_data
);
  localparam int VOICE_INDEX_WIDTH = $clog2(synth_pkg::NUM_VOICES);

  synth_pkg::voice_config_t render_config;
  synth_pkg::voice_runtime_t render_runtime;
  logic [VOICE_INDEX_WIDTH-1:0] voice_read_index;
  logic [synth_pkg::NUM_VOICES-1:0] config_valid;
  logic [synth_pkg::NUM_VOICES-1:0] commit_pulse;
  logic voices_busy;
  logic frame_boundary;

  assign frame_boundary = sample_tick && !voices_busy;
  assign busy = voices_busy;

  voice_register_bank registers (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .frame_boundary,
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .render_voice_index(voice_read_index),
    .render_config,
    .render_runtime,
    .config_valid,
    .commit_pulse
  );

  multi_voice_pipeline voices (
    .clk,
    .rst,
    .voice_read_index,
    .voice_config(render_config),
    .voice_runtime(render_runtime),
    .config_valid,
    .config_commit(commit_pulse),
    .sample_tick,
    .busy(voices_busy),
    .sample_valid,
    .sample_l,
    .sample_r,
    .mem_req_valid,
    .mem_req_addr,
    .mem_req_ready,
    .mem_rsp_valid,
    .mem_rsp_data
  );
endmodule
