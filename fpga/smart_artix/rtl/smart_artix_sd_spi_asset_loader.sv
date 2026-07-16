module smart_artix_sd_spi_asset_loader #(
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
  output logic [7:0]                sd_error_code,
  output logic [7:0]                loader_error_code,
  output logic [31:0]               bytes_loaded,
  output logic [31:0]               sf2_size_bytes,
  output logic [LBA_WIDTH-1:0]      current_lba,

  output logic                      sd_spi_cs_n,
  output logic                      sd_spi_tx_valid,
  input  logic                      sd_spi_tx_ready,
  output logic [7:0]                sd_spi_tx_data,
  input  logic                      sd_spi_rx_valid,
  input  logic [7:0]                sd_spi_rx_data,

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
  logic sd_initialized;
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

  smart_artix_sd_spi_block_reader #(
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
    .spi_cs_n(sd_spi_cs_n),
    .spi_tx_valid(sd_spi_tx_valid),
    .spi_tx_ready(sd_spi_tx_ready),
    .spi_tx_data(sd_spi_tx_data),
    .spi_rx_valid(sd_spi_rx_valid),
    .spi_rx_data(sd_spi_rx_data)
  );

  smart_artix_sd_ddr3_asset_loader #(
    .LBA_WIDTH(LBA_WIDTH),
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH)
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
