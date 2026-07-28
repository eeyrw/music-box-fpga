`timescale 1ns/1ps

module tb_voice_major_render_core;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  reg_bus_req_t bus_req;
  reg_bus_rsp_t bus_rsp;
  logic cmd_stream_valid;
  logic [31:0] cmd_stream_data;
  logic cmd_stream_ready;
  logic [31:0] command_error_count;
  logic [31:0] stale_generation_count;
  global_audio_config_t audio_config;
  logic [1:0] effect_clear;
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

  task automatic send_command_word(input logic [31:0] word);
    begin
      @(negedge clk);
      cmd_stream_data = word;
      cmd_stream_valid = 1'b1;
      do @(posedge clk); while (!cmd_stream_ready);
      @(negedge clk);
      cmd_stream_valid = 1'b0;
    end
  endtask

  task automatic start_mono_voice;
    begin
      send_command_word(32'h1000_0005 |
                        (32'(300 % NUM_VOICES) << 14));
      send_command_word(32'h0000_1234);
      send_command_word(32'd100);
      send_command_word(32'd8);
      send_command_word(32'h0000_0100);
      send_command_word(32'h7fff_7fff);
    end
  endtask

  task automatic configure_audio;
    logic clear_seen;
    begin
      if (audio_config.master_volume != 16'sh7fff)
        $fatal(1, "voice-major audio control reset value mismatch");
      send_command_word(32'h2100_0001);
      send_command_word(32'h0000_4000);
      do @(posedge clk); while (audio_config.master_volume != 16'sh4000);

      clear_seen = 1'b0;
      send_command_word(32'h2400_0001);
      send_command_word(32'h0000_0003);
      repeat (20) begin
        @(posedge clk);
        if (effect_clear == 2'b11)
          clear_seen = 1'b1;
      end
      if (!clear_seen)
        $fatal(1, "voice-major effect-clear command was not dispatched");
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
    bus_req = '0;
    cmd_stream_valid = 1'b0;
    cmd_stream_data = '0;
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

    configure_audio();
    start_mono_voice();

    render_and_read(32'd20, 24'sd99, 1'b1);
    render_and_read(32'd21, 24'sd100, 1'b0);
    if (command_error_count != 0 || stale_generation_count != 0)
      $fatal(1, "replacement core reported a false stale write");

    $display("PASS: replacement voice-major render core state continuity");
    $finish;
  end

  initial begin
    repeat (12000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
