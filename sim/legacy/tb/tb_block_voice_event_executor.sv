`timescale 1ns/1ps

module tb_block_voice_event_executor;
  import synth_pkg::*;

  localparam int TEST_VOICE = (NUM_VOICES > 300) ? 300 : (NUM_VOICES - 1);

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic event_valid;
  logic event_ready;
  block_voice_event_t event_in;
  logic boundary_open;
  logic [TIMELINE_FRAME_WIDTH-1:0] boundary_frame;
  logic install_valid;
  logic install_ready;
  logic [VOICE_ID_WIDTH-1:0] install_voice;
  block_voice_state_snapshot_t install_state;
  logic control_event_valid;
  logic control_event_ready;
  block_voice_event_t control_event;
  logic control_event_done_pulse;
  logic stale_control_event_pulse;
  logic result_valid;
  logic result_ready;
  block_voice_event_result_t result;
  logic late_event_sticky;

  logic render_busy;
  logic params_write_valid;
  logic params_write_ready;
  logic [VOICE_ID_WIDTH-1:0] params_write_voice;
  logic [VOICE_GENERATION_WIDTH-1:0] params_write_generation;
  voice_event_params_t params_write_event;
  volume_env_params_t params_write_env;
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
  logic [NUM_VOICES-1:0] active_bitmap;
  logic stale_params_write_pulse;
  logic stale_dynamic_write_pulse;

  always #5 clk = ~clk;
  assign render_busy = !boundary_open;

  block_voice_event_executor executor (
    .clk, .rst, .event_valid, .event_ready, .event_in, .boundary_open,
    .boundary_frame, .install_valid, .install_ready, .install_voice,
    .install_state, .control_event_valid, .control_event_ready,
    .control_event, .control_event_done_pulse, .stale_control_event_pulse,
    .result_valid, .result_ready, .result, .late_event_sticky
  );

  block_voice_state_store store (
    .clk, .rst, .render_busy, .install_valid, .install_ready, .install_voice,
    .install_state, .params_write_valid, .params_write_ready,
    .params_write_voice, .params_write_generation, .params_write_event,
    .params_write_env, .control_event_valid, .control_event_ready,
    .control_event, .control_event_done_pulse, .stale_control_event_pulse,
    .state_read_req_valid, .state_read_req_ready, .state_read_req_voice,
    .state_read_rsp_valid, .state_read_rsp_ready, .state_read_rsp,
    .dynamic_write_valid, .dynamic_write_ready, .dynamic_write_voice,
    .dynamic_write_data, .active_bitmap, .stale_params_write_pulse,
    .stale_dynamic_write_pulse
  );

  task automatic submit_event(
      input block_voice_event_t value,
      input block_voice_event_status_t expected_status);
    begin
      @(negedge clk);
      event_in = value;
      event_valid = 1'b1;
      do @(posedge clk); while (!event_ready);
      @(negedge clk);
      event_valid = 1'b0;
      do @(posedge clk); while (!result_valid);
      if (result.status != expected_status ||
          result.host_voice_id != value.host_voice_id ||
          result.kind != value.kind)
        $fatal(1, "event result mismatch");
      @(negedge clk);
      result_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      result_ready = 1'b0;
    end
  endtask

  task automatic read_voice(
      input logic [VOICE_ID_WIDTH-1:0] voice,
      output block_voice_state_snapshot_t snapshot);
    begin
      @(negedge clk);
      boundary_open = 1'b0;
      state_read_req_voice = voice;
      state_read_req_valid = 1'b1;
      do @(posedge clk); while (!state_read_req_ready);
      @(negedge clk);
      state_read_req_valid = 1'b0;
      do @(posedge clk); while (!state_read_rsp_valid);
      snapshot = state_read_rsp;
      @(negedge clk);
      state_read_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      state_read_rsp_ready = 1'b0;
      boundary_open = 1'b1;
    end
  endtask

  initial begin
    block_voice_event_t command;
    block_voice_state_snapshot_t observed;

    event_valid = 1'b0;
    event_in = '0;
    boundary_open = 1'b1;
    boundary_frame = 32'd99;
    result_ready = 1'b0;
    params_write_valid = 1'b0;
    params_write_voice = '0;
    params_write_generation = '0;
    params_write_event = '0;
    params_write_env = '0;
    state_read_req_valid = 1'b0;
    state_read_req_voice = '0;
    state_read_rsp_ready = 1'b0;
    dynamic_write_valid = 1'b0;
    dynamic_write_voice = '0;
    dynamic_write_data = '0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    command = '0;
    command.target_frame = 32'd100;
    command.host_voice_id = 16'(TEST_VOICE);
    command.generation = 16'h1201;
    command.kind = BLOCK_VOICE_START;
    command.descriptor.region.base_addr = 32'h0012_0000;
    command.descriptor.region.length = 24'd4096;
    command.descriptor.region.loop_start = 24'd16;
    command.descriptor.region.loop_end = 24'd4000;
    command.descriptor.region.loop_mode = LOOP_MODE_CONTINUOUS;
    command.descriptor.phase_init = 32'h0000_0800;
    command.event_params.phase_inc = 32'h0000_0180;
    command.event_params.gain_l = 16'sh2000;
    command.event_params.gain_r = 16'sh3000;
    command.env_params.sustain_cb_q12_20 = 32'd200;
    command.start_env_state.stage = ENV_SUSTAIN;
    command.start_env_state.attenuation_cb_q12_20 = 32'd200;

    fork
      submit_event(command, BLOCK_EVENT_APPLIED);
      begin
        repeat (5) @(posedge clk);
        if (active_bitmap[TEST_VOICE]) $fatal(1, "future START applied early");
        @(negedge clk);
        boundary_frame = 32'd100;
      end
    join
    if (!active_bitmap[TEST_VOICE]) $fatal(1, "high voice START was not installed");

    command.kind = BLOCK_VOICE_GAIN;
    command.event_params.gain_l = 16'sh4100;
    command.event_params.gain_r = 16'sh4200;
    submit_event(command, BLOCK_EVENT_APPLIED);
    command.kind = BLOCK_VOICE_PITCH;
    command.event_params.phase_inc = 32'h0000_0250;
    submit_event(command, BLOCK_EVENT_APPLIED);
    read_voice(VOICE_ID_WIDTH'(TEST_VOICE), observed);
    if (observed.event_params.gain_l != 16'sh4100 ||
        observed.event_params.gain_r != 16'sh4200 ||
        observed.event_params.phase_inc != 32'h0000_0250)
      $fatal(1, "same-frame source order lost a runtime update");

    command.kind = BLOCK_VOICE_FILTER;
    command.generation = 16'h1200;
    command.event_params.filter_enable = 1'b1;
    submit_event(command, BLOCK_EVENT_STALE);
    read_voice(VOICE_ID_WIDTH'(TEST_VOICE), observed);
    if (observed.event_params.filter_enable)
      $fatal(1, "stale generation modified filter state");

    command.generation = 16'h1201;
    command.kind = BLOCK_VOICE_RELEASE;
    command.env_params.release_step_cb_q12_20 = 32'd17;
    submit_event(command, BLOCK_EVENT_APPLIED);
    read_voice(VOICE_ID_WIDTH'(TEST_VOICE), observed);
    if (!observed.event_params.released ||
        observed.env_params.release_step_cb_q12_20 != 32'd17 ||
        observed.dynamic.env_state.stage != ENV_RELEASE)
      $fatal(1, "RELEASE did not update owned state atomically");

    command.kind = BLOCK_VOICE_STOP;
    submit_event(command, BLOCK_EVENT_APPLIED);
    if (active_bitmap[TEST_VOICE]) $fatal(1, "STOP did not deactivate voice");

    command.kind = BLOCK_VOICE_START;
    command.generation = 16'h1202;
    command.target_frame = 32'd90;
    submit_event(command, BLOCK_EVENT_APPLIED);
    if (!late_event_sticky) $fatal(1, "late event status was not sticky");

    command.host_voice_id = 16'd700;
    command.target_frame = boundary_frame;
    submit_event(command, BLOCK_EVENT_BAD_VOICE);

    $display("PASS: timestamped block voice event execution");
    $finish;
  end

  initial begin
    repeat (4000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
