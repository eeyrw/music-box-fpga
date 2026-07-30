`timescale 1ns/1ps

module tb_block_mix_buffer;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic block_req_valid;
  logic block_req_ready;
  render_block_req_t block_req;
/* verilator lint_off UNUSEDSIGNAL */
  logic block_fill_ready;
/* verilator lint_on UNUSEDSIGNAL */
  logic contribution_valid;
  logic contribution_ready;
  logic [BLOCK_FRAME_INDEX_WIDTH-1:0] contribution_frame_index;
  stereo_pcm_t contribution;
  logic block_finish_valid;
  logic block_finish_ready;
  logic block_complete_valid;
  logic block_complete_ready;
  render_block_complete_t block_complete;
  logic block_read_req_valid;
  logic block_read_req_ready;
  render_block_read_req_t block_read_req;
  logic block_read_rsp_valid;
  logic block_read_rsp_ready;
  render_block_read_rsp_t block_read_rsp;
  logic block_release_valid;
  logic block_release_ready;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] block_release_buffer_id;

  always #5 clk <= ~clk;

  block_mix_buffer dut (.*);

  task automatic start_block(input logic [31:0] start_frame,
                             input logic [BLOCK_FRAME_COUNT_WIDTH-1:0] count);
    begin
      @(negedge clk);
      block_req.start_frame = start_frame;
      block_req.frame_count = count;
      block_req_valid = 1'b1;
      do @(posedge clk); while (!block_req_ready);
      @(negedge clk);
      block_req_valid = 1'b0;
    end
  endtask

  task automatic add_contribution(
      input logic [BLOCK_FRAME_INDEX_WIDTH-1:0] index,
      input logic signed [PCM_WIDTH-1:0] left,
      input logic signed [PCM_WIDTH-1:0] right);
    begin
      @(negedge clk);
      contribution_frame_index = BLOCK_FRAME_INDEX_WIDTH'(index);
      contribution.l = PCM_WIDTH'(left);
      contribution.r = PCM_WIDTH'(right);
      contribution_valid = 1'b1;
      do @(posedge clk); while (!contribution_ready);
      @(negedge clk);
      contribution_valid = 1'b0;
    end
  endtask

  task automatic finish_block;
    begin
      @(negedge clk);
      block_finish_valid = 1'b1;
      do @(posedge clk); while (!block_finish_ready);
      @(negedge clk);
      block_finish_valid = 1'b0;
    end
  endtask

  task automatic accept_completion(output logic buffer_id);
    render_block_complete_t held;
    begin
      do @(posedge clk); while (!block_complete_valid);
      held = block_complete;
      repeat (3) begin
        @(posedge clk);
        if (!block_complete_valid || block_complete != held) begin
          $fatal(1, "completion changed under backpressure");
        end
      end
      buffer_id = block_complete.buffer_id;
      @(negedge clk);
      block_complete_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      block_complete_ready = 1'b0;
    end
  endtask

  task automatic read_sample(input logic buffer_id, input int index,
                             input int expected_l, input int expected_r);
    render_block_read_rsp_t held;
    begin
      @(negedge clk);
      block_read_req.buffer_id = buffer_id;
      block_read_req.frame_index = BLOCK_FRAME_INDEX_WIDTH'(index);
      block_read_req_valid = 1'b1;
      do @(posedge clk); while (!block_read_req_ready);
      @(negedge clk);
      block_read_req_valid = 1'b0;
      do @(posedge clk); while (!block_read_rsp_valid);
      held = block_read_rsp;
      @(posedge clk);
      if (!block_read_rsp_valid || block_read_rsp != held) begin
        $fatal(1, "read response changed under backpressure");
      end
      if (32'($signed(block_read_rsp.sample.l)) != expected_l ||
          32'($signed(block_read_rsp.sample.r)) != expected_r) begin
        $fatal(1, "sample %0d mismatch: got %0d,%0d expected %0d,%0d",
               index, $signed(block_read_rsp.sample.l),
               $signed(block_read_rsp.sample.r), expected_l, expected_r);
      end
      @(negedge clk);
      block_read_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      block_read_rsp_ready = 1'b0;
    end
  endtask

  task automatic release_block(input logic buffer_id);
    begin
      @(negedge clk);
      block_release_buffer_id = buffer_id;
      block_release_valid = 1'b1;
      do @(posedge clk); while (!block_release_ready);
      @(negedge clk);
      block_release_valid = 1'b0;
    end
  endtask

  initial begin
    logic first_bank;
    logic second_bank;

    block_req_valid = 1'b0;
    block_req = '0;
    contribution_valid = 1'b0;
    contribution_frame_index = '0;
    contribution = '0;
    block_finish_valid = 1'b0;
    block_complete_ready = 1'b0;
    block_read_req_valid = 1'b0;
    block_read_req = '0;
    block_read_rsp_ready = 1'b0;
    block_release_valid = 1'b0;
    block_release_buffer_id = '0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    start_block(32'd100, 3);
    add_contribution(0, 1000, -1000);
    add_contribution(0, -250, 500);
    add_contribution(1, 32767, -32768);
    finish_block();
    accept_completion(first_bank);
    if (block_complete.start_frame != 100 || block_complete.frame_count != 3) begin
      $fatal(1, "completion metadata mismatch");
    end
    read_sample(first_bank, 0, 750, -500);
    read_sample(first_bank, 1, 32767, -32768);
    read_sample(first_bank, 2, 0, 0);

    release_block(first_bank);
    start_block(32'd103, 1);
    for (int voice = 0; voice < 512; voice++)
      add_contribution(0, 32767, -32768);
    finish_block();
    accept_completion(first_bank);
    read_sample(first_bank, 0, 16776704, -16777216);

    start_block(32'd104, 1);
    add_contribution(0, -123, 456);
    finish_block();
    accept_completion(second_bank);
    if (second_bank == first_bank) $fatal(1, "owned bank was overwritten");

    @(negedge clk);
    block_req.start_frame = 32'd105;
    block_req.frame_count = 1;
    block_req_valid = 1'b1;
    repeat (2) begin
      @(posedge clk);
      if (block_req_ready) $fatal(1, "request accepted without a free bank");
    end
    @(negedge clk);
    block_req_valid = 1'b0;

    read_sample(second_bank, 0, -123, 456);
    release_block(first_bank);
    start_block(32'd104, 1);
    add_contribution(0, 7, 8);
    finish_block();
    do @(posedge clk); while (!block_complete_valid);
    @(negedge clk);
    rst = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    @(posedge clk);
    if (block_complete_valid || !block_req_ready) begin
      $fatal(1, "reset did not discard blocks and free both banks");
    end

    $display("PASS: block mix buffer");
    $finish;
  end

  initial begin
    repeat (2500) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
