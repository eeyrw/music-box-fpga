`timescale 1ns/1ps

module tb_block_mono_voice_engine;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic start_valid;
  logic start_ready;
  logic [VOICE_ID_WIDTH-1:0] start_voice_index;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] start_frame_count;
  voice_playback_region_t start_region;
  voice_event_params_t start_params;
  volume_env_params_t start_env_params;
  voice_dynamic_state_t start_dynamic;
  logic line_req_valid;
  logic line_req_ready;
  ordered_line_req_t line_req;
  logic line_rsp_valid;
  logic line_rsp_ready;
  ordered_line_rsp_t line_rsp;
  logic contribution_valid;
  logic contribution_ready;
  block_voice_contribution_t contribution;
  logic result_valid;
  logic result_ready;
  logic [VOICE_ID_WIDTH-1:0] result_voice_index;
  voice_dynamic_state_t result_dynamic;
/* verilator lint_off UNUSEDSIGNAL */
  sample_window_diagnostics_t sample_window_diagnostics;
/* verilator lint_on UNUSEDSIGNAL */

  always #5 clk <= ~clk;

  block_mono_voice_engine dut (.*);

  task automatic start_voice;
    begin
      @(negedge clk);
      start_valid = 1'b1;
      do @(posedge clk); while (!start_ready);
      @(negedge clk);
      start_valid = 1'b0;
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
          $fatal(1, "engine line request mismatch");
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

  task automatic consume_result(output voice_dynamic_state_t value);
    voice_dynamic_state_t held;
    begin
      do @(posedge clk); while (!result_valid);
      held = result_dynamic;
      @(posedge clk);
      if (!result_valid || result_dynamic != held)
        $fatal(1, "engine dynamic result changed under backpressure");
      value = result_dynamic;
      @(negedge clk);
      result_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      result_ready = 1'b0;
    end
  endtask

  initial begin
/* verilator lint_off UNUSEDSIGNAL */
    voice_dynamic_state_t final_state;
/* verilator lint_on UNUSEDSIGNAL */

    start_valid = 1'b0;
    start_voice_index = VOICE_ID_WIDTH'(5);
    start_frame_count = BLOCK_FRAME_COUNT_WIDTH'(1);
    start_region = '0;
    start_region.base_addr = 32'd100;
    start_region.length = 24'd8;
    start_region.loop_mode = LOOP_MODE_NONE;
    start_params = '0;
    start_params.phase_inc = 32'h0000_0100;
    start_params.gain_l = 16'sh7fff;
    start_params.gain_r = 16'sh7fff;
    start_env_params = '0;
    start_dynamic = '0;
    start_dynamic.active = 1'b1;
    start_dynamic.generation = 16'h0028;
    start_dynamic.env_state.stage = ENV_SUSTAIN;
    line_req_ready = 1'b0;
    line_rsp_valid = 1'b0;
    line_rsp = '0;
    contribution_ready = 1'b0;
    result_ready = 1'b0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    start_voice();
    service_line(32'd96);
    do @(posedge clk); while (!contribution_valid);
    if (contribution.voice_index != start_voice_index ||
        contribution.generation != 16'h0028 ||
        contribution.block_frame_index != '0 ||
        $signed(contribution.contribution_l) != 16'sd99 ||
        $signed(contribution.contribution_r) != 16'sd99)
      $fatal(1, "engine contribution mismatch");
    @(negedge clk);
    contribution_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    contribution_ready = 1'b0;
    consume_result(final_state);
    if (result_voice_index != start_voice_index || !final_state.active ||
        final_state.phase != 32'h0000_0100 ||
        final_state.env_state.stage != ENV_SUSTAIN ||
        final_state.generation != 16'h0028)
      $fatal(1, "engine dynamic state writeback mismatch");

    start_env_params.delay_samples = 24'd2;
    start_dynamic.phase = 32'h0000_0300;
    start_dynamic.env_state = '0;
    start_dynamic.env_state.stage = ENV_DELAY;
    start_voice();
    while (!result_valid) begin
      @(posedge clk);
      if (line_req_valid || contribution_valid)
        $fatal(1, "Delay frame issued memory or DSP work");
    end
    consume_result(final_state);
    if (!final_state.active || final_state.phase != 32'h0000_0400 ||
        final_state.env_state.stage != ENV_DELAY ||
        final_state.env_state.elapsed != 24'd1)
      $fatal(1, "Delay frame did not advance phase and envelope state");

    $display("PASS: mono voice block engine state ownership");
    $finish;
  end

  initial begin
    repeat (4000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
