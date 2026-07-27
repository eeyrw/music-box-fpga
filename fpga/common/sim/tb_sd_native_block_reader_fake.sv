module tb_sd_native_block_reader_fake;
  import sd_native_pkg::*;
  localparam int LBA_WIDTH = 32;

  logic clk;
  logic rst;
  logic init_start;
  logic initialized;
  logic high_speed_active;
  logic busy;
  logic [7:0] error_code;
  logic [7:0] retry_count;
  logic [3:0] recovery_error_code;
  logic block_req_valid;
  logic block_req_ready;
  logic [LBA_WIDTH-1:0] block_req_lba;
  logic [15:0] block_req_block_count;
  logic block_byte_valid;
  logic block_byte_ready;
  logic [7:0] block_byte_data;
  logic block_byte_last;
  logic phy_cmd_valid;
  logic phy_cmd_ready;
  logic [5:0] phy_cmd_index;
  logic [31:0] phy_cmd_arg;
  sd_response_type_t phy_cmd_resp_type;
  logic phy_cmd_data_read;
  logic [15:0] phy_cmd_block_len;
  logic [15:0] phy_cmd_block_count;
  logic phy_rsp_data_proceed;
  logic phy_rsp_data_cancel;
  logic phy_abort_request;
  logic phy_rsp_valid;
  sd_transport_status_t phy_rsp_status;
  logic [119:0] phy_rsp_data;
  logic phy_transaction_done;
  logic phy_data_valid;
  logic phy_data_ready;
  logic [7:0] phy_data;
  logic phy_data_last;
  sd_transport_status_t phy_data_status;
  logic [7:0] illegal_command_count;
  logic [31:0] last_read_lba;
  logic selected;
  logic wide_bus;
  int errors;
  int data_seen;

  sd_native_block_reader #(
    .LBA_WIDTH(LBA_WIDTH),
    .CLK_HZ(1_000),
    .INIT_TIMEOUT_MS(1_000)
  ) dut (
    .clk,
    .rst,
    .init_start,
    .initialized,
    .high_speed_active,
    .busy,
    .error_code,
    .retry_count,
    .recovery_error_code,
    .block_req_valid,
    .block_req_ready,
    .block_req_lba,
    .block_req_block_count,
    .block_byte_valid,
    .block_byte_ready,
    .block_byte_data,
    .block_byte_last,
    .phy_cmd_valid,
    .phy_cmd_ready,
    .phy_cmd_index,
    .phy_cmd_arg,
    .phy_cmd_resp_type,
    .phy_cmd_data_read,
    .phy_cmd_block_len,
    .phy_cmd_block_count,
    .phy_rsp_data_proceed,
    .phy_rsp_data_cancel,
    .phy_abort_request,
    .phy_rsp_valid,
    .phy_rsp_status,
    .phy_rsp_data,
    .phy_transaction_done,
    .phy_data_valid,
    .phy_data_ready,
    .phy_data,
    .phy_data_last,
    .phy_data_status
  );

  fake_sd_native_phy_model #(
    .DATA_DELAY_CYCLES(4),
    .INIT_BUSY_RESPONSES(2),
    .HIGH_SPEED_SUPPORTED(1'b0),
    .SCR_CMD23_SUPPORTED(1'b0)
  ) card (
    .clk,
    .rst,
    .cmd_valid(phy_cmd_valid),
    .cmd_ready(phy_cmd_ready),
    .cmd_index(phy_cmd_index),
    .cmd_arg(phy_cmd_arg),
    .cmd_resp_type(phy_cmd_resp_type),
    .cmd_data_read(phy_cmd_data_read),
    .cmd_block_len(phy_cmd_block_len),
    .cmd_block_count(phy_cmd_block_count),
    .rsp_data_proceed(phy_rsp_data_proceed),
    .rsp_data_cancel(phy_rsp_data_cancel),
    .abort_request(phy_abort_request),
    .rsp_valid(phy_rsp_valid),
    .rsp_status(phy_rsp_status),
    .rsp_data(phy_rsp_data),
    .transaction_done(phy_transaction_done),
    .data_valid(phy_data_valid),
    .data_ready(phy_data_ready),
    .data(phy_data),
    .data_last(phy_data_last),
    .data_status(phy_data_status),
    .illegal_command_count,
    .last_read_lba,
    .selected,
    .wide_bus
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

  always_ff @(posedge clk) begin
    logic [31:0] expected_lba;
    logic [15:0] expected_offset;
    if (rst) begin
      data_seen <= 0;
    end else if (block_byte_valid && block_byte_ready) begin
      expected_lba = 32'h0000_4567 + 32'(data_seen / 512);
      expected_offset = 16'(data_seen % 512);
      check(block_byte_data == (expected_lba[7:0] ^ expected_lba[15:8]
                                ^ expected_lba[23:16] ^ expected_lba[31:24]
                                ^ expected_offset[7:0] ^ expected_offset[15:8]),
            "fake SD native data mismatch");
      if (data_seen == 1023)
        check(block_byte_last, "fake SD native final byte missing last");
      else
        check(!block_byte_last, "fake SD native early last");
      data_seen <= data_seen + 1;
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    init_start = 1'b0;
    block_req_valid = 1'b0;
    block_req_lba = 32'd0;
    block_req_block_count = 16'd2;
    block_byte_ready = 1'b1;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    init_start = 1'b1;
    @(negedge clk);
    init_start = 1'b0;

    wait (initialized);
    @(posedge clk);
    check(error_code == 8'd0, "fake SD native init error");
    check(!high_speed_active, "default-speed-only card incorrectly enabled high speed");
    check(!busy, "fake SD native reader stayed busy after init");
    check(block_req_ready, "fake SD native reader not ready after init");
    check(selected, "fake SD native card was not selected");
    check(wide_bus, "fake SD native card did not switch to 4-bit mode");
    check(illegal_command_count == 8'd0, "fake SD native model saw illegal commands");

    @(negedge clk);
    block_req_lba = 32'h0000_4567;
    block_req_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_req_valid = 1'b0;

    wait (data_seen == 1024);
    repeat (2) @(posedge clk);
    check(last_read_lba == 32'h0000_4568, "fake SD native final read LBA mismatch");
    check(block_req_ready, "fake SD native reader did not return ready after read");
    check(error_code == 8'd0, "fake SD native read error");
    check(retry_count == 8'd0, "fake SD native reader unexpectedly retried");
    check(recovery_error_code == 4'd0, "fake SD native recovery error was nonzero");
    check(!dut.cmd23_supported, "SCR-disabled CMD23 support was ignored");

    if (errors != 0)
      $fatal(1, "FAIL: sd_native_block_reader_fake errors=%0d", errors);

    $display("PASS: sd_native_block_reader_fake");
    $finish;
  end
endmodule
