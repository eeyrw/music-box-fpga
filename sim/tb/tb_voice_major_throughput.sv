`timescale 1ns/1ps

module tb_voice_major_throughput;
  import synth_pkg::*;

`ifdef SYNTH_ACTIVE_LANES
  localparam int ACTIVE_LANES = `SYNTH_ACTIVE_LANES;
`else
  localparam int ACTIVE_LANES = 256;
`endif
  localparam int BLOCK_DEADLINE_CYCLES =
      (100_000_000 * MAX_BLOCK_FRAMES) / 48_000;
`ifdef SYNTH_FILTER_ENABLE
  localparam bit FILTER_ENABLE = 1'b1;
`else
  localparam bit FILTER_ENABLE = 1'b0;
`endif
  localparam string MEMORY_PROFILE = "ideal_zero_wait";
  localparam string QUALIFICATION = "theoretical_only";

  logic clk = 1'b0;
  logic rst = 1'b1;
  reg_bus_req_t bus_req;
/* verilator lint_off UNUSEDSIGNAL */
  reg_bus_rsp_t bus_rsp;
/* verilator lint_on UNUSEDSIGNAL */
  logic cmd_stream_valid;
  logic [31:0] cmd_stream_data;
  logic cmd_stream_ready;
  logic [31:0] command_error_count;
  logic [31:0] stale_generation_count;
/* verilator lint_off UNUSEDSIGNAL */
  global_audio_config_t audio_config;
  logic [1:0] effect_clear;
/* verilator lint_on UNUSEDSIGNAL */
  logic block_req_valid;
  logic block_req_ready;
  render_block_req_t block_req;
/* verilator lint_off UNUSEDSIGNAL */
  logic render_busy;
/* verilator lint_on UNUSEDSIGNAL */
  logic line_req_valid;
  logic line_req_ready;
  ordered_line_req_t line_req;
  logic line_rsp_valid;
/* verilator lint_off UNUSEDSIGNAL */
  logic line_rsp_ready;
/* verilator lint_on UNUSEDSIGNAL */
  ordered_line_rsp_t line_rsp;
  logic block_complete_valid;
  logic block_complete_ready;
/* verilator lint_off UNUSEDSIGNAL */
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
  sample_window_diagnostics_t sample_window_diagnostics;
/* verilator lint_on UNUSEDSIGNAL */
  integer cycle_count;
  integer start_cycle;
  integer block_cycles;
  integer engine_start_count;
  integer line_request_count;
  integer contribution_count;
  integer dsp_issue_count;
  integer dsp_select_count;
  integer last_lane_issue_cycle [0:BLOCK_WORK_ENTRY_COUNT-1];
  integer dsp_issue_run;
  integer max_dsp_issue_run;
  integer frontend_dsp_overlap_cycles;
  integer max_outstanding_voices;
  integer controller_state_cycles [0:7];
  integer first_engine_start_cycle;
  integer last_engine_start_cycle;

/* verilator lint_off BLKSEQ */
  always #5 clk <= ~clk;
