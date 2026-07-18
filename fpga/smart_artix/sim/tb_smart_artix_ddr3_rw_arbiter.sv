module tb_smart_artix_ddr3_rw_arbiter;
  logic clk;
  logic rst;
  smart_artix_pkg::mig_app_command_t read_command;
  smart_artix_pkg::mig_app_response_t read_response;
  smart_artix_pkg::mig_app_command_t debug_command;
  smart_artix_pkg::mig_app_write_data_t debug_write_data;
  smart_artix_pkg::mig_app_response_t debug_response;
  smart_artix_pkg::mig_app_command_t write_command;
  smart_artix_pkg::mig_app_write_data_t write_data;
  smart_artix_pkg::mig_app_response_t write_response;
  smart_artix_pkg::mig_app_command_t mig_app_command;
  smart_artix_pkg::mig_app_write_data_t mig_app_write_data;
  smart_artix_pkg::mig_app_response_t mig_app_response;
  int errors;

  smart_artix_ddr3_rw_arbiter dut (
    .clk,
    .rst,
    .read_command,
    .read_response,
    .debug_command,
    .debug_write_data,
    .debug_response,
    .write_command,
    .write_data,
    .write_response,
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
    read_command = '0;
    read_command.cmd = 3'b001;
    debug_command = '0;
    debug_command.cmd = 3'b001;
    debug_write_data = '0;
    write_command = '0;
    write_command.cmd = 3'b000;
    write_data = '0;
    mig_app_response = '0;
    mig_app_response.rdy = 1'b1;
    mig_app_response.rd_data = 128'hdead_beef_0000_0001_0000_0002_0000_0003;
    mig_app_response.wdf_rdy = 1'b1;
    errors = 0;

    repeat (2) @(posedge clk);
    rst = 1'b0;

    @(negedge clk);
    write_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0040);
    write_command.en = 1'b1;
    write_data.data = 128'h0010_000f_000e_000d_000c_000b_000a_0009;
    write_data.mask = 16'h00f0;
    write_data.wren = 1'b1;
    write_data.end_ = 1'b1;
    #1;
    check(mig_app_command.en, "arbiter did not forward write command when read idle");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0040),
          "arbiter write address mismatch");
    check(mig_app_command.cmd == 3'b000, "arbiter write command mismatch");
    check(write_response.rdy, "arbiter did not return write command ready");
    check(!read_response.rdy, "arbiter returned read ready without read request");
    check(mig_app_write_data.data == write_data.data, "arbiter write data mismatch");
    check(mig_app_write_data.mask == write_data.mask, "arbiter write mask mismatch");
    check(mig_app_write_data.wren && mig_app_write_data.end_,
          "arbiter did not forward write data strobes");
    check(write_response.wdf_rdy, "arbiter did not return write-data ready");

    @(negedge clk);
    read_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0080);
    read_command.en = 1'b1;
    write_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_00c0);
    write_command.en = 1'b1;
    #1;
    check(mig_app_command.en, "arbiter did not forward read command");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0080),
          "arbiter did not prioritize read address");
    check(mig_app_command.cmd == 3'b001, "arbiter read command mismatch");
    check(read_response.rdy, "arbiter did not return read ready");
    check(!write_response.rdy, "arbiter returned write ready while read had priority");
    check(mig_app_write_data.wren, "arbiter should still forward independent write-data channel");

    @(negedge clk);
    read_command.en = 1'b0;
    debug_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0180);
    debug_command.cmd = 3'b001;
    debug_command.en = 1'b1;
    write_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0200);
    write_command.en = 1'b1;
    #1;
    check(mig_app_command.en, "arbiter did not forward debug command");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0180),
          "arbiter debug address mismatch");
    check(mig_app_command.cmd == 3'b001, "arbiter debug command mismatch");
    check(debug_response.rdy, "arbiter did not return debug ready");
    check(!write_response.rdy, "arbiter returned write ready while debug had priority");

    @(negedge clk);
    debug_command.en = 1'b0;
    debug_write_data.data = 128'h1111_2222_3333_4444_5555_6666_7777_8888;
    debug_write_data.mask = 16'h0f0f;
    debug_write_data.wren = 1'b1;
    debug_write_data.end_ = 1'b1;
    write_data.data = 128'haaaa_bbbb_cccc_dddd_eeee_ffff_0000_1111;
    write_data.mask = 16'hf0f0;
    write_data.wren = 1'b1;
    write_data.end_ = 1'b1;
    #1;
    check(mig_app_write_data.data == debug_write_data.data, "arbiter debug write data mismatch");
    check(mig_app_write_data.mask == debug_write_data.mask, "arbiter debug write mask mismatch");
    check(debug_response.wdf_rdy, "arbiter did not return debug write-data ready");
    check(!write_response.wdf_rdy,
          "arbiter returned loader write-data ready while debug write data active");

    @(negedge clk);
    debug_write_data.wren = 1'b0;
    mig_app_response.rd_data_valid = 1'b1;
    mig_app_response.rd_data_end = 1'b1;
    #1;
    check(read_response.rd_data_valid, "arbiter did not route read data valid");
    check(read_response.rd_data_end, "arbiter did not route read data end");
    check(read_response.rd_data == mig_app_response.rd_data, "arbiter read data mismatch");
    check(debug_response.rd_data_valid, "arbiter did not route debug read data valid");
    check(debug_response.rd_data_end, "arbiter did not route debug read data end");
    check(debug_response.rd_data == mig_app_response.rd_data, "arbiter debug read data mismatch");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_ddr3_rw_arbiter errors=%0d", errors);

    $display("PASS: smart_artix_ddr3_rw_arbiter");
    $finish;
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_response_fields;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_response_fields = read_response.wdf_rdy
      ^ write_response.rd_data_valid ^ write_response.rd_data_end ^ (^write_response.rd_data);
endmodule
