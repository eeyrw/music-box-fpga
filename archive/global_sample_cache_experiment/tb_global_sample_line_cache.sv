// Archived focused regression for global_sample_line_cache.sv.
`timescale 1ns/1ps

module tb_global_sample_line_cache;
  import synth_pkg::*;

  localparam int TAG_COUNT = 4;
  localparam int TAG_WIDTH = 2;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic client_req_valid;
  logic client_req_ready;
  logic [ADDR_WIDTH-1:0] client_req_addr;
  logic [TAG_WIDTH-1:0] client_req_tag;
  logic [VOICE_ID_WIDTH-1:0] client_req_voice;
  logic client_req_refill;
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
  logic [31:0] stat_client_requests;
  logic [31:0] stat_window_hits;
  logic [31:0] stat_window_refills;
  logic [31:0] stat_fallback_reads;
  logic [31:0] stat_memory_reads;
  logic [31:0] stat_evictions;
  logic [31:0] stat_stall_cycles;

  always #5 clk <= ~clk;

  global_sample_line_cache #(
    .WINDOW_WORDS(32),
    .TAG_COUNT(TAG_COUNT),
    .TAG_WIDTH(TAG_WIDTH),
    .CACHE_WORDS(128)
  ) dut (.*);

  task automatic request_line(
      input logic [ADDR_WIDTH-1:0] address,
      input logic [TAG_WIDTH-1:0] tag,
      input logic [VOICE_ID_WIDTH-1:0] voice,
      input logic refill);
    begin
      @(negedge clk);
      client_req_addr = address;
      client_req_tag = tag;
      client_req_voice = voice;
      client_req_refill = refill;
      client_req_valid = 1'b1;
      do @(posedge clk); while (!client_req_ready);
      @(negedge clk);
      client_req_valid = 1'b0;
    end
  endtask

  task automatic fill_lines(
      input logic [ADDR_WIDTH-1:0] first_line,
      input int line_count,
      input logic [15:0] data_base);
    begin
      for (int line = 0; line < line_count; line++) begin
        while (!memory_req_valid) @(negedge clk);
        if (memory_req.aligned_line_addr !=
            first_line + ADDR_WIDTH'(line * BLOCK_LINE_WORDS))
          $fatal(1, "global cache memory request address mismatch got=%0d line=%0d",
                 memory_req.aligned_line_addr, line);
        @(posedge clk);
        @(negedge clk);
      end

      for (int line = 0; line < line_count; line++) begin
        for (int word = 0; word < BLOCK_LINE_WORDS; word++)
          memory_rsp.words[word] = data_base + 16'(line * 16) +
                                   16'(word);
        memory_rsp_valid = 1'b1;
        do @(posedge clk); while (!memory_rsp_ready);
        @(negedge clk);
        memory_rsp_valid = 1'b0;
      end
    end
  endtask

  task automatic expect_response(
      input logic [ADDR_WIDTH-1:0] address,
      input logic [TAG_WIDTH-1:0] tag,
      input logic [15:0] data_base);
    ordered_line_rsp_t held;
    begin
      do @(posedge clk); while (!client_rsp_valid);
      held = client_rsp;
      @(posedge clk);
      if (!client_rsp_valid || client_rsp != held ||
          client_rsp_addr != address || client_rsp_tag != tag)
        $fatal(1, "global cache response changed under backpressure");
      for (int word = 0; word < BLOCK_LINE_WORDS; word++) begin
        if (client_rsp.words[word] != data_base + 16'(word))
          $fatal(1, "global cache response data mismatch word=%0d", word);
      end
      @(negedge clk);
      client_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      client_rsp_ready = 1'b0;
    end
  endtask

  task automatic miss_and_fill(
      input logic [ADDR_WIDTH-1:0] address,
      input logic [TAG_WIDTH-1:0] tag,
      input logic [VOICE_ID_WIDTH-1:0] voice,
      input logic refill,
      input logic [15:0] data_base);
    logic [ADDR_WIDTH-1:0] macro_base;
    logic [ADDR_WIDTH-1:0] first_line;
    logic [15:0] critical_base;
    int line_count;
    begin
      macro_base = {address[ADDR_WIDTH-1:5], 5'b0};
      if (refill) begin
        first_line = macro_base;
        line_count = 4;
        critical_base = data_base + 16'(address[4:3] * 16);
      end else begin
        first_line = {address[ADDR_WIDTH-1:3], 3'b0};
        line_count = 1;
        critical_base = data_base;
      end
      request_line(address, tag, voice, refill);
      fill_lines(first_line, line_count, data_base);
      expect_response(address, tag, critical_base);
    end
  endtask

  task automatic hit_and_expect(
      input logic [ADDR_WIDTH-1:0] address,
      input logic [TAG_WIDTH-1:0] tag,
      input logic [VOICE_ID_WIDTH-1:0] voice,
      input logic refill,
      input logic [15:0] data_base);
    begin
      request_line(address, tag, voice, refill);
      if (memory_req_valid)
        $fatal(1, "global cache hit issued an external read");
      expect_response(address, tag, data_base);
    end
  endtask

  initial begin
    client_req_valid = 1'b0;
    client_req_addr = '0;
    client_req_tag = '0;
    client_req_voice = '0;
    client_req_refill = 1'b0;
    client_rsp_ready = 1'b0;
    memory_req_ready = 1'b1;
    memory_rsp_valid = 1'b0;
    memory_rsp = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // A nonzero critical subline still causes one aligned four-line fill.
    miss_and_fill(32'd8, 2'd0, VOICE_ID_WIDTH'(0), 1'b1, 16'h1000);

    // A different voice shares another subline of the same physical macro-line.
    hit_and_expect(32'd24, 2'd1, VOICE_ID_WIDTH'(NUM_VOICES - 1),
                   1'b0, 16'h1030);

    // Fallback misses allocate only their requested sectors. A second-sector
    // miss reuses the same macro tag without evicting the first sector.
    miss_and_fill(32'd72, 2'd2, VOICE_ID_WIDTH'(1), 1'b0, 16'h2000);
    miss_and_fill(32'd88, 2'd3, VOICE_ID_WIDTH'(2), 1'b0, 16'h2100);
    hit_and_expect(32'd72, 2'd0, VOICE_ID_WIDTH'(3), 1'b0, 16'h2000);

    // Macro-lines at 0, 64, and 128 map to the same set in this tiny cache.
    // The recent macro-line-64 hit makes macro-line 0 the LRU victim.
    miss_and_fill(32'd128, 2'd1, VOICE_ID_WIDTH'(4), 1'b1, 16'h3000);
    hit_and_expect(32'd88, 2'd2, VOICE_ID_WIDTH'(5), 1'b0, 16'h2100);

    if (stat_client_requests != 7 || stat_window_hits != 3 ||
        stat_window_refills != 2 || stat_fallback_reads != 2 ||
        stat_memory_reads != 10 || stat_evictions != 1 ||
        stat_stall_cycles != 0)
      $fatal(1, "global sample line cache statistics mismatch");

    $display("PASS: adaptive global macro-line sectors, sharing, LRU, and backpressure");
    $finish;
  end

  initial begin
    repeat (3000) @(posedge clk);
    $fatal(1, "global sample line cache test timeout");
  end
endmodule
