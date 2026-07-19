module tb_smart_artix_ddr3_rw_arbiter;
  logic clk;
  logic rst;
  smart_artix_pkg::mig_app_command_t read_command;
  smart_artix_pkg::mig_app_response_t read_response;
  smart_artix_pkg::mig_app_command_t reg_access_command;
  smart_artix_pkg::mig_app_write_data_t reg_access_write_data;
  smart_artix_pkg::mig_app_response_t reg_access_response;
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
    .reg_access_command,
    .reg_access_write_data,
    .reg_access_response,
    .write_command,
    .write_data,
    .write_response,
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );

/* verilator lint_off BLKSEQ */
  always #5 clk <= ~clk;
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
    reg_access_command = '0;
    reg_access_command.cmd = 3'b001;
    reg_access_write_data = '0;
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
    check(!mig_app_write_data.wren, "arbiter forwarded write data without the matching write command grant");
    check(!write_response.wdf_rdy,
          "arbiter returned write-data ready while read command had priority");

    @(posedge clk);
    @(negedge clk);
    read_command.en = 1'b0;
    mig_app_response.rdy = 1'b0;
    mig_app_response.wdf_rdy = 1'b1;
    #1;
    check(mig_app_command.en, "arbiter did not keep pending write command after read grant");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_00c0),
          "arbiter pending write address mismatch");
    check(mig_app_write_data.wren, "arbiter did not pair write data with pending write command");
    check(write_response.wdf_rdy, "arbiter did not return paired write-data ready");

    @(posedge clk);
    @(negedge clk);
    mig_app_response.rdy = 1'b1;
    mig_app_response.wdf_rdy = 1'b0;
    #1;
    check(mig_app_command.en, "arbiter did not keep write command until accepted");
    check(write_response.rdy, "arbiter did not return pending write command ready");
    check(!mig_app_write_data.wren, "arbiter resent already accepted write data");

    @(posedge clk);
    @(negedge clk);
    write_command.en = 1'b0;
    write_data.wren = 1'b0;
    mig_app_response.wdf_rdy = 1'b1;

    write_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0280);
    write_command.en = 1'b1;
    write_data.wren = 1'b1;
    #1;
    check(write_response.rdy, "arbiter blocked write command while read response was pending");
    check(write_response.wdf_rdy, "arbiter blocked write data while read response was pending");

    @(posedge clk);
    @(negedge clk);
    write_command.en = 1'b0;
    write_data.wren = 1'b0;
    mig_app_response.rd_data_valid = 1'b1;
    mig_app_response.rd_data_end = 1'b1;
    #1;
    check(read_response.rd_data_valid, "arbiter did not route read data valid");
    check(read_response.rd_data_end, "arbiter did not route read data end");
    check(read_response.rd_data == mig_app_response.rd_data, "arbiter read data mismatch");
    check(!reg_access_response.rd_data_valid, "arbiter broadcast read data to reg-access client");

    @(posedge clk);
    @(negedge clk);
    mig_app_response.rd_data_valid = 1'b0;
    mig_app_response.rd_data_end = 1'b0;
    reg_access_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0180);
    reg_access_command.cmd = 3'b001;
    reg_access_command.en = 1'b1;
    write_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0200);
    write_command.en = 1'b1;
    write_data.wren = 1'b1;
    #1;
    check(mig_app_command.en, "arbiter did not forward register-access command");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0180),
          "arbiter register-access address mismatch");
    check(mig_app_command.cmd == 3'b001, "arbiter register-access command mismatch");
    check(reg_access_response.rdy, "arbiter did not return reg-access ready");
    check(!write_response.rdy, "arbiter returned write ready while reg-access client had priority");
    check(!mig_app_write_data.wren, "arbiter forwarded loader write data during reg-access read");

    @(posedge clk);
    @(negedge clk);
    reg_access_command.en = 1'b0;
    write_command.en = 1'b0;
    write_data.wren = 1'b0;
    mig_app_response.rd_data = 128'h1234_5678_9abc_def0_1111_2222_3333_4444;
    mig_app_response.rd_data_valid = 1'b1;
    mig_app_response.rd_data_end = 1'b1;
    #1;
    check(reg_access_response.rd_data_valid, "arbiter did not route reg-access read data valid");
    check(reg_access_response.rd_data_end, "arbiter did not route reg-access read data end");
    check(reg_access_response.rd_data == mig_app_response.rd_data, "arbiter reg-access read data mismatch");
    check(!read_response.rd_data_valid, "arbiter broadcast reg-access read data to read client");

    @(posedge clk);
    @(negedge clk);
    mig_app_response.rd_data_valid = 1'b0;
    mig_app_response.rd_data_end = 1'b0;
    reg_access_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0300);
    reg_access_command.cmd = 3'b000;
    reg_access_command.en = 1'b1;
    reg_access_write_data.data = 128'h1111_2222_3333_4444_5555_6666_7777_8888;
    reg_access_write_data.mask = 16'h0f0f;
    reg_access_write_data.wren = 1'b1;
    reg_access_write_data.end_ = 1'b1;
    write_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0340);
    write_command.en = 1'b1;
    write_data.data = 128'haaaa_bbbb_cccc_dddd_eeee_ffff_0000_1111;
    write_data.mask = 16'hf0f0;
    write_data.wren = 1'b1;
    write_data.end_ = 1'b1;
    #1;
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(29'h000_0300),
          "arbiter reg-access write command address mismatch");
    check(reg_access_response.rdy, "arbiter did not return reg-access write command ready");
    check(!write_response.rdy, "arbiter returned loader ready while reg-access write had priority");
    check(mig_app_write_data.data == reg_access_write_data.data, "arbiter reg-access write data mismatch");
    check(mig_app_write_data.mask == reg_access_write_data.mask, "arbiter reg-access write mask mismatch");
    check(reg_access_response.wdf_rdy, "arbiter did not return reg-access write-data ready");
    check(!write_response.wdf_rdy,
          "arbiter returned loader write-data ready while reg-access write data active");

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
