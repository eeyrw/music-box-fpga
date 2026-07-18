module tb_smart_artix_ddr3_debug_master;
  logic clk;
  logic rst;
  logic start;
  logic write;
  logic [31:0] byte_addr;
  logic [smart_artix_pkg::MIG_DATA_WIDTH-1:0] wdata;
  logic [smart_artix_pkg::MIG_MASK_WIDTH-1:0] byte_enable;
  logic ready;
  logic busy;
  logic done_pulse;
  logic error_pulse;
  logic [smart_artix_pkg::MIG_DATA_WIDTH-1:0] rdata;
  smart_artix_pkg::mig_app_command_t mig_app_command;
  smart_artix_pkg::mig_app_write_data_t mig_app_write_data;
  smart_artix_pkg::mig_app_response_t mig_app_response;
  int errors;

  smart_artix_ddr3_debug_master dut (
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
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
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
    mig_app_response = '0;
    mig_app_response.rdy = 1'b1;
    mig_app_response.rd_data = 128'haaaa_bbbb_cccc_dddd_eeee_ffff_1111_2222;
    mig_app_response.wdf_rdy = 1'b1;
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
    check(mig_app_command.en && mig_app_command.cmd == 3'b000,
          "debug write command not driven");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0100),
          "debug write address mismatch");
    check(mig_app_write_data.wren && mig_app_write_data.end_,
          "debug write data strobe not driven");
    check(mig_app_write_data.data == wdata, "debug write data mismatch");
    check(mig_app_write_data.mask == 16'hff00, "debug write mask mismatch");
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
    check(mig_app_command.en && mig_app_command.cmd == 3'b001,
          "debug read command not driven");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0200),
          "debug read address mismatch");
    @(negedge clk);
    mig_app_response.rd_data_valid = 1'b1;
    mig_app_response.rd_data_end = 1'b1;
    @(negedge clk);
    mig_app_response.rd_data_valid = 1'b0;
    mig_app_response.rd_data_end = 1'b0;
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
