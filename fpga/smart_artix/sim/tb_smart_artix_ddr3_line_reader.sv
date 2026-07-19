module tb_smart_artix_ddr3_line_reader;
  logic clk;
  logic rst;
  smart_artix_pkg::line_read_request_t line_req;
  logic line_req_ready;
  smart_artix_pkg::line_read_response_t line_rsp;
  logic mig_init_calib_complete;
  smart_artix_pkg::mig_app_command_t mig_app_command;
  smart_artix_pkg::mig_app_response_t mig_app_response;
  int errors;

  smart_artix_ddr3_line_reader #(
    .WORD_ADDR_SHIFT(1)
  ) dut (
    .clk,
    .rst,
    .line_req,
    .line_req_ready,
    .line_rsp,
    .mig_init_calib_complete,
    .mig_app_command,
    .mig_app_response
  );

/* verilator lint_off BLKSEQ */
  always #5 clk <= ~clk;
/* verilator lint_on BLKSEQ */

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    line_req = '0;
    mig_init_calib_complete = 1'b0;
    mig_app_response = '0;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);
    check(!line_req_ready, "line reader accepted requests before MIG calibration");

    mig_init_calib_complete = 1'b1;
    line_req.addr = 32'h0000_0040;
    line_req.valid = 1'b1;
    @(posedge clk);
    line_req.valid = 1'b0;
    @(negedge clk);
    check(mig_app_command.en, "line reader did not issue MIG read command");
    check(mig_app_command.cmd == 3'b001, "line reader used wrong MIG read command");
    check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(32'h0000_0080),
          "line reader used wrong byte address");

    @(negedge clk);
    mig_app_response.rdy = 1'b1;
    @(posedge clk);
    @(negedge clk);
    mig_app_response.rdy = 1'b0;
    @(posedge clk);
    check(!line_rsp.valid, "line reader responded before MIG read data");

    @(negedge clk);
    mig_app_response.rd_data = 128'h0008_0007_0006_0005_0004_0003_0002_0001;
    mig_app_response.rd_data_valid = 1'b1;
    mig_app_response.rd_data_end = 1'b1;
    @(posedge clk);
    @(negedge clk);
    check(line_rsp.valid, "line reader did not emit a line response");
    check(line_rsp.data == 128'h0008_0007_0006_0005_0004_0003_0002_0001,
          "line reader returned wrong line data");
    mig_app_response.rd_data_valid = 1'b0;
    mig_app_response.rd_data_end = 1'b0;

    @(posedge clk);
    check(line_req_ready, "line reader did not return to idle after response");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_ddr3_line_reader errors=%0d", errors);

    $display("PASS: smart_artix_ddr3_line_reader");
    $finish;
  end
endmodule
