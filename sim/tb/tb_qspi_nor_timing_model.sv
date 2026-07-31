module tb_qspi_nor_timing_model;
  localparam int LINE_WORDS = 8;

  logic clk;
  logic rst;
  logic req_valid;
  logic req_ready;
  logic [31:0] req_addr;
  logic rsp_valid;
  logic rsp_ready;
  logic [LINE_WORDS*16-1:0] rsp_data;
  logic [63:0] stat_accepted;
  logic [63:0] stat_returned;
  logic [63:0] stat_sequential_lines;
  logic [63:0] stat_random_lines;
  logic [63:0] stat_transactions;
  logic [63:0] stat_overhead_cycles;
  logic [63:0] stat_data_cycles;
  int cycle_count;
  int errors;

  qspi_nor_timing_model #(
    .REQUEST_QUEUE_DEPTH(8),
    .INIT_CYCLES(3),
    .COMMAND_BITS(8),
    .COMMAND_LANES(1),
    .ADDRESS_BITS(32),
    .ADDRESS_LANES(4),
    .MODE_BITS(8),
    .MODE_LANES(4),
    .DUMMY_CYCLES(8),
    .DATA_LANES(4),
    .CS_HIGH_CYCLES(1),
    .CONTINUOUS_READ(1'b1)
  ) dut (
    .clk,
    .rst,
    .req_valid,
    .req_ready,
    .req_addr,
    .rsp_valid,
    .rsp_ready,
    .rsp_data,
    .stat_accepted,
    .stat_returned,
    .stat_sequential_lines,
    .stat_random_lines,
    .stat_transactions,
    .stat_overhead_cycles,
    .stat_data_cycles
  );

/* verilator lint_off BLKSEQ */
  always #5 clk <= ~clk;
  always @(posedge clk) cycle_count = cycle_count + 1;
/* verilator lint_on BLKSEQ */

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask

  task automatic send_request(input logic [31:0] address,
                              output int accepted_cycle);
    @(negedge clk);
    while (!req_ready) @(negedge clk);
    req_addr = address;
    req_valid = 1'b1;
    @(posedge clk);
    accepted_cycle = cycle_count;
    @(negedge clk);
    req_valid = 1'b0;
  endtask

  task automatic receive_response(input logic [15:0] expected_word0,
                                  output int response_cycle);
    @(negedge clk);
    while (!rsp_valid) @(negedge clk);
    response_cycle = cycle_count;
    check(rsp_data[15:0] == expected_word0,
          $sformatf("response word0 mismatch: got=%04x expected=%04x",
                    rsp_data[15:0], expected_word0));
    @(posedge clk);
    @(negedge clk);
  endtask

  initial begin
    int accepted_cycle [0:3];
    int response_cycle [0:3];
    logic [LINE_WORDS*16-1:0] held_data;

    clk = 1'b0;
    rst = 1'b1;
    req_valid = 1'b0;
    req_addr = '0;
    rsp_ready = 1'b1;
    cycle_count = 0;
    errors = 0;

    repeat (2) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    check(!req_ready, "model accepted a request before initialization");

    // The first three requests can remain under one CS-low continuous read.
    send_request(32'h0000_0000, accepted_cycle[0]);
    send_request(32'h0000_0008, accepted_cycle[1]);
    send_request(32'h0000_0010, accepted_cycle[2]);
    receive_response(16'h1000, response_cycle[0]);
    receive_response(16'h2000, response_cycle[1]);
    receive_response(16'h3000, response_cycle[2]);

    check(response_cycle[1] - response_cycle[0] == 32,
          "sequential line did not consume exactly 32 quad data clocks");
    check(response_cycle[2] - response_cycle[1] == 32,
          "second sequential line did not consume exactly 32 quad data clocks");
    check(stat_transactions == 1 && stat_random_lines == 1 &&
          stat_sequential_lines == 2,
          "continuous-read transaction accounting mismatch");
    check(stat_overhead_cycles == 27 && stat_data_cycles == 96,
          "QSPI protocol-cycle accounting mismatch");

    // A non-contiguous line must pay command/address/mode/dummy overhead again.
    rsp_ready = 1'b0;
    send_request(32'h0000_0020, accepted_cycle[3]);
    @(negedge clk);
    while (!rsp_valid) @(negedge clk);
    response_cycle[3] = cycle_count;
    held_data = rsp_data;
    repeat (3) begin
      @(negedge clk);
      check(rsp_valid, "response valid dropped under backpressure");
      check(rsp_data == held_data, "response payload changed under backpressure");
    end
    rsp_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    check(held_data[15:0] == 16'h4000,
          "random response data mismatch");
    check(response_cycle[3] - accepted_cycle[3] >= 59,
          "random read omitted QSPI transaction overhead");
    check(stat_transactions == 2 && stat_random_lines == 2 &&
          stat_sequential_lines == 2,
          "random-read transaction accounting mismatch");
    check(stat_overhead_cycles == 54 && stat_data_cycles == 128,
          "final QSPI protocol-cycle accounting mismatch");
    check(stat_accepted == 4 && stat_returned == 4,
          "accepted/returned accounting mismatch");

    if (errors != 0)
      $fatal(1, "FAIL: qspi_nor_timing_model errors=%0d", errors);
    $display("QSPI_NOR_TIMING transactions=%0d sequential=%0d random=%0d overhead=%0d data=%0d",
             stat_transactions, stat_sequential_lines, stat_random_lines,
             stat_overhead_cycles, stat_data_cycles);
    $display("PASS: qspi_nor_timing_model");
    $finish;
  end
endmodule
