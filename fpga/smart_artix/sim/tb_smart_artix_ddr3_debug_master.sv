module tb_smart_artix_ddr3_debug_master;
  localparam int MIG_ADDR_WIDTH = 28;
  localparam int MIG_DATA_WIDTH = 128;
  localparam int MASK_WIDTH = MIG_DATA_WIDTH / 8;

  logic clk;
  logic rst;
  logic start;
  logic write;
  logic [31:0] byte_addr;
  logic [MIG_DATA_WIDTH-1:0] wdata;
  logic [MASK_WIDTH-1:0] byte_enable;
  logic ready;
  logic busy;
  logic done_pulse;
  logic error_pulse;
  logic [MIG_DATA_WIDTH-1:0] rdata;
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

  smart_artix_ddr3_debug_master #(
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH)
  ) dut (
    .clk,
    .rst,
    .start,
    .write,
    .byte_addr,
    .wdata,
    .byte_enable,
    .ready,
    .busy,
    .done_pulse,
    .error_pulse,
    .rdata,
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
    start = 1'b0;
    write = 1'b0;
    byte_addr = '0;
    wdata = 128'h0123_4567_89ab_cdef_fedc_ba98_7654_3210;
    byte_enable = 16'h00ff;
    mig_app_rdy = 1'b1;
    mig_app_rd_data = 128'haaaa_bbbb_cccc_dddd_eeee_ffff_1111_2222;
    mig_app_rd_data_valid = 1'b0;
    mig_app_rd_data_end = 1'b0;
    mig_app_wdf_rdy = 1'b1;
    errors = 0;

    repeat (2) @(posedge clk);
    rst = 1'b0;

    @(negedge clk);
    byte_addr = 32'h0000_0004;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    #1;
    check(error_pulse, "unaligned debug access did not report error");
    check(ready && !busy, "unaligned debug access should remain idle");

    @(negedge clk);
    byte_addr = 32'h0000_0100;
    byte_enable = 16'h0000;
    write = 1'b1;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    #1;
    check(error_pulse, "zero-byte write did not report error");
    check(ready && !busy, "zero-byte write should remain idle");

    @(negedge clk);
    byte_enable = 16'h00ff;
    write = 1'b1;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    #1;
    check(busy && !ready, "debug write did not enter busy state");
    check(mig_app_en && mig_app_cmd == 3'b000, "debug write command not driven");
    check(mig_app_addr == 28'h000_0100, "debug write address mismatch");
    check(mig_app_wdf_wren && mig_app_wdf_end, "debug write data strobe not driven");
    check(mig_app_wdf_data == wdata, "debug write data mismatch");
    check(mig_app_wdf_mask == 16'hff00, "debug write mask mismatch");
    @(negedge clk);
    #1;
    check(done_pulse, "debug write did not complete after command/data ready");
    check(ready && !busy, "debug write did not return to idle");

    @(negedge clk);
    write = 1'b0;
    byte_addr = 32'h0000_0200;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    #1;
    check(mig_app_en && mig_app_cmd == 3'b001, "debug read command not driven");
    check(mig_app_addr == 28'h000_0200, "debug read address mismatch");
    @(negedge clk);
    mig_app_rd_data_valid = 1'b1;
    mig_app_rd_data_end = 1'b1;
    @(negedge clk);
    mig_app_rd_data_valid = 1'b0;
    mig_app_rd_data_end = 1'b0;
    #1;
    check(done_pulse, "debug read did not complete on read data end");
    check(rdata == 128'haaaa_bbbb_cccc_dddd_eeee_ffff_1111_2222, "debug read data mismatch");
    check(ready && !busy, "debug read did not return to idle");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_ddr3_debug_master errors=%0d", errors);

    $display("PASS: smart_artix_ddr3_debug_master");
    $finish;
  end
endmodule
