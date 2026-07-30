module tb_ddr3_timing_model;
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
  logic [63:0] stat_row_hits;
  logic [63:0] stat_row_misses;
  logic [63:0] stat_activates;
  logic [63:0] stat_precharges;
  logic [63:0] stat_refreshes;
  int cycle_count;
  int errors;

  ddr3_timing_model #(
    .BANK_COUNT(8),
    .ROW_BITS(2),
    .COLUMN_BITS(1),
    .BANK_ROW_COLUMN(1'b1),
    .REQUEST_QUEUE_DEPTH(8),
    .INIT_CYCLES(3),
    .T_RCD(20),
    .T_RP(2),
    .T_CL(3),
    .T_RAS(3),
    .T_RC(5),
    .T_CCD(1),
    .T_RTP(1),
    .T_RRD(2),
    .T_FAW(9),
    .T_RFC(4),
    .T_REFI(120)
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
    .stat_row_hits,
    .stat_row_misses,
    .stat_activates,
    .stat_precharges,
    .stat_refreshes
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

  task automatic transact(input logic [31:0] address,
                           input logic [15:0] expected_word0,
                           output int latency);
    int accepted_cycle;
    int response_cycle;
    send_request(address, accepted_cycle);
    receive_response(expected_word0, response_cycle);
    latency = response_cycle - accepted_cycle;
  endtask

  initial begin
    int cold_latency;
    int hit_latency;
    int conflict_latency;
    int accepted_cycle;
    int response_cycle;
    logic [LINE_WORDS*16-1:0] held_data;
    logic [63:0] refresh_count_before;
    int activate_cycle [0:4];
    int captured_activates;
    logic [63:0] observed_activates;

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

    // Five cold requests target bank 0..4 at the same row under the MIG
    // BANK_ROW_COLUMN layout. A long tRCD keeps reads from obscuring the
    // rank-level ACT command constraints under test.
    captured_activates = 0;
    observed_activates = 0;
    fork
      begin
        for (int bank = 0; bank < 5; bank++)
          send_request(32'(bank * 64), accepted_cycle);
      end
      begin
        while (captured_activates < 5) begin
          @(negedge clk);
          if (stat_activates != observed_activates) begin
            check(stat_activates == observed_activates + 1'b1,
                  "more than one ACT issued in one DDR clock");
            activate_cycle[captured_activates] = cycle_count;
            captured_activates++;
            observed_activates = stat_activates;
          end
        end
      end
    join
    for (int request = 0; request < 5; request++)
      receive_response(request == 0 ? 16'h1000 : 16'h0000, response_cycle);
    for (int activate = 1; activate < 5; activate++)
      check((activate_cycle[activate] - activate_cycle[activate - 1]) >= 2,
            "rank ACT commands violated tRRD");
    check((activate_cycle[4] - activate_cycle[0]) >= 9,
          "fifth rank ACT command violated tFAW");

    rst = 1'b1;
    repeat (2) @(posedge clk);
    rst = 1'b0;

    transact(32'h0000_0000, 16'h1000, cold_latency);
    transact(32'h0000_0008, 16'h2000, hit_latency);
    transact(32'h0000_0020, 16'h4000, conflict_latency);
    check(cold_latency == 30 && hit_latency == 10 && conflict_latency == 32,
          $sformatf("exact DDR burst latency mismatch: cold=%0d hit=%0d conflict=%0d",
                    cold_latency, hit_latency, conflict_latency));
    check(hit_latency < cold_latency,
          $sformatf("row hit was not faster: cold=%0d hit=%0d",
                    cold_latency, hit_latency));
    check(conflict_latency > hit_latency,
          $sformatf("row conflict was not slower: conflict=%0d hit=%0d",
                    conflict_latency, hit_latency));
    check(stat_row_hits >= 1, "row-hit statistic did not increment");
    check(stat_row_misses >= 2, "row-miss statistic did not count cold/conflict reads");
    check(stat_activates >= 2, "activate statistic did not count cold/conflict reads");
    check(stat_precharges >= 1, "row conflict did not issue precharge");

    rsp_ready = 1'b0;
    send_request(32'h0000_0010, accepted_cycle);
    @(negedge clk);
    while (!rsp_valid) @(negedge clk);
    response_cycle = cycle_count;
    held_data = rsp_data;
    repeat (3) begin
      @(negedge clk);
      check(rsp_valid, "response valid dropped under backpressure");
      check(rsp_data == held_data, "response payload changed under backpressure");
    end
    rsp_ready = 1'b1;
    @(posedge clk);
    check(held_data[15:0] == 16'h3000,
          $sformatf("backpressured response data mismatch: got=%04x",
                    held_data[15:0]));
    check(response_cycle > accepted_cycle, "response had zero modeled latency");

    refresh_count_before = stat_refreshes;
    while (stat_refreshes == refresh_count_before) @(negedge clk);
    check(dut.next_refresh_cycle_q == 64'd243,
          "delayed refresh shifted the fixed tREFI schedule");
    check(!req_ready, "request ready stayed high during refresh recovery");
    while (!req_ready) @(negedge clk);
    transact(32'h0000_0000, 16'h1000, cold_latency);

    check(stat_accepted == 5, "accepted-request count mismatch");
    check(stat_returned == 5, "returned-response count mismatch");
    check(stat_refreshes >= 1, "refresh statistic did not increment");

    if (errors != 0)
      $fatal(1, "FAIL: ddr3_timing_model errors=%0d", errors);
    $display("DDR3_TIMING cold=%0d hit=%0d conflict=%0d refreshes=%0d",
             cold_latency, hit_latency, conflict_latency, stat_refreshes);
    $display("PASS: ddr3_timing_model");
    $finish;
  end
endmodule
