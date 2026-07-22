module wavetable_system_core #(
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
  output logic [15:0]              mem_response_trace_latency
);
  logic mem_req_valid;
  logic [synth_pkg::VOICE_ID_WIDTH-1:0] mem_req_voice;
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

  assign mem_req.valid = mem_req_valid;
  assign mem_req.voice = mem_req_voice;
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
    .sample_tick,
    .sample_valid,
    .sample_l,
    .sample_r,
    .busy,
    .mem_req_valid,
    .mem_req_voice,
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
endmodule
