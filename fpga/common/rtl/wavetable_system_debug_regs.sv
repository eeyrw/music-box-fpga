module wavetable_system_debug_regs #(
  parameter int OUTPUT_FIFO_DEPTH = 8
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     core_reset,
  input  logic                     bus_valid,
  input  logic                     bus_write,
  input  logic [15:0]              bus_address,
  input  logic [31:0]              bus_wdata,
  output logic                     debug_access,
  output logic [31:0]              debug_rdata,
  input  logic                     sample_tick,
  input  logic                     core_sample_valid,
  input  logic                     core_busy,
  input  logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  input  logic                     ext_rsp_valid,
  input  logic                     i2s_sample_ready,
  input  logic                     fifo_sample_valid,
  input  logic                     underrun_pulse,
  input  logic                     sample_drop_pulse,
  input  logic                     mem_debug_hit_pulse,
  input  logic                     mem_debug_miss_pulse,
  input  logic                     mem_debug_response_pulse,
  input  logic [15:0]              mem_debug_response_latency,
  input  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic                     render_deadline_miss_pulse,
  output logic [15:0]              render_latency_cycles
);
  import synth_register_pkg::*;

  localparam logic [15:0] ADDR_SYSTEM_STATUS = REG_SYSTEM_STATUS;
  localparam logic [15:0] ADDR_DEBUG_EVENT_FLAGS = REG_DEBUG_EVENT_FLAGS;
  localparam logic [15:0] ADDR_AUDIO_STATUS = REG_AUDIO_STATUS;
  localparam logic [15:0] ADDR_RENDER_STATUS = REG_RENDER_STATUS;
  localparam logic [15:0] ADDR_MEMORY_STATUS = REG_MEMORY_STATUS;
  localparam logic [15:0] ADDR_UNDERRUN_COUNT = REG_UNDERRUN_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_DROP_COUNT = REG_SAMPLE_DROP_COUNT;
  localparam logic [15:0] ADDR_RENDER_DEADLINE_MISS_COUNT = REG_RENDER_DEADLINE_MISS_COUNT;
  localparam logic [15:0] ADDR_MEM_HIT_COUNT = REG_MEM_HIT_COUNT;
  localparam logic [15:0] ADDR_MEM_MISS_COUNT = REG_MEM_MISS_COUNT;
  localparam logic [15:0] ADDR_MEM_RESPONSE_COUNT = REG_MEM_RESPONSE_COUNT;

  logic render_pending;
  logic [15:0] render_latency_count;
  logic [31:0] debug_event_flags;
  logic [31:0] underrun_count;
  logic [31:0] sample_drop_count;
  logic [31:0] render_deadline_miss_count;
  logic [31:0] mem_hit_count;
  logic [31:0] mem_miss_count;
  logic [31:0] mem_response_count;
  logic [31:0] debug_event_set_mask;

  function automatic logic is_system_debug_address(input logic [15:0] address);
    unique case (address)
      ADDR_SYSTEM_STATUS, ADDR_DEBUG_EVENT_FLAGS, ADDR_AUDIO_STATUS,
      ADDR_RENDER_STATUS, ADDR_MEMORY_STATUS, ADDR_UNDERRUN_COUNT,
      ADDR_SAMPLE_DROP_COUNT, ADDR_RENDER_DEADLINE_MISS_COUNT,
      ADDR_MEM_HIT_COUNT, ADDR_MEM_MISS_COUNT, ADDR_MEM_RESPONSE_COUNT: begin
        is_system_debug_address = 1'b1;
      end
      default: is_system_debug_address = 1'b0;
    endcase
  endfunction

  function automatic logic [31:0] sat_inc(input logic [31:0] value);
    sat_inc = (value == 32'hffff_ffff) ? value : value + 32'd1;
  endfunction

  assign debug_access = bus_valid && is_system_debug_address(bus_address);
  assign debug_event_set_mask = {
    26'd0,
    mem_debug_response_pulse,
    mem_debug_miss_pulse,
    mem_debug_hit_pulse,
    sample_tick && render_pending && !core_sample_valid,
    sample_drop_pulse,
    underrun_pulse
  };

  always_comb begin
    debug_rdata = 32'd0;
    unique case (bus_address)
      ADDR_SYSTEM_STATUS: begin
        debug_rdata = {
          24'd0,
          ext_rsp_valid,
          ext_req_ready,
          ext_req_valid,
          i2s_sample_ready,
          fifo_sample_valid,
          core_sample_valid,
          render_pending,
          core_busy
        };
      end
      ADDR_DEBUG_EVENT_FLAGS: debug_rdata = debug_event_flags;
      ADDR_AUDIO_STATUS: begin
        debug_rdata = {
          14'd0,
          debug_event_flags[1],
          debug_event_flags[0],
          16'(output_fifo_level)
        };
      end
      ADDR_RENDER_STATUS: begin
        debug_rdata = {14'd0, debug_event_flags[2], render_pending, render_latency_cycles};
      end
      ADDR_MEMORY_STATUS: begin
        debug_rdata = {
          10'd0,
          debug_event_flags[5],
          debug_event_flags[4],
          debug_event_flags[3],
          ext_rsp_valid,
          ext_req_ready,
          ext_req_valid,
          mem_debug_response_latency
        };
      end
      ADDR_UNDERRUN_COUNT: debug_rdata = underrun_count;
      ADDR_SAMPLE_DROP_COUNT: debug_rdata = sample_drop_count;
      ADDR_RENDER_DEADLINE_MISS_COUNT: debug_rdata = render_deadline_miss_count;
      ADDR_MEM_HIT_COUNT: debug_rdata = mem_hit_count;
      ADDR_MEM_MISS_COUNT: debug_rdata = mem_miss_count;
      ADDR_MEM_RESPONSE_COUNT: debug_rdata = mem_response_count;
      default: debug_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      render_pending <= 1'b0;
      render_latency_count <= '0;
      render_latency_cycles <= '0;
      render_deadline_miss_pulse <= 1'b0;
      debug_event_flags <= 32'd0;
      underrun_count <= 32'd0;
      sample_drop_count <= 32'd0;
      render_deadline_miss_count <= 32'd0;
      mem_hit_count <= 32'd0;
      mem_miss_count <= 32'd0;
      mem_response_count <= 32'd0;
    end else begin
      render_deadline_miss_pulse <= 1'b0;

      if (debug_access && bus_write && (bus_address == ADDR_DEBUG_EVENT_FLAGS)) begin
        debug_event_flags <= (debug_event_flags & ~bus_wdata) | debug_event_set_mask;
      end else begin
        debug_event_flags <= debug_event_flags | debug_event_set_mask;
      end

      if (underrun_pulse)
        underrun_count <= sat_inc(underrun_count);
      if (sample_drop_pulse)
        sample_drop_count <= sat_inc(sample_drop_count);
      if (sample_tick && render_pending && !core_sample_valid)
        render_deadline_miss_count <= sat_inc(render_deadline_miss_count);
      if (mem_debug_hit_pulse)
        mem_hit_count <= sat_inc(mem_hit_count);
      if (mem_debug_miss_pulse)
        mem_miss_count <= sat_inc(mem_miss_count);
      if (mem_debug_response_pulse)
        mem_response_count <= sat_inc(mem_response_count);

      if (core_reset) begin
        render_pending <= 1'b0;
        render_latency_count <= '0;
        render_latency_cycles <= '0;
      end else begin
        render_deadline_miss_pulse <= sample_tick && render_pending && !core_sample_valid;

        if (sample_tick) begin
          render_pending <= 1'b1;
          render_latency_count <= '0;
        end else if (core_sample_valid) begin
          render_pending <= 1'b0;
          render_latency_cycles <= render_latency_count;
        end else if (render_pending && render_latency_count != 16'hffff) begin
          render_latency_count <= render_latency_count + 1'b1;
        end
      end
    end
  end
endmodule
