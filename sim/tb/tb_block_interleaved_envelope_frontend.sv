`timescale 1ns/1ps

module tb_block_interleaved_envelope_frontend;
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
  logic result_valid;
  logic result_ready;
  logic [VOICE_ID_WIDTH-1:0] result_voice_index;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] result_frame_count;
  voice_playback_region_t result_region;
  voice_event_params_t result_params;
  voice_dynamic_state_t result_dynamic;
  block_envelope_result_t result_envelope;

  always #5 clk = ~clk;

  block_interleaved_envelope_frontend dut (.*);

  task automatic submit(input int voice);
    begin
      @(negedge clk);
      start_voice_index = VOICE_ID_WIDTH'(voice);
      start_region.base_addr = ADDR_WIDTH'(voice * 64);
      start_params.phase_inc = PHASE_WIDTH'(voice + 1);
      start_dynamic.generation = VOICE_GENERATION_WIDTH'(voice + 16);
      start_valid = 1'b1;
      do @(posedge clk); while (!start_ready);
      @(negedge clk);
      start_valid = 1'b0;
    end
  endtask

  task automatic accept_result(input int voice);
    logic [VOICE_ID_WIDTH-1:0] held_voice;
    block_envelope_result_t held_envelope;
    begin
      do @(posedge clk); while (!result_valid);
      held_voice = result_voice_index;
      held_envelope = result_envelope;
      @(posedge clk);
      if (!result_valid || result_voice_index != held_voice ||
          result_envelope != held_envelope)
        $fatal(1, "interleaved envelope result changed under backpressure");
      if (result_voice_index != VOICE_ID_WIDTH'(voice) ||
          result_frame_count != BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES) ||
          result_region.base_addr != ADDR_WIDTH'(voice * 64) ||
          result_params.phase_inc != PHASE_WIDTH'(voice + 1) ||
          result_dynamic.generation != VOICE_GENERATION_WIDTH'(voice + 16) ||
          !result_dynamic.active || result_dynamic.env_state.stage != ENV_SUSTAIN ||
          !result_envelope.active ||
          result_envelope.phase_advance_mask != '1 ||
          result_envelope.render_mask != '1)
        $fatal(1, "interleaved envelope tag or state mismatch");
      for (int frame = 0; frame < MAX_BLOCK_FRAMES; frame++) begin
        if (result_envelope.envelope_levels[frame] != 16'sh7fff)
          $fatal(1, "interleaved envelope level mismatch");
      end
      @(negedge clk);
      result_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      result_ready = 1'b0;
    end
  endtask

  initial begin
    start_valid = 1'b0;
    start_voice_index = '0;
    start_frame_count = BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES);
    start_region = '0;
    start_params = '0;
    start_env_params = '0;
    start_dynamic = '0;
    start_dynamic.active = 1'b1;
    start_dynamic.env_state.stage = ENV_SUSTAIN;
    result_ready = 1'b0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    for (int voice = 0; voice < BLOCK_WORK_ENTRY_COUNT; voice++)
      submit(voice);
    for (int voice = 0; voice < BLOCK_WORK_ENTRY_COUNT; voice++)
      accept_result(voice);

    if (!start_ready)
      $fatal(1, "interleaved envelope slots did not return to free state");
    $display("PASS: interleaved envelope tags, levels, and backpressure");
    $finish;
  end

  initial begin
    repeat (5000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
