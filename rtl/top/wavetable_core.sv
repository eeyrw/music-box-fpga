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
  synth_pkg::voice_config_t active_config;
  logic config_valid;
  logic commit_pulse;

  voice_register_bank registers (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .active_config,
    .config_valid,
    .commit_pulse
  );

  voice_pipeline voice (
    .clk,
    .rst,
    .voice_config(active_config),
    .config_valid,
    .config_commit(commit_pulse),
    .sample_tick,
    .busy,
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
