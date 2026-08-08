`timescale 1ns/1ps

module tb_voice_major_render_effects_harness;
  import synth_pkg::*;

  logic core_clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic rst;
  logic cmd_stream_valid;
  /* verilator lint_off UNUSEDSIGNAL */
  logic cmd_stream_ready;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] cmd_stream_data;
  logic block_req_valid;
  logic block_req_ready;
  logic [31:0] block_start_frame;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] block_frame_count;
  logic renderer_complete_valid;
  logic block_complete_valid;
  logic block_complete_ready;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] block_complete_buffer;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [31:0] block_complete_start_frame;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] block_complete_frame_count;
  logic effect_flush_valid;
  logic effect_flush_ready;
  logic effect_output_valid;
  logic effect_output_ready;
  pcm_t effect_output_l;
  pcm_t effect_output_r;
  logic effects_busy;
  logic [15:0] effects_max_processing_cycles;
  logic [31:0] effects_input_frame_count;
  logic [31:0] effects_output_frame_count;
  logic [63:0] overlap_total_renderer_cycles;
  logic [63:0] overlap_max_renderer_cycles;
  logic [63:0] overlap_max_renderer_utilization_ppm;
  logic [31:0] overlap_renderer_deadline_misses;
  logic [63:0] overlap_total_release_cycles;
  logic [63:0] overlap_max_release_cycles;
  logic [63:0] overlap_max_initiation_cycles;
  logic [63:0] overlap_max_release_utilization_ppm;
  logic [31:0] overlap_release_deadline_misses;
  logic [63:0] ddr_accepted;
  logic [63:0] ddr_returned;
  logic [31:0] configured_max_block_frames;
  int renderer_completions = 0;
  int block_completions = 0;
  int output_frames = 0;
  int nonzero_output_frames = 0;
  int errors = 0;
  longint unsigned core_cycles = 0;
  longint unsigned request_cycle [0:3];
  longint unsigned renderer_cycle [0:3];
  longint unsigned release_cycle [0:3];

  always #16 core_clk <= ~core_clk;
  always #4 ddr_clk <= ~ddr_clk;

  /* verilator lint_off PINCONNECTEMPTY */
  voice_major_render_effects_harness dut (
    .core_clk,
    .ddr_clk,
    .rst,
    .cmd_stream_valid,
    .cmd_stream_ready,
    .cmd_stream_data,
    .block_req_valid,
    .block_req_ready,
    .block_start_frame,
    .block_frame_count,
    .renderer_complete_valid,
    .block_complete_valid,
    .block_complete_ready,
    .block_complete_buffer,
    .block_complete_start_frame,
    .block_complete_frame_count,
    .effect_flush_valid,
    .effect_flush_ready,
    .effect_output_valid,
    .effect_output_ready,
    .effect_output_l,
    .effect_output_r,
    .effects_busy,
    .effects_max_processing_cycles,
    .effects_input_frame_count,
    .effects_output_frame_count,
    .overlap_total_renderer_cycles,
    .overlap_max_renderer_cycles,
    .overlap_max_renderer_utilization_ppm,
    .overlap_renderer_deadline_misses,
    .overlap_total_release_cycles,
    .overlap_max_release_cycles,
    .overlap_max_initiation_cycles,
    .overlap_max_release_utilization_ppm,
    .overlap_release_deadline_misses,
    .render_busy(),
    .command_error_count(),
    .stale_generation_count(),
    .ddr_accepted,
    .ddr_returned,
    .ddr_row_hits(),
    .ddr_row_misses(),
    .ddr_activates(),
    .ddr_precharges(),
    .ddr_refreshes(),
    .window_client_requests(),
    .window_hits(),
    .window_memory_reads(),
    .window_evictions(),
    .window_stall_cycles(),
    .window_refills(),
    .window_fallback_reads(),
    .configured_window_bytes(),
    .configured_window_words(),
    .configured_max_block_frames,
    .active_voice_count(),
    .voice_active_bitmap(),
    .completion_event_valid(),
    .completion_event_voice(),
    .completion_event_generation(),
    .completion_event_reason(),
    .debug_plan_valid(),
    .debug_plan_voice(),
    .debug_plan_first(),
    .debug_plan_last(),
    .debug_plan_addr_0(),
    .debug_plan_addr_1()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  /* verilator lint_off BLKSEQ */
  always @(posedge core_clk) begin
    core_cycles++;
    if (renderer_complete_valid) begin
      renderer_cycle[renderer_completions] = core_cycles;
      renderer_completions++;
    end
    if (block_complete_valid && block_complete_ready) begin
      if (block_complete_start_frame != 32'(block_completions * 16) ||
          block_complete_frame_count != BLOCK_FRAME_COUNT_WIDTH'(16)) begin
        $error("block completion metadata mismatch got=%0d/%0d expected=%0d/16",
               block_complete_start_frame, block_complete_frame_count,
               block_completions * 16);
        errors++;
      end
      release_cycle[block_completions] = core_cycles;
      block_completions++;
    end
    if (effect_output_valid && effect_output_ready) begin
      output_frames++;
      if (effect_output_l != 0 || effect_output_r != 0)
        nonzero_output_frames++;
    end
  end
  /* verilator lint_on BLKSEQ */

  task automatic send_command_word(input logic [31:0] word);
    begin
      @(negedge core_clk);
      cmd_stream_data = word;
      cmd_stream_valid = 1'b1;
      do @(posedge core_clk); while (!cmd_stream_ready);
      @(negedge core_clk);
      cmd_stream_valid = 1'b0;
    end
  endtask

  task automatic install_looping_voice(input int voice);
    begin
      send_command_word(32'h1000_0107 | (32'(voice) << 14));
      send_command_word(32'h0000_0001);
      send_command_word(32'h0000_0000);
      send_command_word(32'h0000_0008);
      send_command_word(32'h0000_0000);
      send_command_word(32'h0000_0008);
      send_command_word(32'h0000_0100);
      send_command_word(32'h0020_0020);
    end
  endtask

  task automatic enable_effects;
    begin
      send_command_word(32'h2200_0006);
      send_command_word(32'h0000_0001);
      send_command_word(32'h0000_0800);
      send_command_word(32'h0000_0200);
      send_command_word(32'h0010_0000);
      send_command_word(32'h2000_2000);
      send_command_word(32'h4000_0000);

      send_command_word(32'h2300_0009);
      send_command_word(32'h0000_0001);
      send_command_word(32'h0000_2000);
      send_command_word(32'h0000_2000);
      send_command_word(32'h0000_4000);
      send_command_word(32'h0000_1000);
      repeat (4) send_command_word(32'h2000_2000);
    end
  endtask

  task automatic request_block(input int block_number);
    begin
      @(negedge core_clk);
      block_start_frame = block_number * 16;
      block_frame_count = BLOCK_FRAME_COUNT_WIDTH'(16);
      block_req_valid = 1'b1;
      do @(posedge core_clk); while (!block_req_ready);
      request_cycle[block_number] = core_cycles;
      @(negedge core_clk);
      block_req_valid = 1'b0;
    end
  endtask

  task automatic flush_zero;
    begin
      @(negedge core_clk);
      effect_flush_valid = 1'b1;
      do @(posedge core_clk); while (!effect_flush_ready);
      @(negedge core_clk);
      effect_flush_valid = 1'b0;
    end
  endtask

  initial begin
    longint unsigned max_render_cycles;
    longint unsigned max_release_cycles;
    longint unsigned max_initiation_cycles;

    rst = 1'b1;
    cmd_stream_valid = 1'b0;
    cmd_stream_data = '0;
    block_req_valid = 1'b0;
    block_start_frame = '0;
    block_frame_count = '0;
    block_complete_ready = 1'b1;
    effect_flush_valid = 1'b0;
    effect_output_ready = 1'b1;
    repeat (8) @(negedge core_clk);
    rst = 1'b0;

    enable_effects();
    for (int voice = 0; voice < NUM_VOICES; voice++)
      install_looping_voice(voice);
    while (dut.active_voice_count != 16'(NUM_VOICES)) @(negedge core_clk);

    request_block(0);
    for (int block = 1; block < 4; block++) begin
      while (renderer_completions < block) @(negedge core_clk);
      request_block(block);
    end
    while (block_completions < 4) @(negedge core_clk);
    while (output_frames < 16) @(negedge core_clk);
    if (output_frames != 16) begin
      $error("lookahead warm-up output count mismatch got=%0d", output_frames);
      errors++;
    end

    repeat (48) flush_zero();
    while (output_frames < 64) @(negedge core_clk);
    repeat (2) @(negedge core_clk);

    if (renderer_completions != 4 || block_completions != 4 ||
        effects_input_frame_count != 32'd112 ||
        effects_output_frame_count != 32'd64 ||
        output_frames != 64 || effects_max_processing_cycles == 0 ||
        effects_max_processing_cycles > 16'd96 || effects_busy ||
        configured_max_block_frames != 32'd16 || ddr_accepted == 0 ||
        ddr_accepted != ddr_returned || nonzero_output_frames == 0 ||
        overlap_total_renderer_cycles == 0 ||
        overlap_max_renderer_cycles == 0 ||
        overlap_max_renderer_utilization_ppm >= 64'd1_000_000 ||
        overlap_renderer_deadline_misses != 0 ||
        overlap_total_release_cycles == 0 ||
        overlap_max_release_cycles == 0 ||
        overlap_max_initiation_cycles == 0 ||
        overlap_max_release_utilization_ppm >= 64'd1_000_000 ||
        overlap_release_deadline_misses != 0) begin
      $error("effects harness accounting mismatch renderer=%0d blocks=%0d outputs=%0d inputs=%0d rtl_outputs=%0d max_cycles=%0d",
             renderer_completions, block_completions, output_frames,
             effects_input_frame_count, effects_output_frame_count,
             effects_max_processing_cycles);
      errors++;
    end

    max_render_cycles = 0;
    max_release_cycles = 0;
    max_initiation_cycles = 0;
    for (int block = 0; block < 4; block++) begin
      if (renderer_cycle[block] - request_cycle[block] > max_render_cycles)
        max_render_cycles = renderer_cycle[block] - request_cycle[block];
      if (release_cycle[block] - request_cycle[block] > max_release_cycles)
        max_release_cycles = release_cycle[block] - request_cycle[block];
      if (block != 0 &&
          request_cycle[block] - request_cycle[block-1] >
          max_initiation_cycles)
        max_initiation_cycles =
            request_cycle[block] - request_cycle[block-1];
      if (block != 3 && request_cycle[block+1] >= release_cycle[block]) begin
        $error("block %0d did not overlap drain: next_request=%0d release=%0d",
               block, request_cycle[block+1], release_cycle[block]);
        errors++;
      end
    end
    $display("OVERLAP_TIMING render_max=%0d release_max=%0d initiation_max=%0d first_drain_hidden=%0d",
             max_render_cycles, max_release_cycles, max_initiation_cycles,
             release_cycle[0] - request_cycle[1]);
    $display("RTL_OVERLAP_METRICS release_total=%0d release_max=%0d initiation_max=%0d release_utilization_ppm=%0d",
             overlap_total_release_cycles, overlap_max_release_cycles,
             overlap_max_initiation_cycles,
             overlap_max_release_utilization_ppm);

    if (errors != 0)
      $fatal(1, "FAIL: voice-major RTL effects harness errors=%0d", errors);
    $display("PASS: voice-major RTL effects harness block drain and lookahead");
    $finish;
  end

  initial begin
    repeat (500000) @(posedge core_clk);
    $fatal(1, "effects overlap testbench timeout renderer=%0d blocks=%0d outputs=%0d manager_state=%0d active=%0b base_complete=%0b",
           renderer_completions, block_completions, output_frames,
           dut.manager.output_state_q,
           dut.manager.render_request_active_q,
           dut.base_block_complete_valid);
  end
endmodule
