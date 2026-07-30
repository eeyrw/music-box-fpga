`timescale 1ns/1ps

module tb_voice_major_render_effects_harness;
  import synth_pkg::*;

  logic core_clk = 1'b0;
  logic ddr_clk = 1'b0;
  logic rst;
  logic cmd_stream_valid;
  logic cmd_stream_ready;
  logic [31:0] cmd_stream_data;
  logic block_req_valid;
  logic block_req_ready;
  logic [31:0] block_start_frame;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] block_frame_count;
  logic renderer_complete_valid;
  logic block_complete_valid;
  logic block_complete_ready;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] block_complete_buffer;
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
  logic [63:0] ddr_accepted;
  logic [63:0] ddr_returned;
  logic [31:0] configured_max_block_frames;
  int renderer_completions = 0;
  int block_completions = 0;
  int output_frames = 0;
  int errors = 0;

  always #16 core_clk = ~core_clk;
  always #4 ddr_clk = ~ddr_clk;

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
    .cache_requests(),
    .cache_hits(),
    .cache_mshr_merges(),
    .cache_misses(),
    .cache_evictions(),
    .cache_miss_stall_cycles(),
    .window_refills(),
    .window_fallback_reads(),
    .configured_cache_sets(),
    .configured_cache_bytes(),
    .configured_window_words(),
    .configured_max_block_frames,
    .active_voice_count(),
    .debug_plan_valid(),
    .debug_plan_voice(),
    .debug_plan_first(),
    .debug_plan_last(),
    .debug_plan_addr_0(),
    .debug_plan_addr_1()
  );

  always @(posedge core_clk) begin
    if (renderer_complete_valid)
      renderer_completions++;
    if (block_complete_valid && block_complete_ready)
      block_completions++;
    if (effect_output_valid && effect_output_ready) begin
      output_frames++;
      if (effect_output_l != 0 || effect_output_r != 0) begin
        $error("disabled effects changed a silent frame");
        errors++;
      end
    end
  end

  task automatic submit_block(input int start_frame);
    begin
      @(negedge core_clk);
      block_start_frame = start_frame;
      block_frame_count = BLOCK_FRAME_COUNT_WIDTH'(16);
      block_req_valid = 1'b1;
      do @(posedge core_clk); while (!block_req_ready);
      @(negedge core_clk);
      block_req_valid = 1'b0;
      while (!block_complete_valid) @(negedge core_clk);
      if (block_complete_start_frame != 32'(start_frame) ||
          block_complete_frame_count != BLOCK_FRAME_COUNT_WIDTH'(16)) begin
        $display("block completion metadata mismatch got=%0d/%0d expected=%0d/16",
                 block_complete_start_frame, block_complete_frame_count,
                 start_frame);
        errors++;
      end
      while (block_complete_valid) @(negedge core_clk);
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

    for (int block = 0; block < 4; block++)
      submit_block(block * 16);
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
        configured_max_block_frames != 32'd16 || ddr_accepted != 0 ||
        ddr_returned != 0) begin
      $error("effects harness accounting mismatch renderer=%0d blocks=%0d outputs=%0d inputs=%0d rtl_outputs=%0d max_cycles=%0d",
             renderer_completions, block_completions, output_frames,
             effects_input_frame_count, effects_output_frame_count,
             effects_max_processing_cycles);
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: voice-major RTL effects harness errors=%0d", errors);
    $display("PASS: voice-major RTL effects harness block drain and lookahead");
    $finish;
  end
endmodule
