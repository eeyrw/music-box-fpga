module tb_smart_artix_sd_native_pin_phy_fake;
  logic clk;
  logic rst;
  logic [3:0] clk_div;
  logic cmd_valid;
  logic cmd_ready;
  logic [5:0] cmd_index;
  logic [31:0] cmd_arg;
  logic [1:0] cmd_resp_type;
  logic cmd_data_read;
  logic [15:0] cmd_block_len;
  logic [15:0] cmd_block_count;
  logic rsp_valid;
  logic [2:0] rsp_status;
  logic [119:0] rsp_data;
  logic data_valid;
  logic data_ready;
  logic [7:0] data;
  logic data_last;
  logic [2:0] data_status;
  logic sd_clk;
  logic sd_cmd_o;
  logic sd_cmd_oe;
  logic sd_cmd_i;
  logic [3:0] sd_dat_i;
  logic [5:0] last_cmd_index;
  logic [31:0] last_cmd_arg;
  logic saw_cmd17;
  int errors;
  int data_seen;

  smart_artix_sd_native_pin_phy #(
    .DIV_WIDTH(4),
    .RESPONSE_TIMEOUT_CYCLES(64),
    .DATA_TIMEOUT_CYCLES(128)
  ) dut (
    .clk,
    .rst,
    .clk_div,
    .cmd_valid,
    .cmd_ready,
    .cmd_index,
    .cmd_arg,
    .cmd_resp_type,
    .cmd_data_read,
    .cmd_block_len,
    .cmd_block_count,
    .rsp_valid,
    .rsp_status,
    .rsp_data,
    .data_valid,
    .data_ready,
    .data,
    .data_last,
    .data_status,
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i,
    .sd_dat_i
  );

  fake_sd_native_pin_model card (
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i,
    .sd_dat_i,
    .last_cmd_index,
    .last_cmd_arg,
    .saw_cmd17
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

/* verilator lint_off BLKSEQ */
  always_ff @(posedge clk) begin
    if (rst) begin
      data_seen <= 0;
    end else if (data_valid && data_ready) begin
      if (data != 8'hff) begin
        $error("pin fake data mismatch index=%0d got=%02x expected=ff", data_seen, data);
        errors++;
      end
      if (data_seen == 3)
        check(data_last, "pin fake final byte missing last");
      else
        check(!data_last, "pin fake early last");
      data_seen <= data_seen + 1;
    end
  end
/* verilator lint_on BLKSEQ */

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    clk_div = 4'd0;
    cmd_valid = 1'b0;
    cmd_index = 6'd0;
    cmd_arg = 32'd0;
    cmd_resp_type = 2'd0;
    cmd_data_read = 1'b0;
    cmd_block_len = 16'd0;
    cmd_block_count = 16'd0;
    data_ready = 1'b1;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    cmd_index = 6'd17;
    cmd_arg = 32'h0000_1234;
    cmd_resp_type = 2'd1;
    cmd_data_read = 1'b1;
    cmd_block_len = 16'd4;
    cmd_block_count = 16'd1;
    cmd_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cmd_valid = 1'b0;

    wait (rsp_valid);
    check(rsp_status == 3'd0, "pin fake response status mismatch");
    wait (data_seen == 4);
    repeat (2) @(posedge clk);
    check(saw_cmd17, "pin fake did not observe CMD17");
    check(last_cmd_index == 6'd17, "pin fake command index mismatch");
    check(last_cmd_arg == 32'h0000_1234, "pin fake command arg mismatch");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_native_pin_phy_fake errors=%0d", errors);

    $display("PASS: smart_artix_sd_native_pin_phy_fake");
    $finish;
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_rsp;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_rsp = (^rsp_data) ^ cmd_ready ^ (^data_status);
endmodule
