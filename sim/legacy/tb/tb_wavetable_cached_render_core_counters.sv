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
  logic cmd_stream_valid;
  logic [31:0] cmd_stream_data;
  logic cmd_stream_ready;
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
  cache_diagnostics_t cache_diagnostics;
  render_timing_diagnostics_t render_diagnostics;
  voice_pipeline_diagnostics_t voice_diagnostics;
  int dsp_ready_no_context_count = 0;

  logic unused_outputs;
  int errors = 0;

  assign unused_outputs = bus_ready | bus_error | (|bus_rdata) | (|sample_l) | (|sample_r) |
                          busy | ext_req_valid | (|ext_req_addr) |
                          (|cache_diagnostics) | (|render_diagnostics) |
                          (|voice_diagnostics);

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
    .cmd_stream_valid,
    .cmd_stream_data,
    .cmd_stream_ready,
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
    .cache_diagnostics,
    .render_diagnostics,
    .voice_diagnostics
  );

  always_ff @(posedge clk) begin
    if (rst)
      dsp_ready_no_context_count <= 0;
    else if (voice_diagnostics.dsp_ready_no_context_pulse)
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
    cmd_stream_valid = 1'b0;
    cmd_stream_data = '0;
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
    if (render_diagnostics.last_cycles == 32'd0) begin
      $error("last_render_cycles did not record a completed frame");
      errors++;
    end
    if (render_diagnostics.frame_count != 64'd1) begin
      $error("render_frame_count got %0d expected 1",
             render_diagnostics.frame_count);
      errors++;
    end
    if (render_diagnostics.max_cycles != render_diagnostics.last_cycles) begin
      $error("max_render_cycles got %0d expected %0d",
             render_diagnostics.max_cycles, render_diagnostics.last_cycles);
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
    if (render_diagnostics.deadline_miss_count != 64'd1) begin
      $error("deadline_miss_count got %0d expected 1",
             render_diagnostics.deadline_miss_count);
      errors++;
    end

    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    if (render_diagnostics.active || render_diagnostics.cycle_counter != 32'd0 ||
        render_diagnostics.last_cycles != 32'd0 ||
        render_diagnostics.max_cycles != 32'd0 ||
        render_diagnostics.cycle_sum != 64'd0 ||
        render_diagnostics.frame_count != 64'd0 ||
        render_diagnostics.deadline_miss_count != 64'd0 ||
        render_diagnostics.over_budget_frames != 64'd0 ||
        render_diagnostics.over_budget_max_cycles != 32'd0 ||
        voice_diagnostics.endpoint.fetch_slot_max_occupancy != 3'd0 ||
        voice_diagnostics.endpoint.word_req_max_occupancy != 5'd0 ||
        voice_diagnostics.endpoint.rsp_meta_max_occupancy != 5'd0 ||
        voice_diagnostics.endpoint.dsp_context_queue_max_occupancy != 3'd0 ||
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
