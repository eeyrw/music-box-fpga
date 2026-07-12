module tb_smart_artix_mig_stub;
  localparam int ADDR_WIDTH = 28;
  localparam int DATA_WIDTH = 128;

  logic clk;
  logic rst;
  logic init_calib_complete;
  logic [ADDR_WIDTH-1:0] app_addr;
  logic [2:0] app_cmd;
  logic app_en;
  logic app_rdy;
  logic [DATA_WIDTH-1:0] app_rd_data;
  logic app_rd_data_valid;
  logic app_rd_data_end;
/* verilator lint_off UNUSEDSIGNAL */
  logic unused_app_rd_data_upper;
/* verilator lint_on UNUSEDSIGNAL */
  int errors;

  assign unused_app_rd_data_upper = ^app_rd_data[DATA_WIDTH-1:32];

  smart_artix_mig_stub #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .INIT_CALIB_CYCLES(3),
    .READ_LATENCY_CYCLES(2)
  ) dut (
    .clk,
    .rst,
    .init_calib_complete,
    .app_addr,
    .app_cmd,
    .app_en,
    .app_rdy,
    .app_rd_data,
    .app_rd_data_valid,
    .app_rd_data_end
  );

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
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
    app_addr = '0;
    app_cmd = 3'b001;
    app_en = 1'b0;
    errors = 0;

    repeat (2) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);
    check(!app_rdy, "MIG stub became ready before calibration delay");

    wait (init_calib_complete);
    @(negedge clk);
    check(app_rdy, "MIG stub did not become ready after calibration");

    app_addr = 28'h000_0100;
    app_en = 1'b1;
    @(posedge clk);
    @(negedge clk);
    app_en = 1'b0;
    check(!app_rdy, "MIG stub accepted a second request while read was pending");

    repeat (3) @(posedge clk);
    @(negedge clk);
    check(app_rd_data_valid, "MIG stub did not return read data");
    check(app_rd_data_end, "MIG stub did not mark end of read data");
    check(app_rd_data[15:0] == 16'h0100, "MIG stub word 0 pattern mismatch");
    check(app_rd_data[31:16] == 16'h0101, "MIG stub word 1 pattern mismatch");

    @(posedge clk);
    check(app_rdy, "MIG stub did not return ready after read response");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_mig_stub errors=%0d", errors);

    $display("PASS: smart_artix_mig_stub");
    $finish;
  end
endmodule
