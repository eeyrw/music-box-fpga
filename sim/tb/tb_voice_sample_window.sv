`timescale 1ns/1ps

module tb_voice_sample_window;
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
  logic [63:0] stat_client_requests;
  logic [63:0] stat_window_hits;
  logic [63:0] stat_window_refills;
  logic [63:0] stat_fallback_reads;
  logic [63:0] stat_memory_reads;
  logic [63:0] stat_evictions;
  logic [63:0] stat_stall_cycles;

  always #5 clk = ~clk;

  voice_sample_window #(
    .WINDOW_WORDS(32),
    .TAG_COUNT(TAG_COUNT),
    .TAG_WIDTH(TAG_WIDTH)
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

  task automatic return_transaction(
      input logic [ADDR_WIDTH-1:0] address,
      input int line_count,
      input logic [15:0] data_base);
    begin
      for (int line = 0; line < line_count; line++) begin
        while (!memory_req_valid) @(negedge clk);
        if (memory_req.aligned_line_addr !=
            address + ADDR_WIDTH'(line * BLOCK_LINE_WORDS))
          $fatal(1, "window memory request address mismatch got=%0d expected=%0d",
                 memory_req.aligned_line_addr,
                 address + ADDR_WIDTH'(line * BLOCK_LINE_WORDS));
        @(posedge clk);
        @(negedge clk);
        memory_req_ready = 1'b0;
        for (int word = 0; word < BLOCK_LINE_WORDS; word++)
          memory_rsp.words[word] = data_base + 16'(line * 16'h0100 + word);
        memory_rsp_valid = 1'b1;
        do @(posedge clk); while (!memory_rsp_ready);
        @(negedge clk);
        memory_rsp_valid = 1'b0;
        memory_req_ready = 1'b1;
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
        $fatal(1, "window response changed under backpressure");
      for (int word = 0; word < BLOCK_LINE_WORDS; word++) begin
        if (client_rsp.words[word] != data_base + 16'(word))
          $fatal(1, "window response data mismatch");
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
    client_req_voice = '0;
    client_req_refill = 1'b0;
    client_rsp_ready = 1'b0;
    memory_req_ready = 1'b1;
    memory_rsp_valid = 1'b0;
    memory_rsp = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    request_line(32'd0, 2'd0, VOICE_ID_WIDTH'(0), 1'b1);
    return_transaction(32'd0, 4, 16'h1000);
    expect_response(32'd0, 2'd0, 16'h1000);

    request_line(32'd16, 2'd1, VOICE_ID_WIDTH'(0), 1'b0);
    expect_response(32'd16, 2'd1, 16'h1200);

    request_line(32'd64, 2'd2, VOICE_ID_WIDTH'(0), 1'b0);
    return_transaction(32'd64, 1, 16'h5000);
    expect_response(32'd64, 2'd2, 16'h5000);

    // A fallback line must not replace the persistent voice window.
    request_line(32'd16, 2'd3, VOICE_ID_WIDTH'(0), 1'b0);
    expect_response(32'd16, 2'd3, 16'h1200);

    request_line(32'd64, 2'd0, VOICE_ID_WIDTH'(0), 1'b1);
    return_transaction(32'd64, 4, 16'h6000);
    expect_response(32'd64, 2'd0, 16'h6000);

    // The highest voice ID owns independent metadata and BRAM lines.
    request_line(32'd0, 2'd1, VOICE_ID_WIDTH'(NUM_VOICES - 1), 1'b1);
    return_transaction(32'd0, 4, 16'h8000);
    expect_response(32'd0, 2'd1, 16'h8000);
    request_line(32'd64, 2'd2, VOICE_ID_WIDTH'(0), 1'b0);
    expect_response(32'd64, 2'd2, 16'h6000);

    if (stat_client_requests != 7 || stat_window_hits != 3 ||
        stat_window_refills != 3 || stat_fallback_reads != 1 ||
        stat_memory_reads != 13 || stat_evictions != 1 ||
        stat_stall_cycles != 0)
      $fatal(1, "voice sample window statistics mismatch");

    $display("PASS: persistent voice sample window refill, hit, fallback, and isolation");
    $finish;
  end

  initial begin
    repeat (3000) @(posedge clk);
    $fatal(1, "voice sample window test timeout");
  end
endmodule
