module smart_artix_sd_native_asset_loader #(
  parameter int LBA_WIDTH = 32
) (
  input  logic                      clk,
  input  logic                      rst,

  input  logic                      start,
  input  logic                      ddr_init_calib_complete,
  output logic                      busy,
  output logic                      asset_loaded,
  output logic                      sd_initialized,
  output logic [3:0]                status_state,
  output logic [7:0]                sd_error_code,
  output logic [7:0]                loader_error_code,
  output logic [31:0]               bytes_loaded,
  output logic [31:0]               sf2_size_bytes,
  output logic [LBA_WIDTH-1:0]      current_lba,

  output logic                      sd_cmd_valid,
  input  logic                      sd_cmd_ready,
  output logic [5:0]                sd_cmd_index,
  output logic [31:0]               sd_cmd_arg,
  output logic [1:0]                sd_cmd_resp_type,
  output logic                      sd_cmd_data_read,
  output logic [15:0]               sd_cmd_block_len,
  output logic [15:0]               sd_cmd_block_count,
  input  logic                      sd_rsp_valid,
  input  logic [2:0]                sd_rsp_status,
  input  logic [119:0]              sd_rsp_data,

  input  logic                      sd_data_valid,
  output logic                      sd_data_ready,
  input  logic [7:0]                sd_data,
  input  logic                      sd_data_last,
  input  logic [2:0]                sd_data_status,

  output smart_artix_pkg::mig_app_command_t    mig_app_command,
  output smart_artix_pkg::mig_app_write_data_t mig_app_write_data,
  input  smart_artix_pkg::mig_app_response_t   mig_app_response
);
  logic sd_busy;
  logic sd_req_valid;
  logic sd_req_ready;
  logic [LBA_WIDTH-1:0] sd_req_lba;
  logic sd_byte_valid;
  logic sd_byte_ready;
  logic [7:0] sd_byte_data;
  logic sd_byte_last;
  logic loader_busy;
  logic sd_start_pulse;
  logic loader_start_pulse;
  logic load_pending;
  logic start_d;
  logic start_pulse;

  assign start_pulse = start && !start_d;
  assign busy = sd_busy || loader_busy || load_pending || (start && !asset_loaded);
  assign sd_start_pulse = start_pulse && !sd_initialized;
  assign loader_start_pulse = (start_pulse && sd_initialized)
      || (load_pending && sd_initialized && !loader_busy && !asset_loaded);

  always_ff @(posedge clk) begin
    if (rst) begin
      start_d <= 1'b0;
      load_pending <= 1'b0;
    end else begin
      start_d <= start;
      if (start_pulse)
        load_pending <= 1'b1;
      if (loader_start_pulse)
        load_pending <= 1'b0;
    end
  end

  smart_artix_sd_native_block_reader #(
    .LBA_WIDTH(LBA_WIDTH)
  ) sd_reader (
    .clk,
    .rst,
    .init_start(sd_start_pulse),
    .initialized(sd_initialized),
    .busy(sd_busy),
    .error_code(sd_error_code),
    .block_req_valid(sd_req_valid),
    .block_req_ready(sd_req_ready),
    .block_req_lba(sd_req_lba),
    .block_byte_valid(sd_byte_valid),
    .block_byte_ready(sd_byte_ready),
    .block_byte_data(sd_byte_data),
    .block_byte_last(sd_byte_last),
    .phy_cmd_valid(sd_cmd_valid),
    .phy_cmd_ready(sd_cmd_ready),
    .phy_cmd_index(sd_cmd_index),
    .phy_cmd_arg(sd_cmd_arg),
    .phy_cmd_resp_type(sd_cmd_resp_type),
    .phy_cmd_data_read(sd_cmd_data_read),
    .phy_cmd_block_len(sd_cmd_block_len),
    .phy_cmd_block_count(sd_cmd_block_count),
    .phy_rsp_valid(sd_rsp_valid),
    .phy_rsp_status(sd_rsp_status),
    .phy_rsp_data(sd_rsp_data),
    .phy_data_valid(sd_data_valid),
    .phy_data_ready(sd_data_ready),
    .phy_data(sd_data),
    .phy_data_last(sd_data_last),
    .phy_data_status(sd_data_status)
  );

  smart_artix_sd_ddr3_asset_loader #(
    .LBA_WIDTH(LBA_WIDTH)
  ) loader (
    .clk,
    .rst,
    .start(loader_start_pulse),
    .ddr_init_calib_complete(ddr_init_calib_complete && sd_initialized),
    .busy(loader_busy),
    .asset_loaded,
    .status_state,
    .error_code(loader_error_code),
    .bytes_loaded,
    .sf2_size_bytes,
    .current_lba,
    .sd_req_valid,
    .sd_req_ready,
    .sd_req_lba,
    .sd_byte_valid,
    .sd_byte_ready,
    .sd_byte_data,
    .sd_byte_last,
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );
endmodule
