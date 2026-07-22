module tb_wavetable_cached_render_core_counters;
  import synth_pkg::*;

  localparam int LINE_WORDS = 32;
  localparam int CLK_HZ = 100_000_000;
  localparam int SAMPLE_RATE = 48_000;
  localparam int SAMPLE_TIMEOUT_CYCLES = 512 + (NUM_VOICES * 4);

  logic clk = 1'b0;
  logic rst;
  logic bus_valid;
  logic bus_write;
  logic [15:0] bus_address;
  logic [31:0] bus_wdata;
  logic [31:0] bus_rdata;
  logic bus_ready;
  logic bus_error;
  logic sample_tick;
  logic sample_valid;
  pcm_t sample_l;
  pcm_t sample_r;
  logic busy;
  logic ext_req_valid;
  logic ext_req_ready;
  logic [31:0] ext_req_addr;
  logic ext_rsp_valid;
  logic [LINE_WORDS*16-1:0] ext_rsp_data;
  logic mem_response_trace_pulse;
  logic [15:0] mem_response_trace_latency;
  logic cache_demand_hit_pulse;
  logic cache_demand_miss_pulse;
  logic cache_line_fill_pulse;
  logic cache_same_line_endpoint_hit_pulse;
  logic cache_replacement_pulse;
  logic cache_prefetch_issued_pulse;
  logic cache_prefetch_filled_pulse;
  logic cache_prefetch_used_pulse;
  logic cache_prefetch_dropped_pulse;
  logic cache_prefetch_late_pulse;
  logic render_active;
  logic [31:0] render_cycle_counter;
  logic [31:0] last_render_cycles;
  logic [31:0] max_render_cycles;
  logic [63:0] render_cycle_sum;
  logic [63:0] render_frame_count;
  logic [63:0] deadline_miss_count;
  logic [63:0] over_budget_frames;
  logic [31:0] over_budget_max_cycles;
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
  int dsp_ready_no_context_count = 0;

  logic unused_outputs;
  int errors = 0;

  assign unused_outputs = bus_ready | bus_error | (|bus_rdata) | (|sample_l) | (|sample_r) |
                          busy | ext_req_valid | (|ext_req_addr) | mem_response_trace_pulse |
                          (|mem_response_trace_latency) | cache_demand_hit_pulse |
                          cache_demand_miss_pulse | cache_line_fill_pulse |
                          cache_same_line_endpoint_hit_pulse | cache_replacement_pulse |
                          cache_prefetch_issued_pulse | cache_prefetch_filled_pulse |
                          cache_prefetch_used_pulse | cache_prefetch_dropped_pulse |
                          cache_prefetch_late_pulse |
                          render_active | (|render_cycle_counter) | (|render_cycle_sum) |
                          (|over_budget_frames) | (|over_budget_max_cycles) |
                          endpoint_cross_line_pair_pulse | endpoint_fetch_slot_pressure_pulse |
                          endpoint_memory_stall_pulse | (|endpoint_fetch_slot_occupancy) |
                          (|endpoint_fetch_slot_max_occupancy) | (|endpoint_word_req_occupancy) |
                          (|endpoint_word_req_max_occupancy) | (|endpoint_rsp_meta_occupancy) |
                          (|endpoint_rsp_meta_max_occupancy) | (|dsp_context_queue_occupancy) |
                          (|dsp_context_queue_max_occupancy) | dsp_ready_no_context_pulse;

  always #5 clk <= ~clk;

  wavetable_cached_render_core #(
    .LINE_WORDS(LINE_WORDS),
    .LINES_PER_VOICE(2),
    .CLK_HZ(CLK_HZ),
    .SAMPLE_RATE(SAMPLE_RATE)
  ) dut (
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
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .mem_response_trace_pulse,
    .mem_response_trace_latency,
    .cache_demand_hit_pulse,
    .cache_demand_miss_pulse,
    .cache_line_fill_pulse,
    .cache_same_line_endpoint_hit_pulse,
    .cache_replacement_pulse,
    .cache_prefetch_issued_pulse,
    .cache_prefetch_filled_pulse,
    .cache_prefetch_used_pulse,
    .cache_prefetch_dropped_pulse,
    .cache_prefetch_late_pulse,
    .render_active,
    .render_cycle_counter,
    .last_render_cycles,
    .max_render_cycles,
    .render_cycle_sum,
    .render_frame_count,
    .deadline_miss_count,
    .over_budget_frames,
    .over_budget_max_cycles,
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

  always_ff @(posedge clk) begin
    if (rst)
      dsp_ready_no_context_count <= 0;
    else if (dsp_ready_no_context_pulse)
      dsp_ready_no_context_count <= dsp_ready_no_context_count + 1;
  end

  task automatic pulse_sample_tick;
    begin
      @(negedge clk);
      sample_tick = 1'b1;
      @(negedge clk);
      sample_tick = 1'b0;
    end
  endtask

  task automatic wait_sample_valid;
    int timeout;
    begin
      timeout = 0;
      while (!sample_valid && timeout < SAMPLE_TIMEOUT_CYCLES) begin
        @(negedge clk);
        timeout++;
      end
      if (!sample_valid) begin
        $error("sample_valid timed out");
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    bus_valid = 1'b0;
    bus_write = 1'b0;
    bus_address = '0;
    bus_wdata = '0;
    sample_tick = 1'b0;
    ext_req_ready = 1'b1;
    ext_rsp_valid = 1'b0;
    ext_rsp_data = '0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    pulse_sample_tick();
    wait_sample_valid();
    @(negedge clk);
    if (last_render_cycles == 32'd0) begin
      $error("last_render_cycles did not record a completed frame");
      errors++;
    end
    if (render_frame_count != 64'd1) begin
      $error("render_frame_count got %0d expected 1", render_frame_count);
      errors++;
    end
    if (max_render_cycles != last_render_cycles) begin
      $error("max_render_cycles got %0d expected %0d", max_render_cycles, last_render_cycles);
      errors++;
    end
    if (dsp_ready_no_context_count == 0) begin
      $error("dsp_ready_no_context_count did not observe scheduler bubbles");
      errors++;
    end

    pulse_sample_tick();
    repeat (2) @(negedge clk);
    pulse_sample_tick();
    wait_sample_valid();
    @(negedge clk);
    if (deadline_miss_count != 64'd1) begin
      $error("deadline_miss_count got %0d expected 1", deadline_miss_count);
      errors++;
    end

    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    if (render_active || render_cycle_counter != 32'd0 || last_render_cycles != 32'd0 ||
        max_render_cycles != 32'd0 || render_cycle_sum != 64'd0 ||
        render_frame_count != 64'd0 || deadline_miss_count != 64'd0 ||
        over_budget_frames != 64'd0 || over_budget_max_cycles != 32'd0 ||
        endpoint_fetch_slot_max_occupancy != 3'd0 ||
        endpoint_word_req_max_occupancy != 5'd0 ||
        endpoint_rsp_meta_max_occupancy != 5'd0 ||
        dsp_context_queue_max_occupancy != 3'd0 ||
        dsp_ready_no_context_count != 0) begin
      $error("render counters did not clear on reset");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: %0d errors", errors);
    $display("PASS: wavetable cached render core counters");
    $finish;
  end
endmodule
