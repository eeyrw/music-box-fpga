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
  input  logic [SD_DIV_WIDTH-1:0]           sd_default_clk_div,
  input  logic [SD_DIV_WIDTH-1:0]           sd_transfer_clk_div,
  input  logic                              ddr_init_calib_complete,
  input  logic                              ddr_ui_rst,
  input  logic [11:0]                       ddr_device_temp,

  output logic                              sd_clk,
  output logic                              sd_cmd_o,
  output logic                              sd_cmd_oe,
  input  logic                              sd_cmd_i,
  input  logic [3:0]                        sd_dat_i,
  input  logic                              sd_card_detect_n,

  input  smart_artix_pkg::line_read_request_t line_req,
  output logic                              line_req_ready,
  output smart_artix_pkg::line_read_response_t line_rsp,
  input  logic                              line_rsp_ready,

  input  smart_artix_pkg::ddr_reg_access_request_t ddr_reg_access_request,
  output smart_artix_pkg::ddr_reg_access_status_t  ddr_reg_access_status,
  output smart_artix_pkg::platform_status_t   platform_status,

  output smart_artix_pkg::mig_app_command_t    mig_app_command,
  output smart_artix_pkg::mig_app_write_data_t mig_app_write_data,
  input  smart_artix_pkg::mig_app_response_t   mig_app_response
);
  smart_artix_pkg::mig_app_command_t    read_command;
  smart_artix_pkg::mig_app_response_t   read_response;
  smart_artix_pkg::mig_app_command_t    reg_access_command;
  smart_artix_pkg::mig_app_write_data_t reg_access_write_data;
  smart_artix_pkg::mig_app_response_t   reg_access_response;
  smart_artix_pkg::mig_app_command_t    write_command;
  smart_artix_pkg::mig_app_write_data_t write_data;
  smart_artix_pkg::mig_app_response_t   write_response;
  logic                      loader_busy;
  logic                      asset_loaded;
  logic                      sd_initialized;
  logic [3:0]                loader_status_state;
  logic [7:0]                sd_error_code;
  logic [7:0]                sd_retry_count;
  logic [3:0]                sd_recovery_error_code;
  logic [7:0]                loader_error_code;
  logic [31:0]               bytes_loaded;
  logic [31:0]               sf2_size_bytes;
  logic [LBA_WIDTH-1:0]      current_lba;
  logic                      sd_transfer_clock_ready;
  logic                      sd_cmd_valid;
  logic                      sd_cmd_ready;
  logic [5:0]                sd_cmd_index;
  logic [31:0]               sd_cmd_arg;
  sd_native_pkg::sd_response_type_t sd_cmd_resp_type;
  logic                      sd_cmd_data_read;
  logic [15:0]               sd_cmd_block_len;
  logic [15:0]               sd_cmd_block_count;
  logic                      sd_rsp_data_proceed;
  logic                      sd_rsp_data_cancel;
  logic                      sd_abort_request;
  logic                      sd_rsp_valid;
  sd_native_pkg::sd_transport_status_t sd_rsp_status;
  logic [119:0]              sd_rsp_data;
  logic                      sd_transaction_done;
  logic                      sd_data_valid;
  logic                      sd_data_ready;
  logic [7:0]                sd_data;
  logic                      sd_data_last;
  sd_native_pkg::sd_transport_status_t sd_data_status;
  logic [SD_DIV_WIDTH-1:0]   selected_sd_clk_div;
  logic                      reg_access_ready;
  logic                      reg_access_busy;
  logic                      reg_access_done;
  logic                      reg_access_error;
  logic [smart_artix_pkg::MIG_DATA_WIDTH-1:0] reg_access_rdata;
  logic                      sd_card_present;
  logic                      sd_card_power_stable;
  logic                      sd_card_inserted;
  logic                      sd_card_removed;
  logic                      sd_session_rst;

  assign sd_session_rst = loader_rst || !sd_card_power_stable;

  smart_artix_sd_card_detect card_detect (
    .clk,
    .rst(loader_rst),
    .card_detect_n(sd_card_detect_n),
    .card_present(sd_card_present),
    .card_power_stable(sd_card_power_stable),
    .insertion_pulse(sd_card_inserted),
    .removal_pulse(sd_card_removed)
  );

  assign ddr_reg_access_status.ready = reg_access_ready;
  assign ddr_reg_access_status.busy = reg_access_busy;
  assign ddr_reg_access_status.done = reg_access_done;
  assign ddr_reg_access_status.error = reg_access_error;
  assign ddr_reg_access_status.rdata = reg_access_rdata;

  assign platform_status.ddr_init_calib_complete = ddr_init_calib_complete;
  assign platform_status.ddr_ui_rst = ddr_ui_rst;
  assign platform_status.ddr_device_temp = ddr_device_temp;
  assign platform_status.mig_app_rdy = mig_app_response.rdy;
  assign platform_status.mig_app_wdf_rdy = mig_app_response.wdf_rdy;
  assign platform_status.mig_app_rd_data_valid = mig_app_response.rd_data_valid;
  assign platform_status.mig_app_rd_data_end = mig_app_response.rd_data_end;
  assign platform_status.sd_initialized = sd_initialized;
  assign platform_status.sd_card_present = sd_card_present;
  assign platform_status.sd_high_speed_active = sd_transfer_clock_ready;
  assign platform_status.asset_loaded = asset_loaded;
  assign platform_status.asset_loader_busy = loader_busy;
  assign platform_status.asset_loader_state = loader_status_state;
  assign platform_status.sd_error_code = sd_error_code;
  assign platform_status.sd_retry_count = sd_retry_count;
  assign platform_status.sd_recovery_error_code = sd_recovery_error_code;
  assign platform_status.loader_error_code = loader_error_code;
  assign platform_status.bytes_loaded = bytes_loaded;
  assign platform_status.sf2_size_bytes = sf2_size_bytes;
  assign platform_status.current_lba = current_lba[31:0];
  assign selected_sd_clk_div = !sd_initialized ? sd_init_clk_div
      : sd_transfer_clock_ready ? sd_transfer_clk_div : sd_default_clk_div;

  smart_artix_sd_native_asset_loader #(
    .LBA_WIDTH(LBA_WIDTH)
  ) asset_loader (
    .clk,
    .rst(sd_session_rst),
    .start,
    .ddr_init_calib_complete,
    .busy(loader_busy),
    .asset_loaded,
    .sd_initialized,
    .sd_transfer_clock_ready,
    .sd_retry_count,
    .sd_recovery_error_code,
    .status_state(loader_status_state),
    .sd_error_code,
    .loader_error_code,
    .bytes_loaded,
    .sf2_size_bytes,
    .current_lba,
    .sd_cmd_valid,
    .sd_cmd_ready,
    .sd_cmd_index,
    .sd_cmd_arg,
    .sd_cmd_resp_type,
    .sd_cmd_data_read,
    .sd_cmd_block_len,
    .sd_cmd_block_count,
    .sd_rsp_data_proceed,
    .sd_rsp_data_cancel,
    .sd_abort_request,
    .sd_rsp_valid,
    .sd_rsp_status,
    .sd_rsp_data,
    .sd_transaction_done,
    .sd_data_valid,
    .sd_data_ready,
    .sd_data,
    .sd_data_last,
    .sd_data_status,
    .mig_app_command(write_command),
    .mig_app_write_data(write_data),
    .mig_app_response(write_response)
  );

  sd_native_pin_phy #(
    .DIV_WIDTH(SD_DIV_WIDTH)
  ) sd_phy (
    .clk,
    .rst(sd_session_rst),
    .clk_div(selected_sd_clk_div),
    .cmd_valid(sd_cmd_valid),
    .cmd_ready(sd_cmd_ready),
    .cmd_index(sd_cmd_index),
    .cmd_arg(sd_cmd_arg),
    .cmd_resp_type(sd_cmd_resp_type),
    .cmd_data_read(sd_cmd_data_read),
    .cmd_block_len(sd_cmd_block_len),
    .cmd_block_count(sd_cmd_block_count),
    .rsp_data_proceed(sd_rsp_data_proceed),
    .rsp_data_cancel(sd_rsp_data_cancel),
    .abort_request(sd_abort_request),
    .rsp_valid(sd_rsp_valid),
    .rsp_status(sd_rsp_status),
    .rsp_data(sd_rsp_data),
    .transaction_done(sd_transaction_done),
    .data_valid(sd_data_valid),
    .data_ready(sd_data_ready),
    .data(sd_data),
    .data_last(sd_data_last),
    .data_status(sd_data_status),
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i,
    .sd_dat_i
  );

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_sd_detect_events;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_sd_detect_events = sd_card_present ^ sd_card_inserted ^ sd_card_removed
      ^ (^sd_retry_count) ^ (^sd_recovery_error_code);

  smart_artix_ddr3_rw_arbiter arbiter (
    .clk,
    .rst,
    .read_command,
    .read_response,
    .reg_access_command,
    .reg_access_write_data,
    .reg_access_response,
    .write_command,
    .write_data,
    .write_response,
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );

  smart_artix_ddr3_reg_access_master reg_access_master (
    .clk,
    .rst,
    .start(ddr_reg_access_request.start),
    .write(ddr_reg_access_request.write),
    .byte_addr(ddr_reg_access_request.addr),
    .wdata(ddr_reg_access_request.wdata),
    .byte_enable(ddr_reg_access_request.byte_enable),
    .ready(reg_access_ready),
    .busy(reg_access_busy),
    .done_pulse(reg_access_done),
    .error_pulse(reg_access_error),
    .rdata(reg_access_rdata),
    .mig_app_command(reg_access_command),
    .mig_app_write_data(reg_access_write_data),
    .mig_app_response(reg_access_response)
  );

  smart_artix_ddr3_line_reader #(
    .QUEUE_DEPTH(8)
  ) line_reader (
    .clk,
    .rst(core_rst),
    .line_req,
    .line_req_ready,
    .line_rsp,
    .line_rsp_ready,
    .mig_init_calib_complete(ddr_init_calib_complete),
    .mig_app_command(read_command),
    .mig_app_response(read_response)
  );
endmodule
