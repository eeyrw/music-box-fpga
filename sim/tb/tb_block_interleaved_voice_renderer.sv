`timescale 1ns/1ps

module tb_block_interleaved_voice_renderer;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic diagnostics_clear = 1'b0;
  logic start_valid;
  logic start_ready;
  logic [VOICE_ID_WIDTH-1:0] start_voice_index;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] start_frame_count;
  logic [MAX_BLOCK_FRAMES-1:0] start_phase_advance_mask;
  logic [MAX_BLOCK_FRAMES-1:0] start_render_mask;
  logic signed [MAX_BLOCK_FRAMES-1:0][15:0] start_envelope_levels;
  logic start_active;
  logic [VOICE_GENERATION_WIDTH-1:0] start_generation;
  logic [PHASE_WIDTH-1:0] start_phase;
  voice_playback_region_t start_region;
  voice_event_params_t start_params;
  logic signed [FILTER_STATE_WIDTH-1:0] start_filter_z1;
  logic signed [FILTER_STATE_WIDTH-1:0] start_filter_z2;
  logic start_env_active;
  volume_env_state_t start_env_state;
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
  block_voice_dsp_result_t result;
  logic [VOICE_ID_WIDTH-1:0] result_voice_index;
  logic result_env_active;
/* verilator lint_off UNUSEDSIGNAL */
  volume_env_state_t result_env_state;
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_off UNUSEDSIGNAL */
  sample_window_diagnostics_t sample_window_diagnostics;
/* verilator lint_on UNUSEDSIGNAL */
  integer dual_descriptor_emit_count;

  always #5 clk <= ~clk;

  block_interleaved_voice_renderer dut (.*);

  always_ff @(posedge clk) begin
    if (rst)
      dual_descriptor_emit_count <= 0;
    else if (dut.descriptor_plan_q.valid &&
             dut.plan_descriptor_emit_count == 2)
      dual_descriptor_emit_count <= dual_descriptor_emit_count + 1;
  end

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
          $fatal(1, "renderer line request mismatch");
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

  task automatic expect_contribution(
      input logic [BLOCK_FRAME_INDEX_WIDTH-1:0] expected_index,
      input logic signed [15:0] expected_l,
      input logic signed [15:0] expected_r);
    block_voice_contribution_t held;
    begin
      do @(posedge clk); while (!contribution_valid);
      held = contribution;
      @(posedge clk);
      if (!contribution_valid || contribution != held)
        $fatal(1, "renderer contribution changed under backpressure");
      if (contribution.block_frame_index != expected_index ||
          $signed(contribution.contribution_l) != expected_l ||
          $signed(contribution.contribution_r) != expected_r) begin
        $fatal(1, "renderer contribution mismatch: index=%0d l=%0d r=%0d",
               contribution.block_frame_index,
               $signed(contribution.contribution_l),
               $signed(contribution.contribution_r));
      end
      @(negedge clk);
      contribution_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      contribution_ready = 1'b0;
    end
  endtask

  initial begin
    start_valid = 1'b0;
    start_voice_index = VOICE_ID_WIDTH'(12);
    start_frame_count = BLOCK_FRAME_COUNT_WIDTH'(3);
    start_phase_advance_mask = '1;
    start_render_mask = MAX_BLOCK_FRAMES'(3'b101);
    start_envelope_levels = '0;
    start_envelope_levels[0] = 16'sh7fff;
    start_envelope_levels[2] = 16'sh7fff;
    start_active = 1'b1;
    start_generation = 16'h005a;
    start_phase = 32'h0000_0080;
    start_region = '0;
    start_region.base_addr = 32'd100;
    start_region.length = 24'd32;
    start_region.loop_mode = LOOP_MODE_NONE;
    start_params = '0;
    start_params.phase_inc = 32'h0000_0580;
    start_params.gain_l = 16'sh7fff;
    start_params.gain_r = 16'sh4000;
    start_params.filter_enable = 1'b1;
    start_params.filter_b0 = 16'sh2000;
    start_params.filter_b1 = 16'sh1000;
    start_filter_z1 = '0;
    start_filter_z2 = '0;
    start_env_active = 1'b1;
    start_env_state = '0;
    start_env_state.stage = ENV_SUSTAIN;
    line_req_ready = 1'b0;
    line_rsp_valid = 1'b0;
    line_rsp = '0;
    contribution_ready = 1'b0;
    result_ready = 1'b0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    start_voice();
    if (!start_ready)
      $fatal(1, "renderer did not expose its multi-block input window");
    service_line(32'd96);
    expect_contribution(BLOCK_FRAME_INDEX_WIDTH'(0), 16'sd49, 16'sd25);
    expect_contribution(BLOCK_FRAME_INDEX_WIDTH'(2), 16'sd79, 16'sd40);

    do @(posedge clk); while (!result_valid);
    if (result_voice_index != start_voice_index || !result_env_active ||
        result_env_state.stage != ENV_SUSTAIN ||
        result.phase_result.generation != 16'h005a ||
        !result.phase_result.active ||
        result.phase_result.phase != 32'h0000_1100 ||
        result.phase_result.frames_walked != BLOCK_FRAME_COUNT_WIDTH'(3) ||
        $signed(result.filter_z1) != FILTER_STATE_WIDTH'(454656) ||
        $signed(result.filter_z2) != 0) begin
      $fatal(1, "renderer final state mismatch");
    end
    if (dual_descriptor_emit_count != 1)
      $fatal(1, "renderer did not preserve dual descriptor emission");
    @(posedge clk);
    if (!result_valid) $fatal(1, "renderer result dropped under backpressure");
    @(negedge clk);
    result_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    result_ready = 1'b0;
    if (!start_ready) $fatal(1, "renderer did not release voice ownership");

    $display("PASS: ordered-run descriptors, skipped frame, and dual emit");
    $finish;
  end

  initial begin
    repeat (3000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
