`timescale 1ns/1ps

module tb_wavetable_common_status_regs;
  import synth_pkg::*;
  import synth_register_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic core_reset = 1'b0;
  reg_bus_req_t bus_req;
  reg_bus_rsp_t bus_rsp;
  logic core_sample_valid;
  logic core_busy;
  logic render_inflight;
  logic render_deadline_miss_pulse;
  logic render_latency_valid;
  logic [15:0] render_latency_cycles;
  logic ext_req_valid;
  logic ext_req_ready;
  logic ext_rsp_valid;
  logic i2s_sample_ready;
  logic fifo_sample_valid;
  logic underrun_pulse;
  logic sample_drop_pulse;
  logic mem_response_trace_pulse;
  logic [15:0] mem_response_trace_latency;
  logic [3:0] output_fifo_level;
  logic playback_started;
  logic [31:0] audio_lead;
  logic [3:0] minimum_fifo_level;
  logic [31:0] command_error_count;
  logic [31:0] stale_generation_count;
  audio_diagnostics_t audio_diagnostics;
  sample_window_diagnostics_t sample_window_diagnostics;
  logic diagnostics_clear_pulse;

  always #5 clk <= ~clk;

  wavetable_common_status_regs #(
    .OUTPUT_FIFO_DEPTH(8)
  ) dut (
    .clk,
    .rst,
    .core_reset,
    .bus_req,
    .bus_rsp,
    .core_sample_valid,
    .core_busy,
    .render_inflight,
    .render_deadline_miss_pulse,
    .render_latency_valid,
    .render_latency_cycles,
    .ext_req_valid,
    .ext_req_ready,
    .ext_rsp_valid,
    .i2s_sample_ready,
    .fifo_sample_valid,
    .underrun_pulse,
    .sample_drop_pulse,
    .mem_response_trace_pulse,
    .mem_response_trace_latency,
    .output_fifo_level,
    .playback_started,
    .audio_lead,
    .minimum_fifo_level,
    .command_error_count,
    .stale_generation_count,
    .audio_diagnostics,
    .sample_window_diagnostics,
    .diagnostics_clear_pulse
  );

  task automatic expect_read(input logic [15:0] address,
                             input logic [31:0] expected);
    begin
      bus_req = '{valid: 1'b1, write: 1'b0, address: address, wdata: '0};
      #1;
      if (!bus_rsp.ready || bus_rsp.error || bus_rsp.rdata !== expected)
        $fatal(1, "read 0x%04x got ready=%0b error=%0b data=0x%08x expected=0x%08x",
               address, bus_rsp.ready, bus_rsp.error, bus_rsp.rdata, expected);
      bus_req = '0;
    end
  endtask

  task automatic write_flags(input logic [31:0] mask);
    begin
      @(negedge clk);
      bus_req = '{valid: 1'b1, write: 1'b1,
                  address: REG_COMMON_EVENT_FLAGS, wdata: mask};
      @(posedge clk);
      #1;
      bus_req = '0;
    end
  endtask

  task automatic clear_diagnostics;
    begin
      @(negedge clk);
      bus_req = '{valid: 1'b1, write: 1'b1,
                  address: REG_DIAGNOSTIC_CONTROL,
                  wdata: REG_DIAGNOSTIC_CONTROL_CLEAR_MASK};
      @(posedge clk);
      #1;
      bus_req = '0;
      if (!diagnostics_clear_pulse)
        $fatal(1, "diagnostic clear did not produce a pulse");
      @(posedge clk);
      #1;
      if (diagnostics_clear_pulse)
        $fatal(1, "diagnostic clear pulse lasted more than one cycle");
    end
  endtask

  initial begin
    bus_req = '0;
    core_sample_valid = 1'b0;
    core_busy = 1'b0;
    render_inflight = 1'b0;
    render_deadline_miss_pulse = 1'b0;
    render_latency_valid = 1'b0;
    render_latency_cycles = '0;
    ext_req_valid = 1'b0;
    ext_req_ready = 1'b0;
    ext_rsp_valid = 1'b0;
    i2s_sample_ready = 1'b0;
    fifo_sample_valid = 1'b0;
    underrun_pulse = 1'b0;
    sample_drop_pulse = 1'b0;
    mem_response_trace_pulse = 1'b0;
    mem_response_trace_latency = '0;
    output_fifo_level = '0;
    playback_started = 1'b0;
    audio_lead = '0;
    minimum_fifo_level = '0;
    command_error_count = '0;
    stale_generation_count = '0;
    audio_diagnostics = '0;
    sample_window_diagnostics = '0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    render_inflight = 1'b1;
    render_latency_cycles = 16'h1234;
    mem_response_trace_latency = 16'h5678;
    output_fifo_level = 4'd5;
    expect_read(REG_SYSTEM_STATUS, 32'h0000_0502);
    expect_read(REG_PIPELINE_LATENCY_STATUS, 32'h5678_1234);

    playback_started = 1'b1;
    minimum_fifo_level = 4'd2;
    audio_lead = 32'd47;
    command_error_count = 32'd3;
    stale_generation_count = 32'd9;
    expect_read(REG_AUDIO_FIFO_DIAGNOSTICS, 32'h0001_0205);
    expect_read(REG_AUDIO_LEAD, 32'd47);
    expect_read(REG_COMMAND_ERROR_COUNT, 32'd3);
    expect_read(REG_STALE_GENERATION_COUNT, 32'd9);

    @(negedge clk);
    render_latency_valid = 1'b1;
    mem_response_trace_pulse = 1'b1;
    @(posedge clk);
    #1;
    render_latency_valid = 1'b0;
    mem_response_trace_pulse = 1'b0;
    expect_read(REG_PIPELINE_LATENCY_MAX, 32'h5678_1234);
    write_flags(REG_COMMON_EVENT_FLAGS_MEM_RESPONSE_MASK);
    expect_read(REG_COMMON_EVENT_FLAGS, 32'd0);

    @(negedge clk);
    render_latency_cycles = 16'h0100;
    mem_response_trace_latency = 16'h0200;
    render_latency_valid = 1'b1;
    mem_response_trace_pulse = 1'b1;
    @(posedge clk);
    #1;
    render_latency_valid = 1'b0;
    mem_response_trace_pulse = 1'b0;
    expect_read(REG_PIPELINE_LATENCY_MAX, 32'h5678_1234);
    write_flags(REG_COMMON_EVENT_FLAGS_MEM_RESPONSE_MASK);
    expect_read(REG_COMMON_EVENT_FLAGS, 32'd0);

    @(negedge clk);
    render_deadline_miss_pulse = 1'b1;
    @(posedge clk);
    #1;
    render_deadline_miss_pulse = 1'b0;
    expect_read(REG_COMMON_EVENT_FLAGS,
                REG_COMMON_EVENT_FLAGS_RENDER_DEADLINE_MISS_MASK);
    expect_read(REG_RENDER_DEADLINE_MISS_COUNT, 32'd1);

    write_flags(REG_COMMON_EVENT_FLAGS_RENDER_DEADLINE_MISS_MASK);
    expect_read(REG_COMMON_EVENT_FLAGS, 32'd0);

    @(negedge clk);
    render_deadline_miss_pulse = 1'b1;
    bus_req = '{valid: 1'b1, write: 1'b1,
                address: REG_COMMON_EVENT_FLAGS,
                wdata: REG_COMMON_EVENT_FLAGS_RENDER_DEADLINE_MISS_MASK};
    @(posedge clk);
    #1;
    render_deadline_miss_pulse = 1'b0;
    bus_req = '0;
    expect_read(REG_COMMON_EVENT_FLAGS,
                REG_COMMON_EVENT_FLAGS_RENDER_DEADLINE_MISS_MASK);
    expect_read(REG_RENDER_DEADLINE_MISS_COUNT, 32'd2);

    clear_diagnostics();
    expect_read(REG_COMMON_EVENT_FLAGS, 32'd0);
    expect_read(REG_RENDER_DEADLINE_MISS_COUNT, 32'd0);
    expect_read(REG_MEM_RESPONSE_COUNT, 32'd0);
    expect_read(REG_PIPELINE_LATENCY_MAX, 32'd0);

    @(negedge clk);
    core_reset = 1'b1;
    @(posedge clk);
    #1;
    core_reset = 1'b0;
    expect_read(REG_COMMON_EVENT_FLAGS, 32'd0);

    sample_window_diagnostics = '{
      client_request_count: 32'd11,
      window_hit_count: 32'd7,
      window_refill_count: 32'd2,
      fallback_read_count: 32'd2,
      memory_read_count: 32'd66,
      eviction_count: 32'd1,
      stall_cycle_count: 32'd9
    };
    expect_read(REG_SAMPLE_WINDOW_REQUEST_COUNT, 32'd11);
    expect_read(REG_SAMPLE_WINDOW_HIT_COUNT, 32'd7);
    expect_read(REG_SAMPLE_WINDOW_REFILL_COUNT, 32'd2);
    expect_read(REG_SAMPLE_WINDOW_FALLBACK_READ_COUNT, 32'd2);
    expect_read(REG_SAMPLE_WINDOW_MEMORY_READ_COUNT, 32'd66);
    expect_read(REG_SAMPLE_WINDOW_EVICTION_COUNT, 32'd1);
    expect_read(REG_SAMPLE_WINDOW_STALL_CYCLE_COUNT, 32'd9);

    $display("PASS: wavetable_common_status_regs");
    $finish;
  end
endmodule
