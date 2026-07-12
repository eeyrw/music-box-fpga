module tb_smart_artix_ddr3_rw_arbiter;
  localparam int MIG_ADDR_WIDTH = 28;
  localparam int MIG_DATA_WIDTH = 128;
  localparam int MASK_WIDTH = MIG_DATA_WIDTH / 8;

  logic clk;
  logic rst;
  logic [MIG_ADDR_WIDTH-1:0] read_app_addr;
  logic [2:0] read_app_cmd;
  logic read_app_en;
  logic read_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] read_app_rd_data;
  logic read_app_rd_data_valid;
  logic read_app_rd_data_end;
  logic [MIG_ADDR_WIDTH-1:0] write_app_addr;
  logic [2:0] write_app_cmd;
  logic write_app_en;
  logic write_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] write_app_wdf_data;
  logic [MASK_WIDTH-1:0] write_app_wdf_mask;
  logic write_app_wdf_wren;
  logic write_app_wdf_end;
  logic write_app_wdf_rdy;
  logic [MIG_ADDR_WIDTH-1:0] mig_app_addr;
  logic [2:0] mig_app_cmd;
  logic mig_app_en;
  logic mig_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] mig_app_rd_data;
  logic mig_app_rd_data_valid;
  logic mig_app_rd_data_end;
  logic [MIG_DATA_WIDTH-1:0] mig_app_wdf_data;
  logic [MASK_WIDTH-1:0] mig_app_wdf_mask;
  logic mig_app_wdf_wren;
  logic mig_app_wdf_end;
  logic mig_app_wdf_rdy;
  int errors;

  smart_artix_ddr3_rw_arbiter #(
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH)
  ) dut (
    .clk,
    .rst,
    .read_app_addr,
    .read_app_cmd,
    .read_app_en,
    .read_app_rdy,
    .read_app_rd_data,
    .read_app_rd_data_valid,
    .read_app_rd_data_end,
    .write_app_addr,
    .write_app_cmd,
    .write_app_en,
    .write_app_rdy,
    .write_app_wdf_data,
    .write_app_wdf_mask,
    .write_app_wdf_wren,
    .write_app_wdf_end,
    .write_app_wdf_rdy,
    .mig_app_addr,
    .mig_app_cmd,
    .mig_app_en,
    .mig_app_rdy,
    .mig_app_rd_data,
    .mig_app_rd_data_valid,
    .mig_app_rd_data_end,
    .mig_app_wdf_data,
    .mig_app_wdf_mask,
    .mig_app_wdf_wren,
    .mig_app_wdf_end,
    .mig_app_wdf_rdy
  );

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
/* verilator lint_on BLKSEQ */

/* verilator lint_off BLKSEQ */
  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask
/* verilator lint_on BLKSEQ */

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    read_app_addr = '0;
    read_app_cmd = 3'b001;
    read_app_en = 1'b0;
    write_app_addr = '0;
    write_app_cmd = 3'b000;
    write_app_en = 1'b0;
    write_app_wdf_data = '0;
    write_app_wdf_mask = '0;
    write_app_wdf_wren = 1'b0;
    write_app_wdf_end = 1'b0;
    mig_app_rdy = 1'b1;
    mig_app_rd_data = 128'hdead_beef_0000_0001_0000_0002_0000_0003;
    mig_app_rd_data_valid = 1'b0;
    mig_app_rd_data_end = 1'b0;
    mig_app_wdf_rdy = 1'b1;
    errors = 0;

    repeat (2) @(posedge clk);
    rst = 1'b0;

    @(negedge clk);
    write_app_addr = 28'h000_0040;
    write_app_en = 1'b1;
    write_app_wdf_data = 128'h0010_000f_000e_000d_000c_000b_000a_0009;
    write_app_wdf_mask = 16'h00f0;
    write_app_wdf_wren = 1'b1;
    write_app_wdf_end = 1'b1;
    #1;
    check(mig_app_en, "arbiter did not forward write command when read idle");
    check(mig_app_addr == 28'h000_0040, "arbiter write address mismatch");
    check(mig_app_cmd == 3'b000, "arbiter write command mismatch");
    check(write_app_rdy, "arbiter did not return write command ready");
    check(!read_app_rdy, "arbiter returned read ready without read request");
    check(mig_app_wdf_data == write_app_wdf_data, "arbiter write data mismatch");
    check(mig_app_wdf_mask == write_app_wdf_mask, "arbiter write mask mismatch");
    check(mig_app_wdf_wren && mig_app_wdf_end, "arbiter did not forward write data strobes");
    check(write_app_wdf_rdy, "arbiter did not return write-data ready");

    @(negedge clk);
    read_app_addr = 28'h000_0080;
    read_app_en = 1'b1;
    write_app_addr = 28'h000_00c0;
    write_app_en = 1'b1;
    #1;
    check(mig_app_en, "arbiter did not forward read command");
    check(mig_app_addr == 28'h000_0080, "arbiter did not prioritize read address");
    check(mig_app_cmd == 3'b001, "arbiter read command mismatch");
    check(read_app_rdy, "arbiter did not return read ready");
    check(!write_app_rdy, "arbiter returned write ready while read had priority");
    check(mig_app_wdf_wren, "arbiter should still forward independent write-data channel");

    @(negedge clk);
    mig_app_rd_data_valid = 1'b1;
    mig_app_rd_data_end = 1'b1;
    #1;
    check(read_app_rd_data_valid, "arbiter did not route read data valid");
    check(read_app_rd_data_end, "arbiter did not route read data end");
    check(read_app_rd_data == mig_app_rd_data, "arbiter read data mismatch");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_ddr3_rw_arbiter errors=%0d", errors);

    $display("PASS: smart_artix_ddr3_rw_arbiter");
    $finish;
  end
endmodule
