module smart_artix_sd_ddr3_asset_loader #(
  parameter int LBA_WIDTH = 32
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

  output smart_artix_pkg::mig_app_command_t    mig_app_command,
  output smart_artix_pkg::mig_app_write_data_t mig_app_write_data,
  input  smart_artix_pkg::mig_app_response_t   mig_app_response
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

  smart_artix_ddr3_asset_writer writer (
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
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );
endmodule
