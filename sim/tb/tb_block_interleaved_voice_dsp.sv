`timescale 1ns/1ps

module tb_block_interleaved_voice_dsp;
  import synth_pkg::*;

  localparam int BLOCK_WORK_ID_WIDTH = $clog2(BLOCK_WORK_ENTRY_COUNT);

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic token_valid;
  logic token_ready;
  block_dsp_sample_token_t token;
  logic state_update_valid;
  block_dsp_state_update_t state_update;
  logic retire_valid;
  logic retire_ready;
  block_dsp_retire_t retire;

  logic update_seen [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic signed [FILTER_STATE_WIDTH-1:0] update_z1
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic signed [FILTER_STATE_WIDTH-1:0] update_z2
      [0:BLOCK_WORK_ENTRY_COUNT-1];

  always #5 clk <= ~clk;

  block_interleaved_voice_dsp dut (
    .clk,
    .rst,
    .token_valid,
    .token_ready,
    .token,
    .state_update_valid,
    .state_update,
    .retire_valid,
    .retire_ready,
    .retire
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int entry = 0; entry < BLOCK_WORK_ENTRY_COUNT; entry++) begin
        update_seen[entry] <= 1'b0;
        update_z1[entry] <= '0;
        update_z2[entry] <= '0;
      end
    end else if (state_update_valid) begin
      update_seen[state_update.work_id] <= 1'b1;
      update_z1[state_update.work_id] <= state_update.filter_z1;
      update_z2[state_update.work_id] <= state_update.filter_z2;
    end
  end

  task automatic send_token(input block_dsp_sample_token_t value);
    begin
      @(negedge clk);
      token = value;
      token_valid = 1'b1;
      do @(posedge clk); while (!token_ready);
      @(negedge clk);
      token_valid = 1'b0;
    end
  endtask

  task automatic retire_expect(
      input logic [BLOCK_WORK_ID_WIDTH-1:0] expected_work_id,
      input logic expected_last,
      input logic [VOICE_ID_WIDTH-1:0] expected_voice,
      input logic [BLOCK_FRAME_INDEX_WIDTH-1:0] expected_frame,
      input logic signed [15:0] expected_l,
      input logic signed [15:0] expected_r,
      input logic signed [FILTER_STATE_WIDTH-1:0] expected_z1,
      input logic signed [FILTER_STATE_WIDTH-1:0] expected_z2,
      input logic hold_first);
    block_dsp_retire_t held;
    begin
      do @(posedge clk); while (!retire_valid);
      held = retire;
      if (hold_first) begin
        repeat (2) begin
          @(posedge clk);
          if (!retire_valid || retire != held)
            $fatal(1, "interleaved DSP retire changed under backpressure");
        end
      end
      if (retire.work_id != expected_work_id ||
          retire.last != expected_last ||
          retire.contribution.voice_index != expected_voice ||
          retire.contribution.block_frame_index != expected_frame ||
          $signed(retire.contribution.contribution_l) != expected_l ||
          $signed(retire.contribution.contribution_r) != expected_r ||
          $signed(retire.filter_z1) != expected_z1 ||
          $signed(retire.filter_z2) != expected_z2) begin
        $fatal(1,
               "retire mismatch work=%0d voice=%0d frame=%0d l=%0d r=%0d z1=%0d z2=%0d",
               retire.work_id, retire.contribution.voice_index,
               retire.contribution.block_frame_index,
               $signed(retire.contribution.contribution_l),
               $signed(retire.contribution.contribution_r),
               $signed(retire.filter_z1), $signed(retire.filter_z2));
      end
      @(negedge clk);
      retire_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      retire_ready = 1'b0;
    end
  endtask

  function automatic block_dsp_sample_token_t make_token(
      input int work_id,
      input logic [VOICE_ID_WIDTH-1:0] voice_id,
      input logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index,
      input logic filter_enable,
      input logic last,
      input logic signed [15:0] sample_0,
      input logic signed [15:0] sample_1,
      input logic [7:0] fraction,
      input logic signed [FILTER_STATE_WIDTH-1:0] z1,
      input logic signed [FILTER_STATE_WIDTH-1:0] z2);
    block_dsp_sample_token_t value;
    begin
      value = '0;
      value.work_id = BLOCK_WORK_ID_WIDTH'(work_id);
      value.last = last;
      value.voice_context.generation = 16'h0033;
      value.voice_context.voice_index = VOICE_ID_WIDTH'(voice_id);
      value.voice_context.gain_l = 16'sh7fff;
      value.voice_context.gain_r = (work_id == 0) ? 16'sh4000 : 16'sh7fff;
      value.voice_context.filter_enable = filter_enable;
      value.voice_context.filter_b0 = 16'sh2000;
      value.voice_context.filter_b1 = 16'sh1000;
      value.voice_context.filter_b2 = '0;
      value.voice_context.filter_a1 = '0;
      value.voice_context.filter_a2 = '0;
      value.sample.job.block_frame_index = BLOCK_FRAME_INDEX_WIDTH'(frame_index);
      value.sample.job.fraction = fraction;
      value.sample.job.envelope_level = 16'sh7fff;
      value.sample.sample_0 = sample_0;
      value.sample.sample_1 = sample_1;
      value.filter_z1 = z1;
      value.filter_z2 = z2;
      make_token = value;
    end
  endfunction

  initial begin
    block_dsp_sample_token_t value;

    token_valid = 1'b0;
    token = '0;
    retire_ready = 1'b0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // Two independent voices enter on consecutive clocks. Work 1 uses the
    // recursive filter while work 0 proves unrelated work can enter without
    // waiting for a per-voice FSM.
    value = make_token(0, 9, 0, 1'b0, 1'b1,
                       16'sd1000, 16'sd2000, 8'h80, '0, '0);
    send_token(value);
    value = make_token(1, 10, 1, 1'b1, 1'b0,
                       16'sd1000, 16'sd1000, '0, '0, '0);
    send_token(value);
    retire_expect(0, 1'b1, 9, 0, 16'sd1499, 16'sd750, '0, '0, 1'b1);
    retire_expect(1, 1'b0, 10, 1, 16'sd499, 16'sd499,
                  FILTER_STATE_WIDTH'(4096000), '0, 1'b0);
    if (!update_seen[1] || $signed(update_z1[1]) != 4096000 ||
        $signed(update_z2[1]) != 0)
      $fatal(1, "filtered state feedback was not tagged to work entry 1");

    value = make_token(1, 10, 2, 1'b1, 1'b1,
                       16'sd1000, 16'sd1000, '0,
                       update_z1[1], update_z2[1]);
    send_token(value);
    retire_expect(1, 1'b1, 10, 2, 16'sd749, 16'sd749,
                  FILTER_STATE_WIDTH'(4096000), '0, 1'b0);

    $display("PASS: tagged interleaved voice DSP, feedback, and backpressure");
    $finish;
  end

  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
