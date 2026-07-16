module smart_artix_sd_ddr3_asset_loader #(
  parameter int LBA_WIDTH = 32,
  parameter int MIG_ADDR_WIDTH = 28,
  parameter int MIG_DATA_WIDTH = 128
) (
  input  logic                      clk,
  input  logic                      rst,

  input  logic                      start,
  input  logic                      ddr_init_calib_complete,
  output logic                      busy,
  output logic                      asset_loaded,
  output logic [3:0]                status_state,
  output logic [7:0]                error_code,
  output logic [31:0]               bytes_loaded,
  output logic [31:0]               sf2_size_bytes,
  output logic [LBA_WIDTH-1:0]      current_lba,

  output logic                      sd_req_valid,
  input  logic                      sd_req_ready,
  output logic [LBA_WIDTH-1:0]      sd_req_lba,
  input  logic                      sd_byte_valid,
  output logic                      sd_byte_ready,
  input  logic [7:0]                sd_byte_data,
  input  logic                      sd_byte_last,

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
  logic writer_start;
  logic [63:0] writer_base_byte_addr;
  logic [31:0] writer_total_bytes;
  logic writer_byte_valid;
  logic writer_byte_ready;
  logic [7:0] writer_byte_data;
  logic writer_busy;
  logic writer_done_pulse;
  logic writer_error_pulse;

  smart_artix_asset_loader #(
    .LBA_WIDTH(LBA_WIDTH)
  ) loader (
    .clk,
    .rst,
    .start,
    .ddr_init_calib_complete,
    .busy,
    .asset_loaded,
    .status_state,
    .error_code,
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
    .writer_start,
    .writer_base_byte_addr,
    .writer_total_bytes,
    .writer_byte_valid,
    .writer_byte_ready,
    .writer_byte_data,
    .writer_busy,
    .writer_done_pulse,
    .writer_error_pulse
  );

  smart_artix_ddr3_asset_writer #(
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH)
  ) writer (
    .clk,
    .rst,
    .start(writer_start),
    .base_byte_addr(writer_base_byte_addr),
    .total_bytes(writer_total_bytes),
    .busy(writer_busy),
    .done_pulse(writer_done_pulse),
    .error_pulse(writer_error_pulse),
    .byte_valid(writer_byte_valid),
    .byte_ready(writer_byte_ready),
    .byte_data(writer_byte_data),
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
endmodule
