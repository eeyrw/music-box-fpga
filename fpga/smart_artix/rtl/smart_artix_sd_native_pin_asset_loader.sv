module smart_artix_sd_native_pin_asset_loader #(
  parameter int LBA_WIDTH = 32,
  parameter int MIG_ADDR_WIDTH = 28,
  parameter int MIG_DATA_WIDTH = 128,
  parameter int SD_DIV_WIDTH = 16
) (
  input  logic                      clk,
  input  logic                      rst,

  input  logic                      start,
  input  logic [SD_DIV_WIDTH-1:0]   sd_init_clk_div,
  input  logic [SD_DIV_WIDTH-1:0]   sd_transfer_clk_div,
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

  output logic                      sd_clk,
  output logic                      sd_cmd_o,
  output logic                      sd_cmd_oe,
  input  logic                      sd_cmd_i,
  input  logic [3:0]                sd_dat_i,

  output logic [MIG_ADDR_WIDTH-1:0] mig_app_addr,
  output logic [2:0]                mig_app_cmd,
  output logic                      mig_app_en,
  input  logic                      mig_app_rdy,
  output logic [MIG_DATA_WIDTH-1:0] mig_app_wdf_data,
  output logic [MIG_DATA_WIDTH/8-1:0] mig_app_wdf_mask,
  output logic                      mig_app_wdf_wren,
  output logic                      mig_app_wdf_end,
  input  logic                      mig_app_wdf_rdy
);
  logic sd_cmd_valid;
  logic sd_cmd_ready;
  logic [5:0] sd_cmd_index;
  logic [31:0] sd_cmd_arg;
  logic [1:0] sd_cmd_resp_type;
  logic sd_cmd_data_read;
  logic [15:0] sd_cmd_block_len;
  logic [15:0] sd_cmd_block_count;
  logic sd_rsp_valid;
  logic [2:0] sd_rsp_status;
  logic [119:0] sd_rsp_data;
  logic sd_data_valid;
  logic sd_data_ready;
  logic [7:0] sd_data;
  logic sd_data_last;
  logic [2:0] sd_data_status;
  logic [SD_DIV_WIDTH-1:0] selected_sd_clk_div;

  assign selected_sd_clk_div = sd_initialized ? sd_transfer_clk_div : sd_init_clk_div;

  smart_artix_sd_native_asset_loader #(
    .LBA_WIDTH(LBA_WIDTH),
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH)
  ) loader (
    .clk,
    .rst,
    .start,
    .ddr_init_calib_complete,
    .busy,
    .asset_loaded,
    .sd_initialized,
    .status_state,
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
    .sd_rsp_valid,
    .sd_rsp_status,
    .sd_rsp_data,
    .sd_data_valid,
    .sd_data_ready,
    .sd_data,
    .sd_data_last,
    .sd_data_status,
    .mig_app_addr,
    .mig_app_cmd,
    .mig_app_en,
    .mig_app_rdy,
    .mig_app_wdf_data,
    .mig_app_wdf_mask,
    .mig_app_wdf_wren,
    .mig_app_wdf_end,
    .mig_app_wdf_rdy
  );

  smart_artix_sd_native_pin_phy #(
    .DIV_WIDTH(SD_DIV_WIDTH)
  ) phy (
    .clk,
    .rst,
    .clk_div(selected_sd_clk_div),
    .cmd_valid(sd_cmd_valid),
    .cmd_ready(sd_cmd_ready),
    .cmd_index(sd_cmd_index),
    .cmd_arg(sd_cmd_arg),
    .cmd_resp_type(sd_cmd_resp_type),
    .cmd_data_read(sd_cmd_data_read),
    .cmd_block_len(sd_cmd_block_len),
    .cmd_block_count(sd_cmd_block_count),
    .rsp_valid(sd_rsp_valid),
    .rsp_status(sd_rsp_status),
    .rsp_data(sd_rsp_data),
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
endmodule