/* verilator lint_on BLKSEQ */
  always_ff @(posedge clk) begin
    if (rst) begin
      cycle_count <= 0;
      line_rsp_valid <= 1'b0;
      line_rsp <= '0;
      engine_start_count <= 0;
      line_request_count <= 0;
      contribution_count <= 0;
      dsp_issue_count <= 0;
      dsp_select_count <= 0;
      dsp_issue_run <= 0;
      max_dsp_issue_run <= 0;
      frontend_dsp_overlap_cycles <= 0;
      max_outstanding_voices <= 0;
      first_engine_start_cycle <= -1;
      last_engine_start_cycle <= -1;
      for (int state_index = 0; state_index < 8; state_index++)
        controller_state_cycles[state_index] <= 0;
      for (int lane = 0; lane < BLOCK_WORK_ENTRY_COUNT; lane++)
        last_lane_issue_cycle[lane] <= -1;
    end else begin
      cycle_count <= cycle_count + 1;
      controller_state_cycles[dut.controller.state_q] <=
          controller_state_cycles[dut.controller.state_q] + 1;
      line_rsp_valid <= line_req_valid && line_req_ready;
      for (int word_index = 0; word_index < BLOCK_LINE_WORDS; word_index++)
        line_rsp.words[word_index] <= 16'd100;

      if (dut.controller.engine_start_valid &&
          dut.controller.engine_start_ready) begin
        engine_start_count <= engine_start_count + 1;
        if (first_engine_start_cycle < 0)
          first_engine_start_cycle <= cycle_count;
        last_engine_start_cycle <= cycle_count;
      end
      if (line_req_valid && line_req_ready)
        begin
          if (line_req.aligned_line_addr !=
              ADDR_WIDTH'(96 + (line_request_count % 4) * BLOCK_LINE_WORDS))
            $fatal(1, "voice-major segment lost contiguous line order");
          line_request_count <= line_request_count + 1;
        end
      if (dut.controller.engine.contribution_valid &&
          dut.controller.engine.contribution_ready)
        contribution_count <= contribution_count + 1;
      if (dut.controller.engine.renderer.dsp_token_valid &&
          dut.controller.engine.renderer.dsp_token_ready) begin
        dsp_issue_count <= dsp_issue_count + 1;
        dsp_issue_run <= dsp_issue_run + 1;
        if ((dsp_issue_run + 1) > max_dsp_issue_run)
          max_dsp_issue_run <= dsp_issue_run + 1;
      end else begin
        dsp_issue_run <= 0;
      end
      if (dut.controller.engine.renderer.issue_select_capture) begin
        dsp_select_count <= dsp_select_count + 1;
        if ((last_lane_issue_cycle[
                dut.controller.engine.renderer.issue_candidate_lane] >= 0) &&
            ((cycle_count - last_lane_issue_cycle[
                dut.controller.engine.renderer.issue_candidate_lane]) <
             BLOCK_WORK_ENTRY_COUNT)) begin
          $fatal(1, "DSP barrel reused a lane before the feedback distance");
        end
        last_lane_issue_cycle[
            dut.controller.engine.renderer.issue_candidate_lane] <= cycle_count;
      end
      if ((dut.controller.engine.renderer.plan_found ||
           dut.controller.engine.renderer.cache_req_valid ||
           (dut.controller.engine.renderer.line_cache.state_q != '0)) &&
          ((|dut.controller.engine.renderer.dsp.valid_q) ||
           dut.controller.engine.renderer.dsp.retire_valid))
        frontend_dsp_overlap_cycles <= frontend_dsp_overlap_cycles + 1;
      if (int'(dut.controller.outstanding_voices_q) > max_outstanding_voices)
        max_outstanding_voices <=
            int'(dut.controller.outstanding_voices_q);
    end
  end

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

  task automatic install_lane(input int lane);
    logic [5:0] flags;
    logic [7:0] payload_words;
    begin
      flags = FILTER_ENABLE ? 6'b000101 : 6'b000001;
      payload_words = FILTER_ENABLE ? 8'd10 : 8'd7;
      send_command_word(32'h1000_0000 | (32'(lane) << 14) |
                        (32'(flags) << 8) | 32'(payload_words));
      send_command_word(32'(lane + 1));
      send_command_word(32'd96);
      send_command_word(32'd4096);
      send_command_word(32'd0);
      send_command_word(32'd4096);
      send_command_word(32'h0000_0100);
      send_command_word(32'h7fff_7fff);
      if (FILTER_ENABLE) begin
        send_command_word(32'h0000_2000);
        send_command_word(32'd0);
        send_command_word(32'h0001_0000);
      end
    end
  endtask

  initial begin
    if (NUM_VOICES < ACTIVE_LANES)
      $fatal(1, "configured voice count is below the active-lane workload");
    if ((MAX_BLOCK_FRAMES != 8) && (MAX_BLOCK_FRAMES != 16))
      $fatal(1, "throughput test supports eight- or sixteen-frame blocks");

    bus_req = '0;
    cmd_stream_valid = 1'b0;
    cmd_stream_data = '0;
    block_req_valid = 1'b0;
    block_req = '0;
    line_req_ready = 1'b1;
    block_complete_ready = 1'b0;
    block_read_req_valid = 1'b0;
    block_read_req = '0;
    block_read_rsp_ready = 1'b0;
    block_release_valid = 1'b0;
    block_release_buffer_id = '0;
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    for (int lane = 0; lane < ACTIVE_LANES; lane++)
      install_lane(lane);

    @(negedge clk);
    block_req.start_frame = 32'd0;
    block_req.frame_count = BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES);
    block_req_valid = 1'b1;
    do @(posedge clk); while (!block_req_ready);
    start_cycle = cycle_count;
    @(negedge clk);
    block_req_valid = 1'b0;

    do @(posedge clk); while (!block_complete_valid);
    block_cycles = cycle_count - start_cycle;
    if (block_complete.frame_count != BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES))
      $fatal(1, "throughput block metadata mismatch");
    if (command_error_count != 0 || stale_generation_count != 0)
      $fatal(1, "throughput run observed stale state write");
    if (engine_start_count != ACTIVE_LANES ||
        dsp_select_count != (ACTIVE_LANES * MAX_BLOCK_FRAMES) ||
        dsp_issue_count != (ACTIVE_LANES * MAX_BLOCK_FRAMES) ||
        contribution_count != (ACTIVE_LANES * MAX_BLOCK_FRAMES))
      $fatal(1, "throughput run lost voice work or contributions");
    if ((ACTIVE_LANES > 1) &&
        ((max_outstanding_voices < 2) ||
         (frontend_dsp_overlap_cycles == 0)))
      $fatal(1, "voice frontend and DSP did not overlap");
    if (block_cycles > BLOCK_DEADLINE_CYCLES)
      $fatal(1, "%0d-lane memory workload missed the block deadline",
             ACTIVE_LANES);

    $display("VOICE_MAJOR_THROUGHPUT active_lanes=%0d frames=%0d filter=%0d memory=%s qualification=%s cycles=%0d deadline=%0d cycles_per_lane=%0d",
             ACTIVE_LANES, MAX_BLOCK_FRAMES, FILTER_ENABLE, MEMORY_PROFILE,
             QUALIFICATION, block_cycles, BLOCK_DEADLINE_CYCLES,
             block_cycles / ACTIVE_LANES);
    $display("VOICE_MAJOR_STAGES voices=%0d max_outstanding=%0d frontend_dsp_overlap=%0d line_requests=%0d dsp_issues=%0d max_issue_run=%0d contributions=%0d",
             engine_start_count, max_outstanding_voices,
             frontend_dsp_overlap_cycles, line_request_count,
             dsp_issue_count, max_dsp_issue_run, contribution_count);
    $display("VOICE_MAJOR_CONTROLLER idle=%0d wait_fill=%0d request=%0d wait_state=%0d dispatch=%0d drain=%0d finish=%0d first_start=%0d last_start=%0d",
             controller_state_cycles[0], controller_state_cycles[1],
             controller_state_cycles[2], controller_state_cycles[3],
             controller_state_cycles[4], controller_state_cycles[5],
             controller_state_cycles[6],
             first_engine_start_cycle, last_engine_start_cycle);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "throughput testbench timeout");
  end
endmodule
