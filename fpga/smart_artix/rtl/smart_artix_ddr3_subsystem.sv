module smart_artix_ddr3_subsystem #(
  parameter int LBA_WIDTH = 32,
  parameter int SD_DIV_WIDTH = 16
) (
  input  logic                              clk,
  input  logic                              rst,
  input  logic                              loader_rst,
  input  logic                              core_rst,
  input  logic                              start,
  input  logic [SD_DIV_WIDTH-1:0]           sd_init_clk_div,
  input  logic [SD_DIV_WIDTH-1:0]           sd_transfer_clk_div,
  input  logic                              ddr_init_calib_complete,
  input  logic                              ddr_ui_rst,
  input  logic [11:0]                       ddr_device_temp,

  output logic                              sd_clk,
  output logic                              sd_cmd_o,
  output logic                              sd_cmd_oe,
  input  logic                              sd_cmd_i,
  input  logic [3:0]                        sd_dat_i,

  input  smart_artix_pkg::line_read_request_t line_req,
  output logic                              line_req_ready,
  output smart_artix_pkg::line_read_response_t line_rsp,

  input  smart_artix_pkg::ddr_debug_request_t ddr_debug_request,
  output smart_artix_pkg::ddr_debug_status_t  ddr_debug_status,
  output smart_artix_pkg::platform_status_t   platform_status,

  output smart_artix_pkg::mig_app_command_t    mig_app_command,
  output smart_artix_pkg::mig_app_write_data_t mig_app_write_data,
  input  smart_artix_pkg::mig_app_response_t   mig_app_response
);
  smart_artix_pkg::mig_app_command_t    read_command;
  smart_artix_pkg::mig_app_response_t   read_response;
  smart_artix_pkg::mig_app_command_t    debug_command;
  smart_artix_pkg::mig_app_write_data_t debug_write_data;
  smart_artix_pkg::mig_app_response_t   debug_response;
  smart_artix_pkg::mig_app_command_t    write_command;
  smart_artix_pkg::mig_app_write_data_t write_data;
  smart_artix_pkg::mig_app_response_t   write_response;
  logic                      loader_busy;
  logic                      asset_loaded;
  logic                      sd_initialized;
  logic [3:0]                loader_status_state;
  logic [7:0]                sd_error_code;
  logic [7:0]                loader_error_code;
  logic [31:0]               bytes_loaded;
  logic [31:0]               sf2_size_bytes;
  logic [LBA_WIDTH-1:0]      current_lba;
  logic                      debug_ready;
  logic                      debug_busy;
  logic                      debug_done;
  logic                      debug_error;
  logic [smart_artix_pkg::MIG_DATA_WIDTH-1:0] debug_rdata;

  assign ddr_debug_status.ready = debug_ready;
  assign ddr_debug_status.busy = debug_busy;
  assign ddr_debug_status.done = debug_done;
  assign ddr_debug_status.error = debug_error;
  assign ddr_debug_status.rdata = debug_rdata;

  assign platform_status.ddr_init_calib_complete = ddr_init_calib_complete;
  assign platform_status.ddr_ui_rst = ddr_ui_rst;
  assign platform_status.ddr_device_temp = ddr_device_temp;
  assign platform_status.mig_app_rdy = mig_app_response.rdy;
  assign platform_status.mig_app_wdf_rdy = mig_app_response.wdf_rdy;
  assign platform_status.mig_app_rd_data_valid = mig_app_response.rd_data_valid;
  assign platform_status.mig_app_rd_data_end = mig_app_response.rd_data_end;
  assign platform_status.sd_initialized = sd_initialized;
  assign platform_status.asset_loaded = asset_loaded;
  assign platform_status.asset_loader_busy = loader_busy;
  assign platform_status.asset_loader_state = loader_status_state;
  assign platform_status.sd_error_code = sd_error_code;
  assign platform_status.loader_error_code = loader_error_code;
  assign platform_status.bytes_loaded = bytes_loaded;
  assign platform_status.sf2_size_bytes = sf2_size_bytes;
  assign platform_status.current_lba = current_lba[31:0];

  smart_artix_sd_native_pin_asset_loader #(
    .LBA_WIDTH(LBA_WIDTH),
    .SD_DIV_WIDTH(SD_DIV_WIDTH)
  ) asset_loader (
    .clk,
    .rst(loader_rst),
    .start,
    .sd_init_clk_div,
    .sd_transfer_clk_div,
    .ddr_init_calib_complete,
    .busy(loader_busy),
    .asset_loaded,
    .sd_initialized,
    .status_state(loader_status_state),
    .sd_error_code,
    .loader_error_code,
    .bytes_loaded,
    .sf2_size_bytes,
    .current_lba,
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i,
    .sd_dat_i,
    .mig_app_command(write_command),
    .mig_app_write_data(write_data),
    .mig_app_response(write_response)
  );

  smart_artix_ddr3_rw_arbiter arbiter (
    .clk,
    .rst,
    .read_command,
    .read_response,
    .debug_command,
    .debug_write_data,
    .debug_response,
    .write_command,
    .write_data,
    .write_response,
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );

  smart_artix_ddr3_debug_master debug_master (
    .clk,
    .rst,
    .start(ddr_debug_request.start),
    .write(ddr_debug_request.write),
    .byte_addr(ddr_debug_request.addr),
    .wdata(ddr_debug_request.wdata),
    .byte_enable(ddr_debug_request.byte_enable),
    .ready(debug_ready),
    .busy(debug_busy),
    .done_pulse(debug_done),
    .error_pulse(debug_error),
    .rdata(debug_rdata),
    .mig_app_command(debug_command),
    .mig_app_write_data(debug_write_data),
    .mig_app_response(debug_response)
  );

  smart_artix_ddr3_line_reader #(
    .WORD_ADDR_SHIFT(1)
  ) line_reader (
    .clk,
    .rst(core_rst),
    .line_req,
    .line_req_ready,
    .line_rsp,
    .mig_init_calib_complete(ddr_init_calib_complete),
    .mig_app_command(read_command),
    .mig_app_response(read_response)
  );
endmodule
