module wavetable_spi_audio_system #(
  parameter int LINE_WORDS = 8,
  parameter int OUTPUT_FIFO_DEPTH = 8,
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
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
  output logic                     mem_debug_hit_pulse,
  output logic                     mem_debug_miss_pulse,
  output logic                     mem_debug_response_pulse,
  output logic [15:0]              mem_debug_response_latency,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic                     render_deadline_miss_pulse,
  output logic [15:0]              render_latency_cycles,
  input  logic                     platform_ddr_init_calib_complete,
  input  logic                     platform_ddr_ui_rst,
  input  logic [11:0]              platform_ddr_device_temp,
  input  logic                     platform_mig_app_rdy,
  input  logic                     platform_mig_app_wdf_rdy,
  input  logic                     platform_mig_app_rd_data_valid,
  input  logic                     platform_mig_app_rd_data_end,
  input  logic                     platform_sd_initialized,
  input  logic                     platform_asset_loaded,
  input  logic                     platform_asset_loader_busy,
  input  logic [3:0]               platform_asset_loader_state,
  input  logic [7:0]               platform_sd_error_code,
  input  logic [7:0]               platform_loader_error_code,
  input  logic [31:0]              platform_bytes_loaded,
  input  logic [31:0]              platform_sf2_size_bytes,
  input  logic [31:0]              platform_current_lba,
  output logic                     platform_ddr_debug_start,
  output logic                     platform_ddr_debug_write,
  output logic [31:0]              platform_ddr_debug_addr,
  output logic [LINE_WORDS*16-1:0] platform_ddr_debug_wdata,
  output logic [LINE_WORDS*2-1:0]  platform_ddr_debug_byte_enable,
  input  logic                     platform_ddr_debug_ready,
  input  logic                     platform_ddr_debug_busy,
  input  logic                     platform_ddr_debug_done,
  input  logic                     platform_ddr_debug_error,
  input  logic [LINE_WORDS*16-1:0] platform_ddr_debug_rdata
);
  logic sample_tick;
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
  logic core_reset;
  logic system_debug_access;
  logic [31:0] system_debug_rdata;

  assign core_reset = rst || core_rst;
  assign core_bus_valid = spi_bus_valid && !system_debug_access && !core_reset;
  assign core_bus_write = spi_bus_write;
  assign core_bus_address = spi_bus_address;
  assign core_bus_wdata = spi_bus_wdata;
  assign spi_bus_ready = system_debug_access ? 1'b1 : (core_reset ? spi_bus_valid : core_bus_ready);
  assign spi_bus_error = system_debug_access ? 1'b0 : (core_reset ? 1'b1 : core_bus_error);
  assign spi_bus_rdata = system_debug_access ? system_debug_rdata : (core_reset ? 32'd0 : core_bus_rdata);

  fractional_tick_gen #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .TICK_HZ(SAMPLE_RATE_HZ)
  ) sample_tick_gen (
    .clk,
    .rst(core_reset),
    .tick(sample_tick)
  );

  wavetable_system_debug_regs #(
    .LINE_WORDS(LINE_WORDS),
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
  ) debug_regs (
    .clk,
    .rst,
    .core_reset,
    .bus_valid(spi_bus_valid),
    .bus_write(spi_bus_write),
    .bus_address(spi_bus_address),
    .bus_wdata(spi_bus_wdata),
    .debug_access(system_debug_access),
    .debug_rdata(system_debug_rdata),
    .sample_tick,
    .core_sample_valid,
    .core_busy,
    .ext_req_valid,
    .ext_req_ready,
    .ext_rsp_valid,
    .i2s_sample_ready,
    .fifo_sample_valid,
    .underrun_pulse,
    .sample_drop_pulse,
    .mem_debug_hit_pulse,
    .mem_debug_miss_pulse,
    .mem_debug_response_pulse,
    .mem_debug_response_latency,
    .output_fifo_level,
    .render_deadline_miss_pulse,
    .render_latency_cycles,
    .platform_ddr_init_calib_complete,
    .platform_ddr_ui_rst,
    .platform_ddr_device_temp,
    .platform_mig_app_rdy,
    .platform_mig_app_wdf_rdy,
    .platform_mig_app_rd_data_valid,
    .platform_mig_app_rd_data_end,
    .platform_sd_initialized,
    .platform_asset_loaded,
    .platform_asset_loader_busy,
    .platform_asset_loader_state,
    .platform_sd_error_code,
    .platform_loader_error_code,
    .platform_bytes_loaded,
    .platform_sf2_size_bytes,
    .platform_current_lba,
    .platform_ddr_debug_start,
    .platform_ddr_debug_write,
    .platform_ddr_debug_addr,
    .platform_ddr_debug_wdata,
    .platform_ddr_debug_byte_enable,
    .platform_ddr_debug_ready,
    .platform_ddr_debug_busy,
    .platform_ddr_debug_done,
    .platform_ddr_debug_error,
    .platform_ddr_debug_rdata
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
    .bus_error(spi_bus_error)
  );

  wavetable_line_memory_core #(.LINE_WORDS(LINE_WORDS)) core (
    .clk,
    .rst(core_reset),
    .bus_valid(core_bus_valid),
    .bus_write(core_bus_write),
    .bus_address(core_bus_address),
    .bus_wdata(core_bus_wdata),
    .bus_rdata(core_bus_rdata),
    .bus_ready(core_bus_ready),
    .bus_error(core_bus_error),
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
    .rst(core_reset),
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
    .rst(core_reset),
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
