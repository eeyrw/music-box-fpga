`timescale 1ns/1ps

module tb_voice_major_render_core;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic install_valid;
  logic install_ready;
  logic [VOICE_ID_WIDTH-1:0] install_voice;
  block_voice_state_snapshot_t install_state;
  logic params_write_valid;
  logic params_write_ready;
  logic [VOICE_ID_WIDTH-1:0] params_write_voice;
  logic [VOICE_GENERATION_WIDTH-1:0] params_write_generation;
  voice_event_params_t params_write_event;
  volume_env_params_t params_write_env;
  logic stale_params_write_pulse;
  logic stale_dynamic_write_pulse;
  logic block_req_valid;
  logic block_req_ready;
  render_block_req_t block_req;
  logic render_busy;
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

  voice_major_render_core dut (.*);

  task automatic service_line(input logic [ADDR_WIDTH-1:0] base_addr);
    integer word_index;
    logic [ADDR_WIDTH-1:0] line_addr;
    begin
      for (int line = 0; line < 4; line++) begin
        line_addr = base_addr + ADDR_WIDTH'(line * BLOCK_LINE_WORDS);
        while (!line_req_valid) @(negedge clk);
        if (line_req.aligned_line_addr != line_addr)
          $fatal(1, "replacement core line request mismatch");
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

  task automatic render_and_read(
      input logic [TIMELINE_FRAME_WIDTH-1:0] start_frame,
      input logic signed [MIX_WIDTH-1:0] expected_sample,
      input logic service_memory);
    logic [BLOCK_BUFFER_ID_WIDTH-1:0] buffer_id;
    begin
      @(negedge clk);
      block_req.start_frame = start_frame;
      block_req.frame_count = BLOCK_FRAME_COUNT_WIDTH'(1);
      block_req_valid = 1'b1;
      do @(posedge clk); while (!block_req_ready);
      @(negedge clk);
      block_req_valid = 1'b0;
      if (service_memory)
        service_line(32'd96);

      do @(posedge clk); while (!block_complete_valid);
      buffer_id = block_complete.buffer_id;
      if (block_complete.start_frame != start_frame)
        $fatal(1, "replacement core timeline mismatch");
      @(negedge clk);
      block_complete_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      block_complete_ready = 1'b0;

      block_read_req.buffer_id = buffer_id;
      block_read_req.frame_index = '0;
      block_read_req_valid = 1'b1;
      do @(posedge clk); while (!block_read_req_ready);
      @(negedge clk);
      block_read_req_valid = 1'b0;
      do @(posedge clk); while (!block_read_rsp_valid);
      if ($signed(block_read_rsp.sample.l) != expected_sample ||
          $signed(block_read_rsp.sample.r) != expected_sample)
        $fatal(1, "replacement core sample mismatch: l=%0d r=%0d expected=%0d",
               $signed(block_read_rsp.sample.l),
               $signed(block_read_rsp.sample.r), expected_sample);
      @(negedge clk);
      block_read_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      block_read_rsp_ready = 1'b0;

      block_release_buffer_id = buffer_id;
      block_release_valid = 1'b1;
      do @(posedge clk); while (!block_release_ready);
      @(negedge clk);
      block_release_valid = 1'b0;
    end
  endtask

  initial begin
    install_valid = 1'b0;
    install_voice = VOICE_ID_WIDTH'(300 % NUM_VOICES);
    install_state = '0;
    install_state.region.base_addr = 32'd100;
    install_state.region.length = 24'd8;
    install_state.region.loop_mode = LOOP_MODE_NONE;
    install_state.event_params.phase_inc = 32'h0000_0100;
    install_state.event_params.gain_l = 16'sh7fff;
    install_state.event_params.gain_r = 16'sh7fff;
    install_state.dynamic.active = 1'b1;
    install_state.dynamic.generation = 16'h1234;
    install_state.dynamic.env_state.stage = ENV_SUSTAIN;
    params_write_valid = 1'b0;
    params_write_voice = '0;
    params_write_generation = '0;
    params_write_event = '0;
    params_write_env = '0;
    block_req_valid = 1'b0;
    block_req = '0;
    line_req_ready = 1'b0;
    line_rsp_valid = 1'b0;
    line_rsp = '0;
    block_complete_ready = 1'b0;
    block_read_req_valid = 1'b0;
    block_read_req = '0;
    block_read_rsp_ready = 1'b0;
    block_release_valid = 1'b0;
    block_release_buffer_id = '0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    install_valid = 1'b1;
    do @(posedge clk); while (!install_ready);
    @(negedge clk);
    install_valid = 1'b0;

    render_and_read(32'd20, 24'sd99, 1'b1);
    render_and_read(32'd21, 24'sd100, 1'b0);
    if (stale_params_write_pulse || stale_dynamic_write_pulse)
      $fatal(1, "replacement core reported a false stale write");

    $display("PASS: replacement voice-major render core state continuity");
    $finish;
  end

  initial begin
    repeat (12000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
