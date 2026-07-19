module wavetable_cached_render_core #(
  parameter int LINE_WORDS = 8
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
  input  logic                     sample_tick,
  output logic                     sample_valid,
  output synth_pkg::pcm_t          sample_l,
  output synth_pkg::pcm_t          sample_r,
  output logic                     busy,
  output logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  output logic [31:0]              ext_req_addr,
  input  logic                     ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0] ext_rsp_data,
  output logic                     mem_debug_response_pulse,
  output logic [15:0]              mem_debug_response_latency
);
  logic mem_req_valid;
  logic [31:0] mem_req_addr;
  logic mem_req_ready;
  logic mem_rsp_valid;
  synth_pkg::pcm_t mem_rsp_data;

  wavetable_render_core core (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .sample_tick,
    .sample_valid,
    .sample_l,
    .sample_r,
    .busy,
    .mem_req_valid,
    .mem_req_addr,
    .mem_req_ready,
    .mem_rsp_valid,
    .mem_rsp_data
  );

  wave_memory_subsystem #(.LINE_WORDS(LINE_WORDS)) memory (
    .clk,
    .rst,
    .core_req_valid(mem_req_valid),
    .core_req_ready(mem_req_ready),
    .core_req_addr(mem_req_addr),
    .core_rsp_valid(mem_rsp_valid),
    .core_rsp_data(mem_rsp_data),
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .debug_response_pulse(mem_debug_response_pulse),
    .debug_response_latency(mem_debug_response_latency)
  );
endmodule
