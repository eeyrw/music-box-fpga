module tb_smart_artix_ddr3_line_reader;
  localparam int LINE_WORDS = 8;
  localparam int MIG_ADDR_WIDTH = 28;
  localparam int MIG_DATA_WIDTH = LINE_WORDS * 16;

  logic clk;
  logic rst;
  logic line_req_valid;
  logic line_req_ready;
  logic [31:0] line_req_addr;
  logic line_rsp_valid;
  logic [LINE_WORDS*16-1:0] line_rsp_data;
  logic mig_init_calib_complete;
  logic [MIG_ADDR_WIDTH-1:0] mig_app_addr;
  logic [2:0] mig_app_cmd;
  logic mig_app_en;
  logic mig_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] mig_app_rd_data;
  logic mig_app_rd_data_valid;
  logic mig_app_rd_data_end;
  int errors;

  smart_artix_ddr3_line_reader #(
    .LINE_WORDS(LINE_WORDS),
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH),
    .WORD_ADDR_SHIFT(1)
  ) dut (
    .clk,
    .rst,
    .line_req_valid,
    .line_req_ready,
    .line_req_addr,
    .line_rsp_valid,
    .line_rsp_data,
    .mig_init_calib_complete,
    .mig_app_addr,
    .mig_app_cmd,
    .mig_app_en,
    .mig_app_rdy,
    .mig_app_rd_data,
    .mig_app_rd_data_valid,
    .mig_app_rd_data_end
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
    line_req_valid = 1'b0;
    line_req_addr = '0;
    mig_init_calib_complete = 1'b0;
    mig_app_rdy = 1'b0;
    mig_app_rd_data = '0;
    mig_app_rd_data_valid = 1'b0;
    mig_app_rd_data_end = 1'b0;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);
    check(!line_req_ready, "line reader accepted requests before MIG calibration");

    mig_init_calib_complete = 1'b1;
    line_req_addr = 32'h0000_0040;
    line_req_valid = 1'b1;
    @(posedge clk);
    line_req_valid = 1'b0;
    @(negedge clk);
    check(mig_app_en, "line reader did not issue MIG read command");
    check(mig_app_cmd == 3'b001, "line reader used wrong MIG read command");
    check(mig_app_addr == MIG_ADDR_WIDTH'(32'h0000_0080), "line reader used wrong byte address");

    @(negedge clk);
    mig_app_rdy = 1'b1;
    @(posedge clk);
    @(negedge clk);
    mig_app_rdy = 1'b0;
    @(posedge clk);
    check(!line_rsp_valid, "line reader responded before MIG read data");

    @(negedge clk);
    mig_app_rd_data = 128'h0008_0007_0006_0005_0004_0003_0002_0001;
    mig_app_rd_data_valid = 1'b1;
    mig_app_rd_data_end = 1'b1;
    @(posedge clk);
    @(negedge clk);
    check(line_rsp_valid, "line reader did not emit a line response");
    check(line_rsp_data == 128'h0008_0007_0006_0005_0004_0003_0002_0001,
          "line reader returned wrong line data");
    mig_app_rd_data_valid = 1'b0;
    mig_app_rd_data_end = 1'b0;

    @(posedge clk);
    check(line_req_ready, "line reader did not return to idle after response");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_ddr3_line_reader errors=%0d", errors);

    $display("PASS: smart_artix_ddr3_line_reader");
    $finish;
  end
endmodule
