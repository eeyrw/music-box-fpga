module tb_parallel_nor_timing_model;
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
  logic [63:0] stat_page_lines;
  logic [63:0] stat_random_lines;
  logic [63:0] stat_transactions;
  logic [63:0] stat_random_access_cycles;
  logic [63:0] stat_page_access_cycles;
  int cycle_count;
  int errors;

  parallel_nor_timing_model #(
    .REQUEST_QUEUE_DEPTH(8),
    .INIT_CYCLES(3),
    .PAGE_WORDS(16),
    .CLOCK_PERIOD_NS(10),
    .RANDOM_ACCESS_NS(100),
    .PAGE_ACCESS_NS(15),
    .DEVICE_WORDS(64),
    .DEVICE_COUNT(1)
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
    .stat_page_lines,
    .stat_random_lines,
    .stat_transactions,
    .stat_random_access_cycles,
    .stat_page_access_cycles
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

    // Two lines fill one 16-word page. The next line starts a new page.
    send_request(32'h0000_0000, accepted_cycle[0]);
    send_request(32'h0000_0008, accepted_cycle[1]);
    send_request(32'h0000_0010, accepted_cycle[2]);
    receive_response(16'h1000, response_cycle[0]);
    receive_response(16'h2000, response_cycle[1]);
    receive_response(16'h3000, response_cycle[2]);

    check(response_cycle[1] - response_cycle[0] == 16,
          "same-page line did not consume exactly 16 clocks");
    check(response_cycle[2] - response_cycle[1] == 24,
          "new-page line did not consume exactly 24 clocks");
    check(stat_transactions == 2 && stat_random_lines == 2 &&
          stat_page_lines == 1,
          "page-mode transaction accounting mismatch");
    check(stat_random_access_cycles == 20 &&
          stat_page_access_cycles == 44,
          "parallel NOR cycle accounting mismatch");

    // Once the queue drains, even the same address requires a fresh access.
    rsp_ready = 1'b0;
    send_request(32'h0000_0010, accepted_cycle[3]);
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
    check(held_data[15:0] == 16'h3000, "idle restart data mismatch");
    check(response_cycle[3] - accepted_cycle[3] >= 24,
          "idle restart omitted random access latency");
    check(stat_transactions == 3 && stat_random_lines == 3 &&
          stat_page_lines == 1,
          "idle restart accounting mismatch");
    check(stat_random_access_cycles == 30 &&
          stat_page_access_cycles == 58,
          "final parallel NOR cycle accounting mismatch");
    check(stat_accepted == 4 && stat_returned == 4,
          "accepted/returned accounting mismatch");

    if (errors != 0)
      $fatal(1, "FAIL: parallel_nor_timing_model errors=%0d", errors);
    $display("PARALLEL_NOR_TIMING transactions=%0d page=%0d random=%0d random_cycles=%0d page_cycles=%0d",
             stat_transactions, stat_page_lines, stat_random_lines,
             stat_random_access_cycles, stat_page_access_cycles);
    $display("PASS: parallel_nor_timing_model");
    $finish;
  end
endmodule
