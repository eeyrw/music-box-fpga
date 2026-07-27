module tb_sd_native_block_reader;
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
  int errors;
  int output_count;
  int abort_count;

  sd_native_block_reader #(
    .LBA_WIDTH(LBA_WIDTH),
    .CLK_HZ(1_000),
    .INIT_TIMEOUT_MS(1_000),
    .READ_RETRY_LIMIT(2)
  ) dut (.*);

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask
/* verilator lint_on BLKSEQ */

  task automatic accept_cmd(
      input logic [5:0] expected_index,
      input logic [31:0] expected_arg,
      input sd_response_type_t expected_resp,
      input logic expected_data_read);
    begin
      wait (phy_cmd_valid);
      @(negedge clk);
      check(phy_cmd_index == expected_index, "command index mismatch");
      check(phy_cmd_arg == expected_arg, "command argument mismatch");
      check(phy_cmd_resp_type == expected_resp, "response type mismatch");
      check(phy_cmd_data_read == expected_data_read, "data-read flag mismatch");
      phy_cmd_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      phy_cmd_ready = 1'b0;
    end
  endtask

  task automatic send_rsp(
      input sd_transport_status_t status,
      input logic [31:0] response_data);
    begin
      @(negedge clk);
      phy_rsp_status = status;
      phy_rsp_data = {88'd0, response_data};
      phy_rsp_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      phy_rsp_valid = 1'b0;
    end
  endtask

  task automatic command_rsp(
      input logic [5:0] index,
      input logic [31:0] arg,
      input sd_response_type_t response_type,
      input logic [31:0] response_data);
    begin
      accept_cmd(index, arg, response_type, 1'b0);
      if (response_type != SD_RESP_NONE)
        send_rsp(SD_STATUS_OK, response_data);
    end
  endtask

  task automatic pulse_transaction_done;
    begin
      @(negedge clk);
      phy_transaction_done = 1'b1;
      @(posedge clk);
      @(negedge clk);
      phy_transaction_done = 1'b0;
    end
  endtask

  task automatic send_data_byte(
      input logic [7:0] value,
      input logic last,
      input sd_transport_status_t status);
    begin
      @(negedge clk);
      phy_data = value;
      phy_data_last = last;
      phy_data_status = status;
      phy_data_valid = 1'b1;
      wait (phy_data_ready);
      @(posedge clk);
      @(negedge clk);
      phy_data_valid = 1'b0;
      phy_data_last = 1'b0;
      phy_data_status = SD_STATUS_OK;
    end
  endtask

  task automatic send_cmd6_status(
      input logic support_high_speed,
      input logic busy_high_speed,
      input logic [3:0] selection);
    logic [7:0] value;
    begin
      wait (phy_rsp_data_proceed);
      for (int i = 0; i < 64; i++) begin
        value = 8'h00;
        if (i == 13 && support_high_speed)
          value = 8'h02;
        if (i == 15 && busy_high_speed)
          value = 8'h02;
        if (i == 16)
          value = {4'h0, selection};
        send_data_byte(value, i == 63, SD_STATUS_OK);
      end
      pulse_transaction_done();
    end
  endtask

  task automatic send_scr(input logic cmd23_support);
    logic [7:0] value;
    begin
      wait (phy_rsp_data_proceed);
      for (int i = 0; i < 8; i++) begin
        value = i == 3 && cmd23_support ? 8'h02 : 8'h00;
        send_data_byte(value, i == 7, SD_STATUS_OK);
      end
      pulse_transaction_done();
    end
  endtask

  task automatic initialize_high_speed;
    begin
      command_rsp(6'd0, 32'h0, SD_RESP_NONE, 32'h0);
      command_rsp(6'd8, 32'h0000_01aa, SD_RESP_R7, 32'h0000_01aa);
      command_rsp(6'd55, 32'h0, SD_RESP_R1, 32'h0000_0020);
      command_rsp(6'd41, 32'h4030_0000, SD_RESP_R3, 32'h0000_0000);
      command_rsp(6'd55, 32'h0, SD_RESP_R1, 32'h0000_0020);
      command_rsp(6'd41, 32'h4030_0000, SD_RESP_R3, 32'hc000_0000);
      command_rsp(6'd2, 32'h0, SD_RESP_R2, 32'h0);
      command_rsp(6'd3, 32'h0, SD_RESP_R6, 32'h1234_0700);
      command_rsp(6'd7, 32'h1234_0000, SD_RESP_R1B, 32'h0000_0700);
      command_rsp(6'd55, 32'h1234_0000, SD_RESP_R1, 32'h0000_0920);
      command_rsp(6'd42, 32'h0, SD_RESP_R1, 32'h0000_0900);
      command_rsp(6'd55, 32'h1234_0000, SD_RESP_R1, 32'h0000_0920);
      command_rsp(6'd6, 32'h2, SD_RESP_R1, 32'h0000_0900);
      command_rsp(6'd55, 32'h1234_0000, SD_RESP_R1, 32'h0000_0920);
      accept_cmd(6'd51, 32'h0, SD_RESP_R1, 1'b1);
      check(phy_cmd_block_len == 16'd8, "ACMD51 block length mismatch");
      send_rsp(SD_STATUS_OK, 32'h0000_0900);
      send_scr(1'b1);

      accept_cmd(6'd6, 32'h00ff_fff1, SD_RESP_R1, 1'b1);
      check(phy_cmd_block_len == 16'd64, "CMD6 query block length mismatch");
      send_rsp(SD_STATUS_OK, 32'h0000_0900);
      send_cmd6_status(1'b1, 1'b0, 4'h0);

      accept_cmd(6'd6, 32'h80ff_fff1, SD_RESP_R1, 1'b1);
      send_rsp(SD_STATUS_OK, 32'h0000_0900);
      send_cmd6_status(1'b1, 1'b0, 4'h1);
      wait (initialized);
      check(high_speed_active, "high-speed selection was not activated");
    end
  endtask

  task automatic issue_read_response(input logic [31:0] lba);
    begin
      accept_cmd(6'd17, lba, SD_RESP_R1, 1'b1);
      check(phy_cmd_block_count == 16'd1, "CMD17 was not a single-block transaction");
      send_rsp(SD_STATUS_OK, 32'h0000_0900);
      wait (phy_rsp_data_proceed);
    end
  endtask

  task automatic issue_multi_read_response(
      input logic [31:0] lba, input logic [15:0] count);
    begin
      accept_cmd(6'd18, lba, SD_RESP_R1, 1'b1);
      check(phy_cmd_block_count == count, "CMD18 descriptor block count mismatch");
      send_rsp(SD_STATUS_OK, 32'h0000_0900);
      wait (phy_rsp_data_proceed);
    end
  endtask

  task automatic finish_stop(input logic [31:0] response_data);
    begin
      accept_cmd(6'd12, 32'h0, SD_RESP_R1B, 1'b0);
      send_rsp(SD_STATUS_OK, response_data);
      pulse_transaction_done();
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      output_count <= 0;
      abort_count <= 0;
    end else if (block_byte_valid && block_byte_ready) begin
      check(block_byte_data == 8'(output_count), "clean block output data mismatch");
      check(block_byte_last == (output_count == 1535 || output_count == 2559),
            "block stream last mismatch");
      output_count <= output_count + 1;
    end else if (phy_abort_request) begin
      abort_count <= abort_count + 1;
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    init_start = 1'b0;
    block_req_valid = 1'b0;
    block_req_lba = '0;
    block_req_block_count = '0;
    block_byte_ready = 1'b1;
    phy_cmd_ready = 1'b0;
    phy_rsp_valid = 1'b0;
    phy_rsp_status = SD_STATUS_OK;
    phy_rsp_data = '0;
    phy_transaction_done = 1'b0;
    phy_data_valid = 1'b0;
    phy_data = '0;
    phy_data_last = 1'b0;
    phy_data_status = SD_STATUS_OK;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    init_start = 1'b1;
    @(negedge clk);
    init_start = 1'b0;
    initialize_high_speed();
    check(error_code == 0, "initialization reported an error");

    @(negedge clk);
    block_req_lba = 32'h0000_4567;
    block_req_block_count = 16'd3;
    block_req_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_req_valid = 1'b0;

    command_rsp(6'd23, 32'd3, SD_RESP_R1, 32'h0000_0900);
    issue_multi_read_response(32'h0000_4567, 16'd3);
    for (int i = 0; i < 512; i++)
      send_data_byte(8'(i), i == 511, SD_STATUS_OK);
    wait (output_count == 512);
    for (int i = 0; i < 512; i++)
      send_data_byte(8'(i + 512), i == 511,
                     i == 511 ? SD_STATUS_CRC_ERROR : SD_STATUS_OK);
    pulse_transaction_done();
    finish_stop(32'h0000_0900);

    issue_read_response(32'h0000_4568);
    for (int i = 0; i < 512; i++)
      send_data_byte(8'(i + 512), i == 511, SD_STATUS_OK);
    pulse_transaction_done();

    issue_read_response(32'h0000_4569);
    for (int i = 0; i < 512; i++)
      send_data_byte(8'(i + 1024), i == 511, SD_STATUS_OK);
    pulse_transaction_done();

    wait (block_req_ready);
    check(output_count == 1536, "CMD18 recovery stream length mismatch");
    check(abort_count == 1, "CMD18 error did not request exactly one PHY abort");

    @(negedge clk);
    block_req_lba = 32'h0000_5000;
    block_req_block_count = 16'd2;
    block_req_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_req_valid = 1'b0;

    command_rsp(6'd23, 32'd2, SD_RESP_R1, 32'h0040_0900);
    issue_multi_read_response(32'h0000_5000, 16'd2);
    for (int i = 0; i < 512; i++)
      send_data_byte(8'(i + 1536), i == 511, SD_STATUS_OK);
    wait (output_count == 2048);
    for (int i = 0; i < 512; i++)
      send_data_byte(8'(i + 2048), i == 511, SD_STATUS_OK);
    pulse_transaction_done();
    finish_stop(32'h0000_0900);

    wait (block_req_ready);
    repeat (3) @(posedge clk);
    check(output_count == 2560, "reader did not emit all recovered multi-block data");
    check(retry_count == 1, "read retry counter mismatch");
    check(error_code == 0, "read retry left an error");
    check(recovery_error_code == 0, "successful recovery left a recovery error");
    check(!phy_rsp_data_cancel, "successful final request was cancelled");

    @(negedge clk);
    block_req_lba = 32'h0000_6000;
    block_req_block_count = 16'd2;
    block_req_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_req_valid = 1'b0;

    issue_multi_read_response(32'h0000_6000, 16'd2);
    for (int i = 0; i < 512; i++)
      send_data_byte(8'hcc, i == 511,
                     i == 511 ? SD_STATUS_CRC_ERROR : SD_STATUS_OK);
    pulse_transaction_done();
    accept_cmd(6'd12, 32'h0, SD_RESP_R1B, 1'b0);
    send_rsp(SD_STATUS_BUSY_TIMEOUT, 32'h0000_0900);
    repeat (2) @(posedge clk);
    check(error_code == 8'd9, "CMD12 failure did not preserve the data error");
    check(recovery_error_code == 4'd2, "CMD12 busy failure was not reported separately");
    check(!initialized, "reader stayed initialized after failed CMD18 recovery");
    check(output_count == 2560, "failed recovery leaked a partial block");

    if (errors != 0)
      $fatal(1, "FAIL: sd_native_block_reader errors=%0d", errors);
    $display("PASS: sd_native_block_reader");
    $finish;
  end

  initial begin
    repeat (100000) @(posedge clk);
    $fatal(1, "FAIL: sd_native_block_reader timeout state=%0d op=%0d output=%0d",
           dut.state, dut.op, output_count);
  end
endmodule
