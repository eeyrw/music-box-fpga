module wavetable_cached_render_core #(
  parameter int LINE_WORDS = 32,
  parameter int LINES_PER_VOICE = 2,
  parameter int CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE = 48_000
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
  output logic                     cache_replacement_pulse,
  output logic                     cache_prefetch_issued_pulse,
  output logic                     cache_prefetch_filled_pulse,
  output logic                     cache_prefetch_used_pulse,
  output logic                     cache_prefetch_dropped_pulse,
  output logic                     cache_prefetch_late_pulse,
  output logic                     render_active,
  output logic [31:0]              render_cycle_counter,
  output logic [31:0]              last_render_cycles,
  output logic [31:0]              max_render_cycles,
  output logic [63:0]              render_cycle_sum,
  output logic [63:0]              render_frame_count,
  output logic [63:0]              deadline_miss_count,
  output logic [63:0]              over_budget_frames,
  output logic [31:0]              over_budget_max_cycles,
  output logic                     endpoint_cross_line_pair_pulse,
  output logic                     endpoint_fetch_slot_pressure_pulse,
  output logic                     endpoint_memory_stall_pulse,
  output logic [2:0]               endpoint_fetch_slot_occupancy,
  output logic [2:0]               endpoint_fetch_slot_max_occupancy,
  output logic [4:0]               endpoint_word_req_occupancy,
  output logic [4:0]               endpoint_word_req_max_occupancy,
  output logic [4:0]               endpoint_rsp_meta_occupancy,
  output logic [4:0]               endpoint_rsp_meta_max_occupancy,
  output logic [2:0]               dsp_context_queue_occupancy,
  output logic [2:0]               dsp_context_queue_max_occupancy,
  output logic                     dsp_ready_no_context_pulse
);
  localparam int FRAME_BUDGET_CYCLES = CLK_HZ / SAMPLE_RATE;

  logic mem_req_ready;
  synth_pkg::wave_word_req_t mem_req;
  synth_pkg::wave_word_rsp_t mem_rsp;
  logic sample_tick_accepted;

  assign sample_tick_accepted = sample_tick && !busy;

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
    .mem_req_valid(mem_req.valid),
    .mem_req_voice(mem_req.voice),
    .mem_req_addr(mem_req.addr),
    .mem_req_ready,
    .mem_rsp_valid(mem_rsp.valid),
    .mem_rsp_data(mem_rsp.data),
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
    .replacement_pulse(cache_replacement_pulse),
    .prefetch_issued_pulse(cache_prefetch_issued_pulse),
    .prefetch_filled_pulse(cache_prefetch_filled_pulse),
    .prefetch_used_pulse(cache_prefetch_used_pulse),
    .prefetch_dropped_pulse(cache_prefetch_dropped_pulse),
    .prefetch_late_pulse(cache_prefetch_late_pulse)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      render_active <= 1'b0;
      render_cycle_counter <= 32'd0;
      last_render_cycles <= 32'd0;
      max_render_cycles <= 32'd0;
      render_cycle_sum <= 64'd0;
      render_frame_count <= 64'd0;
      deadline_miss_count <= 64'd0;
      over_budget_frames <= 64'd0;
      over_budget_max_cycles <= 32'd0;
    end else begin
      if (sample_tick && render_active && !sample_valid)
        deadline_miss_count <= deadline_miss_count + 64'd1;

      if (sample_valid && render_active) begin
        last_render_cycles <= render_cycle_counter;
        render_cycle_sum <= render_cycle_sum + 64'(render_cycle_counter);
        render_frame_count <= render_frame_count + 64'd1;
        if (render_cycle_counter > max_render_cycles)
          max_render_cycles <= render_cycle_counter;
        if (render_cycle_counter > 32'(FRAME_BUDGET_CYCLES)) begin
          over_budget_frames <= over_budget_frames + 64'd1;
          if ((render_cycle_counter - 32'(FRAME_BUDGET_CYCLES)) > over_budget_max_cycles)
            over_budget_max_cycles <= render_cycle_counter - 32'(FRAME_BUDGET_CYCLES);
        end
      end

      if (sample_valid) begin
        render_active <= sample_tick_accepted;
        render_cycle_counter <= sample_tick_accepted ? 32'd1 : 32'd0;
      end else if (sample_tick_accepted) begin
        render_active <= 1'b1;
        render_cycle_counter <= 32'd1;
      end else if (render_active && render_cycle_counter != 32'hffff_ffff) begin
        render_cycle_counter <= render_cycle_counter + 32'd1;
      end
    end
  end
endmodule
