`timescale 1ns/1ps

module tb_ordered_line_cache;
  import synth_pkg::*;

  localparam int TAG_COUNT = 4;
  localparam int TAG_WIDTH = 2;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic client_req_valid;
  logic client_req_ready;
  logic [ADDR_WIDTH-1:0] client_req_addr;
  logic [TAG_WIDTH-1:0] client_req_tag;
  logic client_rsp_valid;
  logic client_rsp_ready;
  logic [ADDR_WIDTH-1:0] client_rsp_addr;
  logic [TAG_WIDTH-1:0] client_rsp_tag;
  ordered_line_rsp_t client_rsp;
  logic memory_req_valid;
  logic memory_req_ready;
  ordered_line_req_t memory_req;
  logic memory_rsp_valid;
  logic memory_rsp_ready;
  ordered_line_rsp_t memory_rsp;
  logic [63:0] stat_client_requests;
  logic [63:0] stat_cache_hits;
  logic [63:0] stat_mshr_merges;
  logic [63:0] stat_memory_misses;
  logic [63:0] stat_evictions;
  logic [63:0] stat_miss_stall_cycles;
  integer memory_request_count;

  always #5 clk = ~clk;

  ordered_line_cache #(
    .CACHE_SET_COUNT(2),
    .MSHR_DEPTH(4),
    .TAG_COUNT(TAG_COUNT),
    .TAG_WIDTH(TAG_WIDTH)
  ) dut (.*);

  always_ff @(posedge clk) begin
    if (rst)
      memory_request_count <= 0;
    else if (memory_req_valid && memory_req_ready)
      memory_request_count <= memory_request_count + 1;
  end

  task automatic request_line(
      input logic [ADDR_WIDTH-1:0] address,
      input logic [TAG_WIDTH-1:0] tag);
    begin
      @(negedge clk);
      client_req_addr = address;
      client_req_tag = tag;
      client_req_valid = 1'b1;
      do @(posedge clk); while (!client_req_ready);
      @(negedge clk);
      client_req_valid = 1'b0;
    end
  endtask

  task automatic return_line(input logic [15:0] base);
    begin
      @(negedge clk);
      for (int word_index = 0; word_index < BLOCK_LINE_WORDS; word_index++)
        memory_rsp.words[word_index] = base + 16'(word_index);
      memory_rsp_valid = 1'b1;
      do @(posedge clk); while (!memory_rsp_ready);
      @(negedge clk);
      memory_rsp_valid = 1'b0;
    end
  endtask

  task automatic expect_response(
      input logic [ADDR_WIDTH-1:0] address,
      input logic [TAG_WIDTH-1:0] tag,
      input logic [15:0] base);
    ordered_line_rsp_t held;
    begin
      do @(posedge clk); while (!client_rsp_valid);
      held = client_rsp;
      @(posedge clk);
      if (!client_rsp_valid || client_rsp != held ||
          client_rsp_addr != address || client_rsp_tag != tag)
        $fatal(1, "cache response changed under backpressure");
      for (int word_index = 0; word_index < BLOCK_LINE_WORDS; word_index++) begin
        if (client_rsp.words[word_index] != base + 16'(word_index))
          $fatal(1, "cache response data mismatch");
      end
      @(negedge clk);
      client_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      client_rsp_ready = 1'b0;
    end
  endtask

  initial begin
    client_req_valid = 1'b0;
    client_req_addr = '0;
    client_req_tag = '0;
    client_rsp_ready = 1'b0;
    memory_req_ready = 1'b1;
    memory_rsp_valid = 1'b0;
    memory_rsp = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    request_line(32'd0, 2'd0);
    request_line(32'd0, 2'd1);
    if (memory_request_count != 1)
      $fatal(1, "same-line misses were not merged");
    return_line(16'h1000);
    expect_response(32'd0, 2'd0, 16'h1000);
    expect_response(32'd0, 2'd1, 16'h1000);

    request_line(32'd0, 2'd2);
    expect_response(32'd0, 2'd2, 16'h1000);
    if (memory_request_count != 1)
      $fatal(1, "cache hit reached external memory");

    request_line(32'd16, 2'd0);
    return_line(16'h2000);
    expect_response(32'd16, 2'd0, 16'h2000);
    request_line(32'd0, 2'd0);
    expect_response(32'd0, 2'd0, 16'h1000);
    request_line(32'd32, 2'd0);
    return_line(16'h3000);
    expect_response(32'd32, 2'd0, 16'h3000);
    request_line(32'd16, 2'd0);
    if (memory_request_count != 4)
      $fatal(1, "two-way conflict did not evict the LRU line");
    return_line(16'h2000);
    expect_response(32'd16, 2'd0, 16'h2000);

    if (stat_client_requests != 7 || stat_cache_hits != 2 ||
        stat_mshr_merges != 1 || stat_memory_misses != 4 ||
        stat_evictions != 2 || stat_miss_stall_cycles != 0)
      $fatal(1, "cache statistics mismatch");

    $display("PASS: ordered line cache merge, hit, LRU, statistics, and backpressure");
    $finish;
  end

  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "ordered line cache test timeout");
  end
endmodule
