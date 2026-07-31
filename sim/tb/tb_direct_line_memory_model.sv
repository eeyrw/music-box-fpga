module tb_direct_line_memory_model;
  logic clk = 1'b0;
  logic rst = 1'b1;
  logic req_valid = 1'b0;
  logic req_ready;
  logic [31:0] req_addr = '0;
  logic rsp_valid;
  logic rsp_ready = 1'b0;
  logic [127:0] rsp_data;
  logic [63:0] stat_accepted;
  logic [63:0] stat_returned;

  /* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
  /* verilator lint_on BLKSEQ */

  direct_line_memory_model dut (
    .clk,
    .rst,
    .req_valid,
    .req_ready,
    .req_addr,
    .rsp_valid,
    .rsp_ready,
    .rsp_data,
    .stat_accepted,
    .stat_returned
  );

  task automatic check_line(input logic [31:0] address,
                            input logic [15:0] expected_base);
    logic [127:0] held_data;
    @(negedge clk);
    req_addr = address;
    while (!req_ready) @(negedge clk);
    req_valid = 1'b1;
    @(negedge clk);
    req_valid = 1'b0;
    while (!rsp_valid) @(negedge clk);
    for (int word = 0; word < 8; word++) begin
      if (rsp_data[word*16 +: 16] !== expected_base + 16'(word))
        $fatal(1, "line %0h word %0d mismatch: got %0h expected %0h",
               address, word, rsp_data[word*16 +: 16],
               expected_base + 16'(word));
    end
    held_data = rsp_data;
    repeat (2) begin
      @(negedge clk);
      if (!rsp_valid || rsp_data !== held_data)
        $fatal(1, "response changed while backpressured");
    end
    rsp_ready = 1'b1;
    @(negedge clk);
    rsp_ready = 1'b0;
    @(negedge clk);
    if (rsp_valid) $fatal(1, "response did not clear after handshake");
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst = 1'b0;
    check_line(32'h0000_0000, 16'h1000);
    check_line(32'h0000_0008, 16'h2000);
    if (stat_accepted != 2 || stat_returned != 2)
      $fatal(1, "counter mismatch: accepted=%0d returned=%0d",
             stat_accepted, stat_returned);
    $display("PASS: direct line memory data, backpressure, and accounting");
    $finish;
  end
endmodule
