module tb_smart_artix_sd_native_block_reader_fake;
  localparam int LBA_WIDTH = 32;

  logic clk;
  logic rst;
  logic init_start;
  logic initialized;
  logic transfer_clock_ready;
  logic busy;
  logic [7:0] error_code;
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
  logic [1:0] phy_cmd_resp_type;
  logic phy_cmd_data_read;
  logic [15:0] phy_cmd_block_len;
  logic [15:0] phy_cmd_block_count;
  logic phy_rsp_valid;
  logic [2:0] phy_rsp_status;
  logic [119:0] phy_rsp_data;
  logic phy_data_valid;
  logic phy_data_ready;
  logic [7:0] phy_data;
  logic phy_data_last;
  logic [2:0] phy_data_status;
  logic [7:0] illegal_command_count;
  logic [31:0] last_read_lba;
  logic selected;
  logic wide_bus;
  int errors;
  int data_seen;

  smart_artix_sd_native_block_reader #(
    .LBA_WIDTH(LBA_WIDTH),
    .INIT_RETRY_LIMIT(8)
  ) dut (
    .clk,
    .rst,
    .init_start,
    .initialized,
    .transfer_clock_ready,
    .busy,
    .error_code,
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
    .phy_rsp_valid,
    .phy_rsp_status,
    .phy_rsp_data,
    .phy_data_valid,
    .phy_data_ready,
    .phy_data,
    .phy_data_last,
    .phy_data_status
  );

  fake_sd_native_phy_model #(
    .DATA_DELAY_CYCLES(4),
    .INIT_BUSY_RESPONSES(2)
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
    .rsp_valid(phy_rsp_valid),
    .rsp_status(phy_rsp_status),
    .rsp_data(phy_rsp_data),
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

  always_ff @(posedge clk) begin
    if (rst) begin
      data_seen <= 0;
    end else if (block_byte_valid && block_byte_ready) begin
      check(block_byte_data == (8'h67 ^ 8'h45 ^ 8'(data_seen[7:0]) ^ 8'(data_seen[15:8])),
            "fake SD native data mismatch");
      if (data_seen == 511)
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
    block_req_block_count = 16'd1;
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
    check(transfer_clock_ready, "fake SD native transfer clock not ready after init");
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

    wait (data_seen == 512);
    repeat (2) @(posedge clk);
    check(last_read_lba == 32'h0000_4567, "fake SD native read LBA mismatch");
    check(block_req_ready, "fake SD native reader did not return ready after read");
    check(error_code == 8'd0, "fake SD native read error");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_native_block_reader_fake errors=%0d", errors);

    $display("PASS: smart_artix_sd_native_block_reader_fake");
    $finish;
  end
endmodule
