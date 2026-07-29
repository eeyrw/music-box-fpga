module wavetable_demo_system #(
  parameter int LINE_WORDS = 32,
  parameter int OUTPUT_FIFO_DEPTH = 64,
  parameter int TARGET_LEVEL = 48,
  parameter int START_LEVEL = TARGET_LEVEL,
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000,
  parameter bit PLATFORM_REGS_PRESENT = 1'b0
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     core_rst,
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
  output logic                     mem_response_trace_pulse,
  output logic [15:0]              mem_response_trace_latency,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic                     playback_started,
  output logic                     render_inflight,
  output logic [31:0]              render_sample_counter,
  output logic [31:0]              played_sample_counter,
  output logic [31:0]              audio_lead,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] minimum_fifo_level,
  output logic                     render_deadline_miss_pulse,
  output logic [15:0]              render_latency_cycles,
  output logic                     platform_regs_bus_valid,
  output logic                     platform_regs_bus_write,
  output logic [15:0]              platform_regs_bus_address,
  output logic [31:0]              platform_regs_bus_wdata,
  input  logic [31:0]              platform_regs_bus_rdata,
  input  logic                     platform_regs_bus_ready,
  input  logic                     platform_regs_bus_error
);
  logic render_start;
  synth_pkg::reg_bus_req_t spi_bus_req;
  synth_pkg::reg_bus_rsp_t spi_bus_rsp;
  synth_pkg::reg_bus_req_t core_bus_req;
  synth_pkg::reg_bus_rsp_t core_bus_rsp;
  synth_pkg::reg_bus_req_t common_status_bus_req;
  synth_pkg::reg_bus_rsp_t common_status_bus_rsp;
  synth_pkg::reg_bus_req_t platform_regs_bus_req;
  synth_pkg::reg_bus_rsp_t platform_regs_bus_rsp;
  logic core_sample_valid;
  synth_pkg::pcm_t core_sample_l;
  synth_pkg::pcm_t core_sample_r;
  logic core_busy;
  logic i2s_sample_ready;
  logic fifo_sample_valid;
  logic core_sample_ready;
  logic render_credit;
  logic core_reset;
  logic spi_cmd_valid;
  logic [31:0] spi_cmd_data;
  logic spi_cmd_ready;
  synth_pkg::audio_diagnostics_t audio_diagnostics;

  assign core_reset = rst || core_rst;
  assign platform_regs_bus_valid = platform_regs_bus_req.valid;
  assign platform_regs_bus_write = platform_regs_bus_req.write;
  assign platform_regs_bus_address = platform_regs_bus_req.address;
  assign platform_regs_bus_wdata = platform_regs_bus_req.wdata;
  assign platform_regs_bus_rsp.rdata = platform_regs_bus_rdata;
  assign platform_regs_bus_rsp.ready = platform_regs_bus_ready;
  assign platform_regs_bus_rsp.error = platform_regs_bus_error;

  render_credit_scheduler #(
    .FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
    .TARGET_LEVEL(TARGET_LEVEL)
  ) scheduler (
    .clk,
    .rst(core_reset),
    .fifo_level(output_fifo_level),
    .renderer_busy(core_busy || core_sample_valid),
    .control_batch_complete(1'b1),
    .render_inflight,
    .render_credit,
    .render_start
  );

  spi_register_bridge spi_bridge (
    .clk,
    .rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso,
    .spi_error,
    .bus_valid(spi_bus_req.valid),
    .bus_write(spi_bus_req.write),
    .bus_address(spi_bus_req.address),
    .bus_wdata(spi_bus_req.wdata),
    .bus_rdata(spi_bus_rsp.rdata),
    .bus_ready(spi_bus_rsp.ready),
    .bus_error(spi_bus_rsp.error),
    .cmd_valid(spi_cmd_valid),
    .cmd_data(spi_cmd_data),
    .cmd_ready(spi_cmd_ready)
  );

  wavetable_register_fabric #(
    .PLATFORM_REGS_PRESENT(PLATFORM_REGS_PRESENT)
  ) register_fabric (
    .master_req(spi_bus_req),
    .core_reset,
    .master_rsp(spi_bus_rsp),
    .core_req(core_bus_req),
    .core_rsp(core_bus_rsp),
    .common_status_req(common_status_bus_req),
    .common_status_rsp(common_status_bus_rsp),
    .platform_regs_req(platform_regs_bus_req),
    .platform_regs_rsp(platform_regs_bus_rsp)
  );

  wavetable_common_status_regs #(
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
  ) common_status_regs (
    .clk,
    .rst,
    .core_reset,
    .bus_req(common_status_bus_req),
    .bus_rsp(common_status_bus_rsp),
    .core_sample_valid,
    .core_busy,
    .render_inflight(core_busy),
    .render_deadline_miss_pulse(1'b0),
    .render_latency_cycles(16'd0),
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
    .audio_diagnostics
  );

  assign render_deadline_miss_pulse = 1'b0;
  assign render_latency_cycles = 16'd0;

  wavetable_system_core #(.LINE_WORDS(LINE_WORDS)) core (
    .clk,
    .rst(core_reset),
    .bus_req(core_bus_req),
    .bus_rsp(core_bus_rsp),
    .cmd_stream_valid(spi_cmd_valid),
    .cmd_stream_data(spi_cmd_data),
    .cmd_stream_ready(spi_cmd_ready),
    .sample_tick(render_start),
    .sample_valid(core_sample_valid),
    .sample_ready(core_sample_ready),
    .sample_l(core_sample_l),
    .sample_r(core_sample_r),
    .busy(core_busy),
    .audio_diagnostics,
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .mem_response_trace_pulse,
    .mem_response_trace_latency
  );

  wavetable_i2s_output #(
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
    .START_LEVEL(START_LEVEL),
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) audio_output (
    .clk,
    .rst(core_reset),
    .sample_valid(core_sample_valid),
    .sample_ready(core_sample_ready),
    .sample_l(core_sample_l),
    .sample_r(core_sample_r),
    .i2s_sample_ready,
    .fifo_sample_valid,
    .underrun_pulse,
    .sample_drop_pulse,
    .output_fifo_level,
    .playback_started,
    .render_sample_counter,
    .played_sample_counter,
    .audio_lead,
    .minimum_fifo_level,
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata
  );

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_render_credit;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_render_credit = render_credit;
endmodule
