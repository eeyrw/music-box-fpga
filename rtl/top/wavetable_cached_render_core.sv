module wavetable_cached_render_core #(
  parameter int LINE_WORDS = 32,
  parameter int LINES_PER_VOICE = 2
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
  output logic                     mem_response_trace_pulse,
  output logic [15:0]              mem_response_trace_latency,
  output logic                     cache_demand_hit_pulse,
  output logic                     cache_demand_miss_pulse,
  output logic                     cache_line_fill_pulse,
  output logic                     cache_same_line_endpoint_hit_pulse,
  output logic                     cache_replacement_pulse
);
  logic mem_req_ready;
  synth_pkg::wave_word_req_t mem_req;
  synth_pkg::wave_word_rsp_t mem_rsp;

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
    .mem_req_valid(mem_req.valid),
    .mem_req_voice(mem_req.voice),
    .mem_req_addr(mem_req.addr),
    .mem_req_ready,
    .mem_rsp_valid(mem_rsp.valid),
    .mem_rsp_data(mem_rsp.data)
  );

  voice_line_cache #(
    .LINE_WORDS(LINE_WORDS),
    .LINES_PER_VOICE(LINES_PER_VOICE)
  ) memory (
    .clk,
    .rst,
    .req(mem_req),
    .req_ready(mem_req_ready),
    .rsp(mem_rsp),
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .response_trace_pulse(mem_response_trace_pulse),
    .response_trace_latency(mem_response_trace_latency),
    .demand_hit_pulse(cache_demand_hit_pulse),
    .demand_miss_pulse(cache_demand_miss_pulse),
    .line_fill_pulse(cache_line_fill_pulse),
    .same_line_endpoint_hit_pulse(cache_same_line_endpoint_hit_pulse),
    .replacement_pulse(cache_replacement_pulse)
  );
endmodule
