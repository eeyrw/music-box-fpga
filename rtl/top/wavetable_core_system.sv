module wavetable_core_system #(
  parameter int LINE_WORDS = 8,
  parameter int OUTPUT_FIFO_DEPTH = 8,
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     spi_sclk,
  input  logic                     spi_cs_n,
  input  logic                     spi_mosi,
  output logic                     spi_miso,
  output logic                     spi_error,
  output logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  output logic [31:0]              ext_req_addr,
  input  logic                     ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0] ext_rsp_data,
  output logic                     i2s_bclk,
  output logic                     i2s_lrclk,
  output logic                     i2s_sdata,
  output logic                     underrun_pulse,
  output logic                     sample_drop_pulse,
  output logic                     mem_debug_hit_pulse,
  output logic                     mem_debug_miss_pulse,
  output logic                     mem_debug_response_pulse,
  output logic [15:0]              mem_debug_response_latency,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic                     render_deadline_miss_pulse,
  output logic [15:0]              render_latency_cycles
);
  logic sample_tick;
  logic bus_valid;
  logic bus_write;
  logic [15:0] bus_address;
  logic [31:0] bus_wdata;
  logic [31:0] bus_rdata;
  logic bus_ready;
  logic bus_error;
  logic core_sample_valid;
  synth_pkg::pcm_t core_sample_l;
  synth_pkg::pcm_t core_sample_r;
/* verilator lint_off UNUSEDSIGNAL */
  logic core_busy;
/* verilator lint_on UNUSEDSIGNAL */
  logic i2s_sample_ready;
/* verilator lint_off UNUSEDSIGNAL */
  logic fifo_input_ready;
/* verilator lint_on UNUSEDSIGNAL */
  logic fifo_sample_valid;
  logic fifo_sample_ready;
  synth_pkg::pcm_t fifo_sample_l;
  synth_pkg::pcm_t fifo_sample_r;
  logic render_pending;
  logic [15:0] render_latency_count;

  fractional_tick_gen #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .TICK_HZ(SAMPLE_RATE_HZ)
  ) sample_tick_gen (
    .clk,
    .rst,
    .tick(sample_tick)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      render_pending <= 1'b0;
      render_latency_count <= '0;
      render_latency_cycles <= '0;
      render_deadline_miss_pulse <= 1'b0;
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

  spi_register_bridge spi_bridge (
    .clk,
    .rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso,
    .spi_error,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error
  );

  wavetable_core_memory #(.LINE_WORDS(LINE_WORDS)) core (
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
    .sample_valid(core_sample_valid),
    .sample_l(core_sample_l),
    .sample_r(core_sample_r),
    .busy(core_busy),
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .mem_debug_hit_pulse,
    .mem_debug_miss_pulse,
    .mem_debug_response_pulse,
    .mem_debug_response_latency
  );

  output_sample_fifo #(.DEPTH(OUTPUT_FIFO_DEPTH)) output_fifo (
    .clk,
    .rst,
    .in_valid(core_sample_valid),
    .in_ready(fifo_input_ready),
    .in_l(core_sample_l),
    .in_r(core_sample_r),
    .out_valid(fifo_sample_valid),
    .out_ready(fifo_sample_ready),
    .out_l(fifo_sample_l),
    .out_r(fifo_sample_r),
    .overflow_pulse(sample_drop_pulse),
    .level(output_fifo_level)
  );

  assign fifo_sample_ready = fifo_sample_valid && i2s_sample_ready;

  i2s_tx #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) audio_tx (
    .clk,
    .rst,
    .sample_valid(fifo_sample_valid && i2s_sample_ready),
    .sample_ready(i2s_sample_ready),
    .sample_l(fifo_sample_l),
    .sample_r(fifo_sample_r),
    .underrun_pulse,
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata
  );

endmodule
