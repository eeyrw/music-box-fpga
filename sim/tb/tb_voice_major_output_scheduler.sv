`timescale 1ns/1ps

module tb_voice_major_output_scheduler;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic output_fifo_room;
  logic block_req_valid;
  logic block_req_ready;
  render_block_req_t block_req;
  logic renderer_busy;
  logic block_complete_valid;
  logic block_complete_ready;
  render_block_complete_t block_complete;
  logic block_read_req_valid;
  logic block_read_req_ready;
  render_block_read_req_t block_read_req;
  logic block_read_rsp_valid;
  logic block_read_rsp_ready;
  logic block_release_valid;
  logic block_release_ready;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] block_release_buffer_id;
  logic sample_valid;
  logic sample_ready;
  logic effects_busy;
  logic render_inflight;
  logic render_deadline_miss_pulse;
  logic [15:0] render_latency_cycles;

  always #5 clk <= ~clk;

  voice_major_output_scheduler dut (.*);

  task automatic accept_request(input logic [31:0] expected_start);
    begin
      do @(posedge clk); while (!block_req_valid);
      if (block_req.start_frame != expected_start ||
          block_req.frame_count != BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES))
        $fatal(1, "block request metadata mismatch");
      @(negedge clk);
      block_req_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      block_req_ready = 1'b0;
    end
  endtask

  task automatic publish_block(input logic buffer_id,
                               input logic [31:0] start_frame);
    begin
      @(negedge clk);
      block_complete.buffer_id = buffer_id;
      block_complete.start_frame = start_frame;
      block_complete.frame_count = BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES);
      block_complete_valid = 1'b1;
    end
  endtask

  task automatic drain_sample(input logic buffer_id, input int index);
    begin
      do @(posedge clk); while (!block_read_req_valid);
      if (block_read_req.buffer_id != buffer_id ||
          block_read_req.frame_index != BLOCK_FRAME_INDEX_WIDTH'(index))
        $fatal(1, "read request mismatch for sample %0d", index);
      @(negedge clk);
      block_read_req_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      block_read_req_ready = 1'b0;
      block_read_rsp_valid = 1'b1;
      repeat (2) begin
        @(posedge clk);
        if (!sample_valid || block_read_rsp_ready)
          $fatal(1, "sample response did not hold under backpressure");
      end
      @(negedge clk);
      sample_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      sample_ready = 1'b0;
      block_read_rsp_valid = 1'b0;
    end
  endtask

  initial begin
    logic [15:0] held_latency;

    output_fifo_room = 1'b1;
    block_req_ready = 1'b0;
    renderer_busy = 1'b0;
    block_complete_valid = 1'b0;
    block_complete = '0;
    block_read_req_ready = 1'b0;
    block_read_rsp_valid = 1'b0;
    block_release_ready = 1'b0;
    sample_ready = 1'b0;
    effects_busy = 1'b0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    accept_request(0);
    repeat (3) @(posedge clk);
    publish_block(0, 0);
    if (!block_complete_ready)
      $fatal(1, "first completion was not accepted while output was idle");
    @(posedge clk);
    @(negedge clk);
    block_complete_valid = 1'b0;

    // The second render starts before any sample from the first bank is read.
    accept_request(MAX_BLOCK_FRAMES);
    if (block_release_valid)
      $fatal(1, "first bank released before it was drained");

    drain_sample(0, 0);
    drain_sample(0, 1);
    publish_block(1, MAX_BLOCK_FRAMES);
    @(posedge clk);
    @(negedge clk);
    held_latency = render_latency_cycles;
    if (block_complete_ready)
      $fatal(1, "second completion bypassed the owned first bank");
    repeat (5) begin
      @(posedge clk);
      if (block_complete_ready || render_latency_cycles != held_latency)
        $fatal(1, "pending completion latency did not remain stable");
    end

    for (int index = 2; index < MAX_BLOCK_FRAMES; index++)
      drain_sample(0, index);

    do @(posedge clk); while (!block_release_valid);
    if (block_release_buffer_id != 0)
      $fatal(1, "wrong bank released");
    @(negedge clk);
    block_release_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_release_ready = 1'b0;

    do @(posedge clk); while (!block_complete_ready);
    @(posedge clk);
    @(negedge clk);
    block_complete_valid = 1'b0;

    // Once bank 1 is owned for draining, bank 0 can be requested again.
    accept_request(2 * MAX_BLOCK_FRAMES);
    if (!render_inflight)
      $fatal(1, "accepted render request did not set render_inflight");
    if (render_deadline_miss_pulse)
      $fatal(1, "short render incorrectly missed its deadline");

    // Reset discards independent render and drain ownership together.
    @(negedge clk);
    rst = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    @(posedge clk);
    if (!block_req_valid || block_req.start_frame != 0 || render_inflight ||
        block_read_req_valid || block_release_valid)
      $fatal(1, "reset did not clear overlapping render/drain state");

    $display("PASS: voice-major output scheduler overlap");
    $finish;
  end

  initial begin
    repeat (1000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
