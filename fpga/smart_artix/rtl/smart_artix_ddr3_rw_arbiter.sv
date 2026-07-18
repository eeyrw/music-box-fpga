module smart_artix_ddr3_rw_arbiter (
  input  logic                      clk,
  input  logic                      rst,

  input  smart_artix_pkg::mig_app_command_t    read_command,
  output smart_artix_pkg::mig_app_response_t   read_response,

  input  smart_artix_pkg::mig_app_command_t    debug_command,
  input  smart_artix_pkg::mig_app_write_data_t debug_write_data,
  output smart_artix_pkg::mig_app_response_t   debug_response,

  input  smart_artix_pkg::mig_app_command_t    write_command,
  input  smart_artix_pkg::mig_app_write_data_t write_data,
  output smart_artix_pkg::mig_app_response_t   write_response,

  output smart_artix_pkg::mig_app_command_t    mig_app_command,
  output smart_artix_pkg::mig_app_write_data_t mig_app_write_data,
  input  smart_artix_pkg::mig_app_response_t   mig_app_response
);
  logic grant_read_cmd;
  logic grant_debug_cmd;
  logic grant_debug_wdf;

  assign grant_read_cmd = read_command.en;
  assign grant_debug_cmd = !grant_read_cmd && debug_command.en;
  assign grant_debug_wdf = debug_write_data.wren;

  assign mig_app_command = grant_read_cmd ? read_command :
                           (grant_debug_cmd ? debug_command : write_command);

  assign read_response.rdy = grant_read_cmd ? mig_app_response.rdy : 1'b0;
  assign read_response.wdf_rdy = 1'b0;
  assign debug_response.rdy = grant_debug_cmd ? mig_app_response.rdy : 1'b0;
  assign write_response.rdy = (!grant_read_cmd && !grant_debug_cmd) ? mig_app_response.rdy : 1'b0;

  assign mig_app_write_data = grant_debug_wdf ? debug_write_data : write_data;
  assign debug_response.wdf_rdy = grant_debug_wdf ? mig_app_response.wdf_rdy : 1'b0;
  assign write_response.wdf_rdy = (!grant_debug_wdf) ? mig_app_response.wdf_rdy : 1'b0;

  assign read_response.rd_data = mig_app_response.rd_data;
  assign read_response.rd_data_valid = mig_app_response.rd_data_valid;
  assign read_response.rd_data_end = mig_app_response.rd_data_end;
  assign debug_response.rd_data = mig_app_response.rd_data;
  assign debug_response.rd_data_valid = mig_app_response.rd_data_valid;
  assign debug_response.rd_data_end = mig_app_response.rd_data_end;
  assign write_response.rd_data = mig_app_response.rd_data;
  assign write_response.rd_data_valid = mig_app_response.rd_data_valid;
  assign write_response.rd_data_end = mig_app_response.rd_data_end;

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_clk_rst;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_clk_rst = clk ^ rst;
endmodule
