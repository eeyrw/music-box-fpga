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
  localparam int MIG_ADDR_WIDTH = 29;
  localparam int MIG_DATA_WIDTH = LINE_WORDS * 16;
  localparam int SD_DIV_WIDTH = 16;
  localparam int SYS_CLK_HZ = 100_000_000;
  localparam int SAMPLE_RATE_HZ = 48_000;
  localparam logic [SD_DIV_WIDTH-1:0] SD_INIT_CLK_DIV = SD_DIV_WIDTH'(124);
  localparam logic [SD_DIV_WIDTH-1:0] SD_TRANSFER_CLK_DIV = SD_DIV_WIDTH'(1);

  logic clk_sys;
  logic rst_sys;
  logic clk_mig_sys;

  smart_artix_clk_50m_to_200m board_clock_generator (
    .clk_out1(clk_mig_sys),
    .resetn(rst_n),
    .clk_in1(clk_in)
  );

  logic                     ext_req_valid;
  logic                     ext_req_ready;
  logic [31:0]              ext_req_addr;
  logic                     ext_rsp_valid;
  logic [LINE_WORDS*16-1:0] ext_rsp_data;
  logic                     underrun_pulse;
  logic                     sample_drop_pulse;
  logic                     render_deadline_miss_pulse;
  logic [15:0]              render_latency_cycles;
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level;
  logic                     mem_debug_hit_pulse;
  logic                     mem_debug_miss_pulse;
  logic                     mem_debug_response_pulse;
  logic [15:0]              mem_debug_response_latency;
  logic                     mig_init_calib_complete;
  logic [MIG_ADDR_WIDTH-1:0] mig_app_addr;
  logic [2:0]               mig_app_cmd;
  logic                     mig_app_en;
  logic                     mig_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] mig_app_wdf_data;
  logic [MIG_DATA_WIDTH/8-1:0] mig_app_wdf_mask;
  logic                     mig_app_wdf_wren;
  logic                     mig_app_wdf_end;
  logic [MIG_DATA_WIDTH-1:0] mig_app_rd_data;
  logic                     mig_app_rd_data_valid;
  logic                     mig_app_rd_data_end;
  logic                     mig_app_wdf_rdy;
  logic                     mig_app_sr_active;
  logic                     mig_app_ref_ack;
  logic                     mig_app_zq_ack;
  logic [11:0]              mig_device_temp;
  logic                     mig_ui_clk;
  logic                     mig_ui_clk_sync_rst;
  logic [MIG_ADDR_WIDTH-1:0] read_app_addr;
  logic [2:0]               read_app_cmd;
  logic                     read_app_en;
  logic                     read_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] read_app_rd_data;
  logic                     read_app_rd_data_valid;
  logic                     read_app_rd_data_end;
  logic [MIG_ADDR_WIDTH-1:0] write_app_addr;
  logic [2:0]               write_app_cmd;
  logic                     write_app_en;
  logic                     write_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] write_app_wdf_data;
  logic [MIG_DATA_WIDTH/8-1:0] write_app_wdf_mask;
  logic                     write_app_wdf_wren;
  logic                     write_app_wdf_end;
  logic                     write_app_wdf_rdy;
  logic                     sd_cmd_o;
  logic                     sd_cmd_oe;
  logic                     sd_cmd_i;
  logic                     loader_busy;
  logic                     asset_loaded;
  logic                     sd_initialized;
  logic [3:0]               loader_status_state;
  logic [7:0]               sd_error_code;
  logic [7:0]               loader_error_code;
  logic [63:0]              bytes_loaded;
  logic [63:0]              sf2_size_bytes;
  logic [31:0]              current_lba;

  assign clk_sys = mig_ui_clk;
  assign rst_sys = mig_ui_clk_sync_rst || !mig_init_calib_complete || !asset_loaded;
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
    .app_addr(mig_app_addr),
    .app_cmd(mig_app_cmd),
    .app_en(mig_app_en),
    .app_wdf_data(mig_app_wdf_data),
    .app_wdf_end(mig_app_wdf_end),
    .app_wdf_mask(mig_app_wdf_mask),
    .app_wdf_wren(mig_app_wdf_wren),
    .app_rd_data(mig_app_rd_data),
    .app_rd_data_end(mig_app_rd_data_end),
    .app_rd_data_valid(mig_app_rd_data_valid),
    .app_rdy(mig_app_rdy),
    .app_wdf_rdy(mig_app_wdf_rdy),
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

  smart_artix_sd_native_pin_asset_loader #(
    .LBA_WIDTH(32),
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH),
    .SD_DIV_WIDTH(SD_DIV_WIDTH)
  ) asset_loader (
    .clk(clk_sys),
    .rst(mig_ui_clk_sync_rst),
    .start(mig_init_calib_complete),
    .sd_init_clk_div(SD_INIT_CLK_DIV),
    .sd_transfer_clk_div(SD_TRANSFER_CLK_DIV),
    .ddr_init_calib_complete(mig_init_calib_complete),
    .busy(loader_busy),
    .asset_loaded(asset_loaded),
    .sd_initialized(sd_initialized),
    .status_state(loader_status_state),
    .sd_error_code(sd_error_code),
    .loader_error_code(loader_error_code),
    .bytes_loaded(bytes_loaded),
    .sf2_size_bytes(sf2_size_bytes),
    .current_lba(current_lba),
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i,
    .sd_dat_i(sd_dat),
    .mig_app_addr(write_app_addr),
    .mig_app_cmd(write_app_cmd),
    .mig_app_en(write_app_en),
    .mig_app_rdy(write_app_rdy),
    .mig_app_wdf_data(write_app_wdf_data),
    .mig_app_wdf_mask(write_app_wdf_mask),
    .mig_app_wdf_wren(write_app_wdf_wren),
    .mig_app_wdf_end(write_app_wdf_end),
    .mig_app_wdf_rdy(write_app_wdf_rdy)
  );

  smart_artix_ddr3_rw_arbiter #(
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH)
  ) ddr3_rw_arbiter (
    .clk(clk_sys),
    .rst(rst_sys),
    .read_app_addr,
    .read_app_cmd,
    .read_app_en,
    .read_app_rdy,
    .read_app_rd_data,
    .read_app_rd_data_valid,
    .read_app_rd_data_end,
    .write_app_addr,
    .write_app_cmd,
    .write_app_en,
    .write_app_rdy,
    .write_app_wdf_data,
    .write_app_wdf_mask,
    .write_app_wdf_wren,
    .write_app_wdf_end,
    .write_app_wdf_rdy,
    .mig_app_addr,
    .mig_app_cmd,
    .mig_app_en,
    .mig_app_rdy,
    .mig_app_rd_data,
    .mig_app_rd_data_valid,
    .mig_app_rd_data_end,
    .mig_app_wdf_data,
    .mig_app_wdf_mask,
    .mig_app_wdf_wren,
    .mig_app_wdf_end,
    .mig_app_wdf_rdy
  );

  smart_artix_ddr3_line_reader #(
    .LINE_WORDS(LINE_WORDS),
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH),
    .WORD_ADDR_SHIFT(1)
  ) ddr3_line_reader (
    .clk(clk_sys),
    .rst(rst_sys),
    .line_req_valid(ext_req_valid),
    .line_req_ready(ext_req_ready),
    .line_req_addr(ext_req_addr),
    .line_rsp_valid(ext_rsp_valid),
    .line_rsp_data(ext_rsp_data),
    .mig_init_calib_complete(mig_init_calib_complete),
    .mig_app_addr(read_app_addr),
    .mig_app_cmd(read_app_cmd),
    .mig_app_en(read_app_en),
    .mig_app_rdy(read_app_rdy),
    .mig_app_rd_data(read_app_rd_data),
    .mig_app_rd_data_valid(read_app_rd_data_valid),
    .mig_app_rd_data_end(read_app_rd_data_end)
  );

  wavetable_core_system #(
    .LINE_WORDS(LINE_WORDS),
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) core_system (
    .clk(clk_sys),
    .rst(rst_sys),
    .spi_sclk(spi_sclk),
    .spi_cs_n(spi_cs_n),
    .spi_mosi(spi_mosi),
    .spi_miso(spi_miso),
    .spi_error(led_spi_error),
    .ext_req_valid(ext_req_valid),
    .ext_req_ready(ext_req_ready),
    .ext_req_addr(ext_req_addr),
    .ext_rsp_valid(ext_rsp_valid),
    .ext_rsp_data(ext_rsp_data),
    .i2s_bclk(i2s_bclk),
    .i2s_lrclk(i2s_lrclk),
    .i2s_sdata(i2s_sdata),
    .underrun_pulse(underrun_pulse),
    .sample_drop_pulse(sample_drop_pulse),
    .mem_debug_hit_pulse(mem_debug_hit_pulse),
    .mem_debug_miss_pulse(mem_debug_miss_pulse),
    .mem_debug_response_pulse(mem_debug_response_pulse),
    .mem_debug_response_latency(mem_debug_response_latency),
    .output_fifo_level(output_fifo_level),
    .render_deadline_miss_pulse(render_deadline_miss_pulse),
    .render_latency_cycles(render_latency_cycles)
  );

  assign led_underrun = underrun_pulse;
  assign led_sample_drop = sample_drop_pulse;
  assign led_deadline_miss = render_deadline_miss_pulse;
  assign led_asset_loaded = asset_loaded;
  assign led_loader_error = (sd_error_code != 8'd0) || (loader_error_code != 8'd0);

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_debug;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_debug = ext_req_valid ^ (^ext_req_addr) ^ (^output_fifo_level)
      ^ (^render_latency_cycles) ^ mem_debug_hit_pulse ^ mem_debug_miss_pulse
      ^ mem_debug_response_pulse ^ (^mem_debug_response_latency) ^ (^mig_app_addr)
      ^ (^mig_app_cmd) ^ mig_app_en ^ mig_app_wdf_rdy ^ mig_app_sr_active
      ^ mig_app_ref_ack ^ mig_app_zq_ack ^ (^mig_device_temp) ^ loader_busy
      ^ sd_initialized ^ (^loader_status_state) ^ (^bytes_loaded)
      ^ (^sf2_size_bytes) ^ (^current_lba);
endmodule
