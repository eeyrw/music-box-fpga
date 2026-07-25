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
  logic spi_bus_valid;
  logic spi_bus_write;
  logic [15:0] spi_bus_address;
  logic [31:0] spi_bus_wdata;
  logic [31:0] spi_bus_rdata;
  logic spi_bus_ready;
  logic spi_bus_error;
  logic core_bus_valid;
  logic core_bus_write;
  logic [15:0] core_bus_address;
  logic [31:0] core_bus_wdata;
  logic [31:0] core_bus_rdata;
  logic core_bus_ready;
  logic core_bus_error;
  logic common_status_bus_valid;
  logic common_status_bus_write;
  logic [15:0] common_status_bus_address;
  logic [31:0] common_status_bus_wdata;
  logic [31:0] common_status_bus_rdata;
  logic common_status_bus_ready;
  logic common_status_bus_error;
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
  logic compressor_enabled;
  logic compressor_primed;
  logic [15:0] compressor_delay_level;
  logic [31:0] compressor_gain_reduction;
  logic [31:0] compressor_target_gain_reduction;
  logic [synth_pkg::MIX_WIDTH-1:0] compressor_detector_peak;
  logic [31:0] compressor_max_gain_reduction;
  logic [synth_pkg::MIX_WIDTH-1:0] compressor_max_detector_peak;
  logic [31:0] compressor_input_frame_count;
  logic [31:0] compressor_output_frame_count;
  logic [31:0] compressor_compressed_frame_count;
  logic [31:0] compressor_saturation_count;

  assign core_reset = rst || core_rst;

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
    .bus_valid(spi_bus_valid),
    .bus_write(spi_bus_write),
    .bus_address(spi_bus_address),
    .bus_wdata(spi_bus_wdata),
    .bus_rdata(spi_bus_rdata),
    .bus_ready(spi_bus_ready),
    .bus_error(spi_bus_error),
    .cmd_valid(spi_cmd_valid),
    .cmd_data(spi_cmd_data),
    .cmd_ready(spi_cmd_ready)
  );

  wavetable_register_fabric #(
    .PLATFORM_REGS_PRESENT(PLATFORM_REGS_PRESENT)
  ) register_fabric (
    .master_valid(spi_bus_valid),
    .master_write(spi_bus_write),
    .master_address(spi_bus_address),
    .master_wdata(spi_bus_wdata),
    .core_reset,
    .master_rdata(spi_bus_rdata),
    .master_ready(spi_bus_ready),
    .master_error(spi_bus_error),
    .core_valid(core_bus_valid),
    .core_write(core_bus_write),
    .core_address(core_bus_address),
    .core_wdata(core_bus_wdata),
    .core_rdata(core_bus_rdata),
    .core_ready(core_bus_ready),
    .core_error(core_bus_error),
    .common_status_valid(common_status_bus_valid),
    .common_status_write(common_status_bus_write),
    .common_status_address(common_status_bus_address),
    .common_status_wdata(common_status_bus_wdata),
    .common_status_rdata(common_status_bus_rdata),
    .common_status_ready(common_status_bus_ready),
    .common_status_error(common_status_bus_error),
    .platform_regs_valid(platform_regs_bus_valid),
    .platform_regs_write(platform_regs_bus_write),
    .platform_regs_address(platform_regs_bus_address),
    .platform_regs_wdata(platform_regs_bus_wdata),
    .platform_regs_rdata(platform_regs_bus_rdata),
    .platform_regs_ready(platform_regs_bus_ready),
    .platform_regs_error(platform_regs_bus_error)
  );

  wavetable_common_status_regs #(
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
  ) common_status_regs (
    .clk,
    .rst,
    .core_reset,
    .bus_valid(common_status_bus_valid),
    .bus_write(common_status_bus_write),
    .bus_address(common_status_bus_address),
    .bus_wdata(common_status_bus_wdata),
    .bus_rdata(common_status_bus_rdata),
    .bus_ready(common_status_bus_ready),
    .bus_error(common_status_bus_error),
    .sample_tick(1'b0),
    .core_sample_valid,
    .core_busy,
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
    .compressor_enabled,
    .compressor_primed,
    .compressor_delay_level,
    .compressor_gain_reduction,
    .compressor_target_gain_reduction,
    .compressor_detector_peak,
    .compressor_max_gain_reduction,
    .compressor_max_detector_peak,
    .compressor_input_frame_count,
    .compressor_output_frame_count,
    .compressor_compressed_frame_count,
    .compressor_saturation_count,
    .render_deadline_miss_pulse,
    .render_latency_cycles
  );

  wavetable_system_core #(.LINE_WORDS(LINE_WORDS)) core (
    .clk,
    .rst(core_reset),
    .bus_valid(core_bus_valid),
    .bus_write(core_bus_write),
    .bus_address(core_bus_address),
    .bus_wdata(core_bus_wdata),
    .bus_rdata(core_bus_rdata),
    .bus_ready(core_bus_ready),
    .bus_error(core_bus_error),
    .cmd_stream_valid(spi_cmd_valid),
    .cmd_stream_data(spi_cmd_data),
    .cmd_stream_ready(spi_cmd_ready),
    .sample_tick(render_start),
    .sample_valid(core_sample_valid),
    .sample_ready(core_sample_ready),
    .sample_l(core_sample_l),
    .sample_r(core_sample_r),
    .busy(core_busy),
    .compressor_enabled,
    .compressor_primed,
    .compressor_delay_level,
    .compressor_gain_reduction,
    .compressor_target_gain_reduction,
    .compressor_detector_peak,
    .compressor_max_gain_reduction,
    .compressor_max_detector_peak,
    .compressor_input_frame_count,
    .compressor_output_frame_count,
    .compressor_compressed_frame_count,
    .compressor_saturation_count,
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
