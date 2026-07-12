module smart_artix_sd_spi_pin_asset_loader #(
  parameter int LBA_WIDTH = 32,
  parameter int MIG_ADDR_WIDTH = 28,
  parameter int MIG_DATA_WIDTH = 128,
  parameter int SPI_DIV_WIDTH = 16
) (
  input  logic                      clk,
  input  logic                      rst,

  input  logic                      start,
  input  logic [SPI_DIV_WIDTH-1:0]  sd_spi_clk_div,
  input  logic                      ddr_init_calib_complete,
  output logic                      busy,
  output logic                      asset_loaded,
  output logic [3:0]                status_state,
  output logic [7:0]                sd_error_code,
  output logic [7:0]                loader_error_code,
  output logic [63:0]               bytes_loaded,
  output logic [63:0]               sf2_size_bytes,
  output logic [LBA_WIDTH-1:0]      current_lba,

  output logic                      sd_clk,
  output logic                      sd_cmd_mosi,
  input  logic                      sd_dat0_miso,
  output logic                      sd_dat3_cs_n,

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
  logic sd_spi_cs_n;
  logic sd_spi_tx_valid;
  logic sd_spi_tx_ready;
  logic [7:0] sd_spi_tx_data;
  logic sd_spi_rx_valid;
  logic [7:0] sd_spi_rx_data;

  smart_artix_sd_spi_asset_loader #(
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
    .status_state,
    .sd_error_code,
    .loader_error_code,
    .bytes_loaded,
    .sf2_size_bytes,
    .current_lba,
    .sd_spi_cs_n,
    .sd_spi_tx_valid,
    .sd_spi_tx_ready,
    .sd_spi_tx_data,
    .sd_spi_rx_valid,
    .sd_spi_rx_data,
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

  smart_artix_sd_spi_byte_master #(
    .DIV_WIDTH(SPI_DIV_WIDTH)
  ) spi_master (
    .clk,
    .rst,
    .clk_div(sd_spi_clk_div),
    .cs_n_in(sd_spi_cs_n),
    .tx_valid(sd_spi_tx_valid),
    .tx_ready(sd_spi_tx_ready),
    .tx_data(sd_spi_tx_data),
    .rx_valid(sd_spi_rx_valid),
    .rx_data(sd_spi_rx_data),
    .sd_clk,
    .sd_cmd_mosi,
    .sd_dat0_miso,
    .sd_dat3_cs_n
  );
endmodule
