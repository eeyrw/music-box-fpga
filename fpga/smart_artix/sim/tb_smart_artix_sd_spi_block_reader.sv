module tb_smart_artix_sd_spi_block_reader;
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
  logic spi_cs_n;
  logic spi_tx_valid;
  logic spi_tx_ready;
  logic [7:0] spi_tx_data;
  logic spi_rx_valid;
  logic [7:0] spi_rx_data;
  int errors;
  int data_seen;

  smart_artix_sd_spi_block_reader #(
    .LBA_WIDTH(LBA_WIDTH),
    .POWER_UP_DUMMY_BYTES(2),
    .R1_TIMEOUT_BYTES(8),
    .INIT_RETRY_LIMIT(4),
    .DATA_TOKEN_TIMEOUT_BYTES(16)
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
    .spi_cs_n,
    .spi_tx_valid,
    .spi_tx_ready,
    .spi_tx_data,
    .spi_rx_valid,
    .spi_rx_data
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

  task automatic spi_accept(input logic [7:0] expected_tx,
                            input logic [7:0] response_rx);
    begin
      wait (spi_tx_valid);
      @(negedge clk);
      check(spi_tx_data == expected_tx, "SPI TX byte mismatch");
      spi_tx_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      spi_tx_ready = 1'b0;
      spi_rx_data = response_rx;
      spi_rx_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      spi_rx_valid = 1'b0;
    end
  endtask

  task automatic spi_dummy(input logic [7:0] response_rx);
    begin
      spi_accept(8'hff, response_rx);
    end
  endtask

  task automatic expect_cmd(input logic [5:0] cmd,
                            input logic [31:0] arg,
                            input logic [7:0] crc,
                            input logic [7:0] r1);
    begin
      check(!spi_cs_n, "SD command sent with CS deasserted");
      spi_accept({2'b01, cmd}, 8'hff);
      spi_accept(arg[31:24], 8'hff);
      spi_accept(arg[23:16], 8'hff);
      spi_accept(arg[15:8], 8'hff);
      spi_accept(arg[7:0], 8'hff);
      spi_accept(crc, 8'hff);
      spi_dummy(r1);
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      data_seen <= 0;
    end else if (block_byte_valid && block_byte_ready) begin
      check(block_byte_data == 8'(data_seen[7:0]), "block data byte mismatch");
      if (data_seen == 511)
        check(block_byte_last, "final block byte did not assert last");
      else
        check(!block_byte_last, "non-final block byte asserted last");
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
    spi_tx_ready = 1'b0;
    spi_rx_valid = 1'b0;
    spi_rx_data = 8'hff;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    init_start = 1'b1;
    @(negedge clk);
    init_start = 1'b0;

    spi_dummy(8'hff);
    spi_dummy(8'hff);
    expect_cmd(6'd0, 32'h0000_0000, 8'h95, 8'h01);
    expect_cmd(6'd8, 32'h0000_01aa, 8'h87, 8'h01);
    spi_dummy(8'h00);
    spi_dummy(8'h00);
    spi_dummy(8'h01);
    spi_dummy(8'haa);
    expect_cmd(6'd55, 32'h0000_0000, 8'hff, 8'h01);
    expect_cmd(6'd41, 32'h4000_0000, 8'hff, 8'h01);
    expect_cmd(6'd55, 32'h0000_0000, 8'hff, 8'h01);
    expect_cmd(6'd41, 32'h4000_0000, 8'hff, 8'h00);
    expect_cmd(6'd58, 32'h0000_0000, 8'hff, 8'h00);
    spi_dummy(8'h40);
    spi_dummy(8'h00);
    spi_dummy(8'h00);
    spi_dummy(8'h00);

    wait (initialized);
    @(posedge clk);
    check(error_code == 8'd0, "SD reader reported error after init");
    check(!busy, "SD reader stayed busy after init");
    check(block_req_ready, "SD reader not ready after init");

    @(negedge clk);
    block_req_lba = 32'h0000_1234;
    block_req_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_req_valid = 1'b0;

    expect_cmd(6'd17, 32'h0000_1234, 8'hff, 8'h00);
    spi_dummy(8'hff);
    spi_dummy(8'hfe);
    for (int i = 0; i < 512; i++)
      spi_dummy(8'(i));
    spi_dummy(8'h12);
    spi_dummy(8'h34);

    repeat (2) @(posedge clk);
    check(data_seen == 512, "SD reader did not emit exactly 512 data bytes");
    check(block_req_ready, "SD reader did not return to ready after block read");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_spi_block_reader errors=%0d", errors);

    $display("PASS: smart_artix_sd_spi_block_reader");
    $finish;
  end
endmodule
