`timescale 1ns/1ps

module tb_voice_major_block_controller;
  import synth_pkg::*;

  localparam int DELAY_VOICE = (NUM_VOICES > 300) ? 300 : 3;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic block_req_valid;
  logic block_req_ready;
  render_block_req_t block_req;
  logic [NUM_VOICES-1:0] active_bitmap;
  logic render_busy;
  logic state_read_req_valid;
  logic state_read_req_ready;
  logic [VOICE_ID_WIDTH-1:0] state_read_req_voice;
  logic state_read_rsp_valid;
  logic state_read_rsp_ready;
  block_voice_state_snapshot_t state_read_rsp;
  logic dynamic_write_valid;
  logic dynamic_write_ready;
  logic [VOICE_ID_WIDTH-1:0] dynamic_write_voice;
  voice_dynamic_state_t dynamic_write_data;
  logic line_req_valid;
  logic line_req_ready;
  ordered_line_req_t line_req;
  logic line_rsp_valid;
  logic line_rsp_ready;
  ordered_line_rsp_t line_rsp;
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

  always #5 clk = ~clk;

  voice_major_block_controller dut (.*);

  task automatic send_block;
    begin
      @(negedge clk);
      block_req_valid = 1'b1;
      do @(posedge clk); while (!block_req_ready);
      @(negedge clk);
      block_req_valid = 1'b0;
    end
  endtask

  task automatic provide_state(
      input logic [VOICE_ID_WIDTH-1:0] expected_voice,
      input block_voice_state_snapshot_t snapshot);
    begin
      do @(posedge clk); while (!state_read_req_valid);
      if (state_read_req_voice != expected_voice)
        $fatal(1, "state traversal order mismatch: got %0d expected %0d",
               state_read_req_voice, expected_voice);
      @(negedge clk);
      state_read_req_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      state_read_req_ready = 1'b0;
      state_read_rsp = snapshot;
      state_read_rsp_valid = 1'b1;
      do @(posedge clk); while (!state_read_rsp_ready);
      @(negedge clk);
      state_read_rsp_valid = 1'b0;
    end
  endtask

  task automatic service_line(input logic [ADDR_WIDTH-1:0] base_addr);
    integer word_index;
    logic [ADDR_WIDTH-1:0] line_addr;
    begin
      for (int line = 0; line < 4; line++) begin
        line_addr = base_addr + ADDR_WIDTH'(line * BLOCK_LINE_WORDS);
        while (!line_req_valid) @(negedge clk);
        if (line_req.aligned_line_addr != line_addr)
          $fatal(1, "controller line request mismatch");
        line_req_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        line_req_ready = 1'b0;
        line_rsp = '0;
        for (word_index = 0; word_index < BLOCK_LINE_WORDS;
             word_index = word_index + 1)
          line_rsp.words[word_index] = 16'(line_addr + word_index);
        line_rsp_valid = 1'b1;
        do @(posedge clk); while (!line_rsp_ready);
        @(negedge clk);
        line_rsp_valid = 1'b0;
      end
    end
  endtask

  task automatic accept_dynamic_write(
      input logic [VOICE_ID_WIDTH-1:0] expected_voice,
      input logic [PHASE_WIDTH-1:0] expected_phase,
      input volume_env_stage_t expected_stage,
      input logic [23:0] expected_elapsed);
    voice_dynamic_state_t held;
    begin
      do @(posedge clk); while (!dynamic_write_valid);
      held = dynamic_write_data;
      @(posedge clk);
      if (!dynamic_write_valid || dynamic_write_data != held)
        $fatal(1, "dynamic write changed under backpressure");
      if (dynamic_write_voice != expected_voice ||
          dynamic_write_data.phase != expected_phase ||
          dynamic_write_data.env_state.stage != expected_stage ||
          dynamic_write_data.env_state.elapsed != expected_elapsed)
        $fatal(1, "dynamic write mismatch for voice %0d", expected_voice);
      @(negedge clk);
      dynamic_write_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dynamic_write_ready = 1'b0;
    end
  endtask

  initial begin
    block_voice_state_snapshot_t sounding;
    block_voice_state_snapshot_t delayed;
    logic [BLOCK_BUFFER_ID_WIDTH-1:0] completed_buffer;

    block_req_valid = 1'b0;
    block_req = '0;
    block_req.start_frame = 32'h1234_5678;
    block_req.frame_count = BLOCK_FRAME_COUNT_WIDTH'(1);
    active_bitmap = '0;
    active_bitmap[1] = 1'b1;
    active_bitmap[DELAY_VOICE] = 1'b1;
    state_read_req_ready = 1'b0;
    state_read_rsp_valid = 1'b0;
    state_read_rsp = '0;
    dynamic_write_ready = 1'b0;
    line_req_ready = 1'b0;
    line_rsp_valid = 1'b0;
    line_rsp = '0;
    block_complete_ready = 1'b0;
    block_read_req_valid = 1'b0;
    block_read_req = '0;
    block_read_rsp_ready = 1'b0;
    block_release_valid = 1'b0;
    block_release_buffer_id = '0;

    sounding = '0;
    sounding.region.base_addr = 32'd100;
    sounding.region.length = 24'd8;
    sounding.region.loop_mode = LOOP_MODE_NONE;
    sounding.event_params.phase_inc = 32'h0000_0100;
    sounding.event_params.gain_l = 16'sh7fff;
    sounding.event_params.gain_r = 16'sh7fff;
    sounding.dynamic.active = 1'b1;
    sounding.dynamic.generation = 16'h0011;
    sounding.dynamic.env_state.stage = ENV_SUSTAIN;

    delayed = sounding;
    delayed.dynamic.generation = 16'h0033;
    delayed.dynamic.phase = 32'h0000_0200;
    delayed.dynamic.env_state = '0;
    delayed.dynamic.env_state.stage = ENV_DELAY;
    delayed.env_params.delay_samples = 24'd2;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    send_block();
    provide_state(VOICE_ID_WIDTH'(1), sounding);
    service_line(32'd96);
    accept_dynamic_write(VOICE_ID_WIDTH'(1), 32'h0000_0100,
                         ENV_SUSTAIN, 24'd0);

    provide_state(VOICE_ID_WIDTH'(DELAY_VOICE), delayed);
    accept_dynamic_write(VOICE_ID_WIDTH'(DELAY_VOICE), 32'h0000_0300,
                         ENV_DELAY, 24'd1);

    do @(posedge clk); while (!block_complete_valid);
    if (block_complete.start_frame != block_req.start_frame ||
        block_complete.frame_count != block_req.frame_count)
      $fatal(1, "published block metadata mismatch");
    completed_buffer = block_complete.buffer_id;
    @(posedge clk);
    if (!block_complete_valid || block_complete.buffer_id != completed_buffer)
      $fatal(1, "block completion changed under backpressure");
    @(negedge clk);
    block_complete_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_complete_ready = 1'b0;

    block_read_req.buffer_id = completed_buffer;
    block_read_req.frame_index = '0;
    block_read_req_valid = 1'b1;
    do @(posedge clk); while (!block_read_req_ready);
    @(negedge clk);
    block_read_req_valid = 1'b0;
    do @(posedge clk); while (!block_read_rsp_valid);
    if ($signed(block_read_rsp.sample.l) != 24'sd99 ||
        $signed(block_read_rsp.sample.r) != 24'sd99)
      $fatal(1, "published mix mismatch: l=%0d r=%0d",
             $signed(block_read_rsp.sample.l),
             $signed(block_read_rsp.sample.r));
    @(negedge clk);
    block_read_rsp_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    block_read_rsp_ready = 1'b0;

    block_release_buffer_id = completed_buffer;
    block_release_valid = 1'b1;
    do @(posedge clk); while (!block_release_ready);
    @(negedge clk);
    block_release_valid = 1'b0;

    $display("PASS: voice-major block traversal, writeback, and publication");
    $finish;
  end

  initial begin
    repeat (10000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
