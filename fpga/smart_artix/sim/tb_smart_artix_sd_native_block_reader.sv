module tb_smart_artix_sd_native_block_reader;
  localparam int LBA_WIDTH = 32;

  logic clk;
  logic rst;
  logic init_start;
  logic initialized;
  logic busy;
  logic [7:0] error_code;
  logic block_req_valid;
  logic block_req_ready;
  logic [LBA_WIDTH-1:0] block_req_lba;
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
  int errors;
  int data_seen;

  smart_artix_sd_native_block_reader #(
    .LBA_WIDTH(LBA_WIDTH),
    .INIT_RETRY_LIMIT(4)
  ) dut (
    .clk,
    .rst,
    .init_start,
    .initialized,
    .busy,
    .error_code,
    .block_req_valid,
    .block_req_ready,
    .block_req_lba,
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

  task automatic accept_cmd(input logic [5:0] expected_index,
                            input logic [31:0] expected_arg,
                            input logic [1:0] expected_resp,
                            input logic expected_data_read);
    begin
      wait (phy_cmd_valid);
      @(negedge clk);
      check(phy_cmd_index == expected_index, "native SD command index mismatch");
      check(phy_cmd_arg == expected_arg, "native SD command argument mismatch");
      check(phy_cmd_resp_type == expected_resp, "native SD response type mismatch");
      check(phy_cmd_data_read == expected_data_read, "native SD data_read mismatch");
      if (expected_data_read) begin
        check(phy_cmd_block_len == 16'd512, "native SD block length mismatch");
        check(phy_cmd_block_count == 16'd1, "native SD block count mismatch");
      end
      phy_cmd_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      phy_cmd_ready = 1'b0;
    end
  endtask

  task automatic send_rsp(input logic [119:0] data);
    begin
      @(negedge clk);
      phy_rsp_data = data;
      phy_rsp_status = 3'd0;
      phy_rsp_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      phy_rsp_valid = 1'b0;
    end
  endtask

  task automatic accept_cmd_rsp(input logic [5:0] expected_index,
                                input logic [31:0] expected_arg,
                                input logic [1:0] expected_resp,
                                input logic expected_data_read,
                                input logic [119:0] rsp_data);
    begin
      accept_cmd(expected_index, expected_arg, expected_resp, expected_data_read);
      if (expected_resp != 2'd0)
        send_rsp(rsp_data);
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      data_seen <= 0;
    end else if (block_byte_valid && block_byte_ready) begin
      check(block_byte_data == 8'(data_seen[7:0]), "native SD data byte mismatch");
      if (data_seen == 511)
        check(block_byte_last, "native SD final byte missing last");
      else
        check(!block_byte_last, "native SD early last");
      data_seen <= data_seen + 1;
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    init_start = 1'b0;
    block_req_valid = 1'b0;
    block_req_lba = 32'd0;
    block_byte_ready = 1'b1;
    phy_cmd_ready = 1'b0;
    phy_rsp_valid = 1'b0;
    phy_rsp_status = 3'd0;
    phy_rsp_data = '0;
    phy_data_valid = 1'b0;
    phy_data = 8'd0;
    phy_data_last = 1'b0;
    phy_data_status = 3'd0;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    init_start = 1'b1;
    @(negedge clk);
    init_start = 1'b0;

    accept_cmd_rsp(6'd0, 32'h0000_0000, 2'd0, 1'b0, '0);
    accept_cmd_rsp(6'd8, 32'h0000_01aa, 2'd1, 1'b0, 120'h0000_01aa);
    accept_cmd_rsp(6'd55, 32'h0000_0000, 2'd1, 1'b0, 120'h0);
    accept_cmd_rsp(6'd41, 32'h4030_0000, 2'd1, 1'b0, 120'h0000_0000);
    accept_cmd_rsp(6'd55, 32'h0000_0000, 2'd1, 1'b0, 120'h0);
    accept_cmd_rsp(6'd41, 32'h4030_0000, 2'd1, 1'b0, 120'hc000_0000);
    accept_cmd_rsp(6'd2, 32'h0000_0000, 2'd2, 1'b0, 120'h0);
    accept_cmd_rsp(6'd3, 32'h0000_0000, 2'd1, 1'b0, 120'h1234_0000);
    accept_cmd_rsp(6'd7, 32'h1234_0000, 2'd1, 1'b0, 120'h0);
    accept_cmd_rsp(6'd55, 32'h1234_0000, 2'd1, 1'b0, 120'h0);
    accept_cmd_rsp(6'd6, 32'h0000_0002, 2'd1, 1'b0, 120'h0);

    wait (initialized);
    @(posedge clk);
    check(error_code == 8'd0, "native SD init error");
    check(!busy, "native SD reader stayed busy after init");
    check(block_req_ready, "native SD reader not ready after init");

    @(negedge clk);
    block_req_lba = 32'h0000_4567;
    block_req_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_req_valid = 1'b0;

    accept_cmd_rsp(6'd17, 32'h0000_4567, 2'd1, 1'b1, 120'h0);
    for (int i = 0; i < 512; i++) begin
      @(negedge clk);
      phy_data = 8'(i);
      phy_data_last = i == 511;
      phy_data_valid = 1'b1;
      wait (phy_data_ready);
      @(posedge clk);
      @(negedge clk);
      phy_data_valid = 1'b0;
      phy_data_last = 1'b0;
    end

    repeat (2) @(posedge clk);
    check(data_seen == 512, "native SD reader did not emit exactly 512 bytes");
    check(block_req_ready, "native SD reader did not return ready after read");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_native_block_reader errors=%0d", errors);

    $display("PASS: smart_artix_sd_native_block_reader");
    $finish;
  end
endmodule
