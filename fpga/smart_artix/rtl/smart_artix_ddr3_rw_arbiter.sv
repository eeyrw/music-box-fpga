module smart_artix_ddr3_rw_arbiter #(
  parameter int MIG_ADDR_WIDTH = 28,
  parameter int MIG_DATA_WIDTH = 128
) (
  input  logic                      clk,
  input  logic                      rst,

  input  logic [MIG_ADDR_WIDTH-1:0] read_app_addr,
  input  logic [2:0]                read_app_cmd,
  input  logic                      read_app_en,
  output logic                      read_app_rdy,
  output logic [MIG_DATA_WIDTH-1:0] read_app_rd_data,
  output logic                      read_app_rd_data_valid,
  output logic                      read_app_rd_data_end,

  input  logic [MIG_ADDR_WIDTH-1:0] write_app_addr,
  input  logic [2:0]                write_app_cmd,
  input  logic                      write_app_en,
  output logic                      write_app_rdy,
  input  logic [MIG_DATA_WIDTH-1:0] write_app_wdf_data,
  input  logic [MIG_DATA_WIDTH/8-1:0] write_app_wdf_mask,
  input  logic                      write_app_wdf_wren,
  input  logic                      write_app_wdf_end,
  output logic                      write_app_wdf_rdy,

  output logic [MIG_ADDR_WIDTH-1:0] mig_app_addr,
  output logic [2:0]                mig_app_cmd,
  output logic                      mig_app_en,
  input  logic                      mig_app_rdy,
  input  logic [MIG_DATA_WIDTH-1:0] mig_app_rd_data,
  input  logic                      mig_app_rd_data_valid,
  input  logic                      mig_app_rd_data_end,
  output logic [MIG_DATA_WIDTH-1:0] mig_app_wdf_data,
  output logic [MIG_DATA_WIDTH/8-1:0] mig_app_wdf_mask,
  output logic                      mig_app_wdf_wren,
  output logic                      mig_app_wdf_end,
  input  logic                      mig_app_wdf_rdy
);
  logic grant_read_cmd;

  assign grant_read_cmd = read_app_en;

  assign mig_app_addr = grant_read_cmd ? read_app_addr : write_app_addr;
  assign mig_app_cmd = grant_read_cmd ? read_app_cmd : write_app_cmd;
  assign mig_app_en = grant_read_cmd ? read_app_en : write_app_en;

  assign read_app_rdy = grant_read_cmd ? mig_app_rdy : 1'b0;
  assign write_app_rdy = (!grant_read_cmd) ? mig_app_rdy : 1'b0;

  assign mig_app_wdf_data = write_app_wdf_data;
  assign mig_app_wdf_mask = write_app_wdf_mask;
  assign mig_app_wdf_wren = write_app_wdf_wren;
  assign mig_app_wdf_end = write_app_wdf_end;
  assign write_app_wdf_rdy = mig_app_wdf_rdy;

  assign read_app_rd_data = mig_app_rd_data;
  assign read_app_rd_data_valid = mig_app_rd_data_valid;
  assign read_app_rd_data_end = mig_app_rd_data_end;

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_clk_rst;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_clk_rst = clk ^ rst;
endmodule
