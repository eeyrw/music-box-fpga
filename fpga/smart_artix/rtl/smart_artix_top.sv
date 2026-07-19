module smart_artix_top (
  input  logic clk_in,
  input  logic rst_n,

  inout  wire  [15:0] ddr3_dq,
  inout  wire  [1:0]  ddr3_dqs_n,
  inout  wire  [1:0]  ddr3_dqs_p,
  output logic [14:0] ddr3_addr,
  output logic [2:0]  ddr3_ba,
  output logic        ddr3_ras_n,
  output logic        ddr3_cas_n,
  output logic        ddr3_we_n,
  output logic        ddr3_reset_n,
  output logic [0:0]  ddr3_ck_p,
  output logic [0:0]  ddr3_ck_n,
  output logic [0:0]  ddr3_cke,
  output logic [1:0]  ddr3_dm,
  output logic [0:0]  ddr3_odt,

  input  logic spi_sclk,
  input  logic spi_cs_n,
  input  logic spi_mosi,
  output logic spi_miso,

  output logic i2s_bclk,
  output logic i2s_lrclk,
  output logic i2s_sdata,

  output logic sd_clk,
  inout  wire  sd_cmd,
  input  logic [3:0] sd_dat,

  output logic led_spi_error,
  output logic led_underrun,
  output logic led_sample_drop,
  output logic led_deadline_miss,
  output logic led_asset_loaded,
  output logic led_loader_error
);
  localparam int LINE_WORDS = 8;
  localparam int OUTPUT_FIFO_DEPTH = 8;
  localparam int SD_DIV_WIDTH = 16;
  localparam int SYS_CLK_HZ = 100_000_000;
  localparam int SAMPLE_RATE_HZ = 48_000;
  localparam logic [SD_DIV_WIDTH-1:0] SD_INIT_CLK_DIV = SD_DIV_WIDTH'(124);
  localparam logic [SD_DIV_WIDTH-1:0] SD_TRANSFER_CLK_DIV = SD_DIV_WIDTH'(0);

  logic clk_sys;
  logic rst_sys;
  logic core_rst_sys;
  logic clk_mig_sys;

  smart_artix_clk_50m_to_200m board_clock_generator (
    .clk_out1(clk_mig_sys),
    .resetn(rst_n),
    .clk_in1(clk_in)
  );

  smart_artix_pkg::line_read_request_t core_line_req;
  logic                     core_line_req_ready;
  smart_artix_pkg::line_read_response_t core_line_rsp;
  logic                     underrun_pulse;
  logic                     sample_drop_pulse;
  logic                     render_deadline_miss_pulse;
  logic [15:0]              render_latency_cycles;
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level;
  logic                     mem_response_trace_pulse;
  logic [15:0]              mem_response_trace_latency;
  logic                     mig_init_calib_complete;
  smart_artix_pkg::mig_app_command_t mig_app_command;
  smart_artix_pkg::mig_app_write_data_t mig_app_write_data;
  smart_artix_pkg::mig_app_response_t mig_app_response;
  logic                     mig_app_sr_active;
  logic                     mig_app_ref_ack;
  logic                     mig_app_zq_ack;
  logic [11:0]              mig_device_temp;
  logic                     mig_ui_clk;
  logic                     mig_ui_clk_sync_rst;
  logic                     sd_cmd_o;
  logic                     sd_cmd_oe;
  logic                     sd_cmd_i;
  logic                     platform_regs_bus_valid;
  logic                     platform_regs_bus_write;
  logic [15:0]              platform_regs_bus_address;
  logic [31:0]              platform_regs_bus_wdata;
  logic [31:0]              platform_regs_bus_rdata;
  logic                     platform_regs_bus_ready;
  logic                     platform_regs_bus_error;
  smart_artix_pkg::platform_status_t platform_status;
  smart_artix_pkg::ddr_reg_access_request_t ddr_reg_access_request;
  smart_artix_pkg::ddr_reg_access_status_t ddr_reg_access_status;

  assign clk_sys = mig_ui_clk;
  assign rst_sys = mig_ui_clk_sync_rst || !mig_init_calib_complete;
  assign core_rst_sys = rst_sys || !platform_status.asset_loaded;
  assign sd_cmd = sd_cmd_oe ? sd_cmd_o : 1'bz;
  assign sd_cmd_i = sd_cmd;

  smart_artix_ddr3_mig ddr3_memory_controller (
    .ddr3_dq(ddr3_dq),
    .ddr3_dqs_n(ddr3_dqs_n),
    .ddr3_dqs_p(ddr3_dqs_p),
    .ddr3_addr(ddr3_addr),
    .ddr3_ba(ddr3_ba),
    .ddr3_ras_n(ddr3_ras_n),
    .ddr3_cas_n(ddr3_cas_n),
    .ddr3_we_n(ddr3_we_n),
    .ddr3_reset_n(ddr3_reset_n),
    .ddr3_ck_p(ddr3_ck_p),
    .ddr3_ck_n(ddr3_ck_n),
    .ddr3_cke(ddr3_cke),
    .ddr3_dm(ddr3_dm),
    .ddr3_odt(ddr3_odt),
    .sys_clk_i(clk_mig_sys),
    .app_addr(mig_app_command.addr),
    .app_cmd(mig_app_command.cmd),
    .app_en(mig_app_command.en),
    .app_wdf_data(mig_app_write_data.data),
    .app_wdf_end(mig_app_write_data.end_),
    .app_wdf_mask(mig_app_write_data.mask),
    .app_wdf_wren(mig_app_write_data.wren),
    .app_rd_data(mig_app_response.rd_data),
    .app_rd_data_end(mig_app_response.rd_data_end),
    .app_rd_data_valid(mig_app_response.rd_data_valid),
    .app_rdy(mig_app_response.rdy),
    .app_wdf_rdy(mig_app_response.wdf_rdy),
    .app_sr_req(1'b0),
    .app_ref_req(1'b0),
    .app_zq_req(1'b0),
    .app_sr_active(mig_app_sr_active),
    .app_ref_ack(mig_app_ref_ack),
    .app_zq_ack(mig_app_zq_ack),
    .ui_clk(mig_ui_clk),
    .ui_clk_sync_rst(mig_ui_clk_sync_rst),
    .init_calib_complete(mig_init_calib_complete),
    .device_temp(mig_device_temp),
    .sys_rst(rst_n)
  );

  smart_artix_ddr3_subsystem #(
    .LBA_WIDTH(32),
    .SD_DIV_WIDTH(SD_DIV_WIDTH)
  ) ddr3_subsystem (
    .clk(clk_sys),
    .rst(rst_sys),
    .loader_rst(mig_ui_clk_sync_rst),
    .core_rst(core_rst_sys),
    .start(mig_init_calib_complete),
    .sd_init_clk_div(SD_INIT_CLK_DIV),
    .sd_transfer_clk_div(SD_TRANSFER_CLK_DIV),
    .ddr_init_calib_complete(mig_init_calib_complete),
    .ddr_ui_rst(mig_ui_clk_sync_rst),
    .ddr_device_temp(mig_device_temp),
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i,
    .sd_dat_i(sd_dat),
    .line_req(core_line_req),
    .line_req_ready(core_line_req_ready),
    .line_rsp(core_line_rsp),
    .ddr_reg_access_request,
    .ddr_reg_access_status,
    .platform_status,
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );

  smart_artix_platform_regs platform_regs (
    .clk(clk_sys),
    .rst(rst_sys),
    .bus_valid(platform_regs_bus_valid),
    .bus_write(platform_regs_bus_write),
    .bus_address(platform_regs_bus_address),
    .bus_wdata(platform_regs_bus_wdata),
    .bus_rdata(platform_regs_bus_rdata),
    .bus_ready(platform_regs_bus_ready),
    .bus_error(platform_regs_bus_error),
    .platform_status,
    .ddr_reg_access_request,
    .ddr_reg_access_status
  );

  wavetable_demo_system #(
    .LINE_WORDS(LINE_WORDS),
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ),
    .PLATFORM_REGS_PRESENT(1'b1)
  ) core_system (
    .clk(clk_sys),
    .rst(rst_sys),
    .core_rst(core_rst_sys),
    .spi_sclk(spi_sclk),
    .spi_cs_n(spi_cs_n),
    .spi_mosi(spi_mosi),
    .spi_miso(spi_miso),
    .spi_error(led_spi_error),
    .ext_req_valid(core_line_req.valid),
    .ext_req_ready(core_line_req_ready),
    .ext_req_addr(core_line_req.addr),
    .ext_rsp_valid(core_line_rsp.valid),
    .ext_rsp_data(core_line_rsp.data),
    .i2s_bclk(i2s_bclk),
    .i2s_lrclk(i2s_lrclk),
    .i2s_sdata(i2s_sdata),
    .underrun_pulse(underrun_pulse),
    .sample_drop_pulse(sample_drop_pulse),
    .mem_response_trace_pulse(mem_response_trace_pulse),
    .mem_response_trace_latency(mem_response_trace_latency),
    .output_fifo_level(output_fifo_level),
    .render_deadline_miss_pulse(render_deadline_miss_pulse),
    .render_latency_cycles(render_latency_cycles),
    .platform_regs_bus_valid,
    .platform_regs_bus_write,
    .platform_regs_bus_address,
    .platform_regs_bus_wdata,
    .platform_regs_bus_rdata,
    .platform_regs_bus_ready,
    .platform_regs_bus_error
  );

  assign led_underrun = underrun_pulse;
  assign led_sample_drop = sample_drop_pulse;
  assign led_deadline_miss = render_deadline_miss_pulse;
  assign led_asset_loaded = platform_status.asset_loaded;
  assign led_loader_error = (platform_status.sd_error_code != 8'd0) ||
                            (platform_status.loader_error_code != 8'd0);

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_status;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_status = core_line_req.valid ^ (^core_line_req.addr) ^ (^output_fifo_level)
      ^ (^render_latency_cycles)
      ^ mem_response_trace_pulse ^ (^mem_response_trace_latency) ^ (^mig_app_command.addr)
      ^ (^mig_app_command.cmd) ^ mig_app_command.en ^ mig_app_response.wdf_rdy ^ mig_app_sr_active
      ^ mig_app_ref_ack ^ mig_app_zq_ack ^ (^mig_device_temp)
      ^ platform_status.asset_loader_busy ^ platform_status.sd_initialized
      ^ (^platform_status.asset_loader_state) ^ (^platform_status.bytes_loaded)
      ^ (^platform_status.sf2_size_bytes) ^ (^platform_status.current_lba);
endmodule
