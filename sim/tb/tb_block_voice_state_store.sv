`timescale 1ns/1ps

module tb_block_voice_state_store;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic render_busy;
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
  logic control_event_valid;
/* verilator lint_off UNUSEDSIGNAL */
  // Runtime control-event signaling is connected but outside this bank test.
  logic control_event_ready;
  block_voice_event_t control_event;
  logic control_event_done_pulse;
  logic stale_control_event_pulse;
/* verilator lint_on UNUSEDSIGNAL */
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
  logic stale_params_write_pulse;
  logic stale_dynamic_write_pulse;
  logic completion_event_valid;
  logic [VOICE_ID_WIDTH-1:0] completion_event_voice;
  logic [VOICE_GENERATION_WIDTH-1:0] completion_event_generation;
  logic [1:0] completion_event_reason;
  logic [NUM_VOICES-1:0] voice_active_bitmap;
  logic [7:0] completion_count;
  logic [VOICE_ID_WIDTH-1:0] last_completion_voice;
  logic [VOICE_GENERATION_WIDTH-1:0] last_completion_generation;
  logic [1:0] last_completion_reason;

  always #5 clk <= ~clk;

  always_ff @(posedge clk) begin
    if (rst) begin
      completion_count <= '0;
      last_completion_voice <= '0;
      last_completion_generation <= '0;
      last_completion_reason <= '0;
    end else if (completion_event_valid) begin
      completion_count <= completion_count + 1'b1;
      last_completion_voice <= completion_event_voice;
      last_completion_generation <= completion_event_generation;
      last_completion_reason <= completion_event_reason;
    end
  end

  block_voice_state_store dut (.*);

  task automatic install_voice_state(
      input logic [VOICE_ID_WIDTH-1:0] voice,
      input block_voice_state_snapshot_t snapshot);
    begin
      @(negedge clk);
      install_voice = voice;
      install_state = snapshot;
      install_valid = 1'b1;
      do @(posedge clk); while (!install_ready);
      @(negedge clk);
      install_valid = 1'b0;
    end
  endtask

  task automatic write_params(
      input logic [VOICE_GENERATION_WIDTH-1:0] generation,
      input voice_event_params_t event_value,
      input volume_env_params_t env_value,
      input logic expect_stale);
    logic saw_stale;
    begin
      @(negedge clk);
      params_write_generation = generation;
      params_write_event = event_value;
      params_write_env = env_value;
      params_write_valid = 1'b1;
      do @(posedge clk); while (!params_write_ready);
      @(negedge clk);
      params_write_valid = 1'b0;
      saw_stale = 1'b0;
      repeat (4) begin
        @(negedge clk);
        saw_stale |= stale_params_write_pulse;
      end
      if (saw_stale != expect_stale)
        $fatal(1, "parameter stale result mismatch");
    end
  endtask

  task automatic read_state(output block_voice_state_snapshot_t value);
    block_voice_state_snapshot_t held;
    begin
      @(negedge clk);
      state_read_req_valid = 1'b1;
      do @(posedge clk); while (!state_read_req_ready);
      @(negedge clk);
      state_read_req_valid = 1'b0;
      do @(posedge clk); while (!state_read_rsp_valid);
      held = state_read_rsp;
      @(posedge clk);
      if (!state_read_rsp_valid || state_read_rsp != held)
        $fatal(1, "state response changed under backpressure");
      value = state_read_rsp;
      @(negedge clk);
      state_read_rsp_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      state_read_rsp_ready = 1'b0;
    end
  endtask

  task automatic write_dynamic(
      input voice_dynamic_state_t value,
      input logic expect_stale);
    logic saw_stale;
    begin
      @(negedge clk);
      dynamic_write_data = value;
      dynamic_write_valid = 1'b1;
      do @(posedge clk); while (!dynamic_write_ready);
      @(negedge clk);
      dynamic_write_valid = 1'b0;
      saw_stale = 1'b0;
      repeat (4) begin
        @(negedge clk);
        saw_stale |= stale_dynamic_write_pulse;
      end
      if (saw_stale != expect_stale)
        $fatal(1, "dynamic stale result mismatch");
    end
  endtask

  task automatic send_control(
      input block_voice_event_kind_t kind,
      input logic [31:0] release_step);
    begin
      @(negedge clk);
      control_event = '0;
      control_event.kind = kind;
      control_event.host_voice_id = 16'd7;
      control_event.generation = 16'h0052;
      control_event.env_params.release_step_cb_q12_20 = release_step;
      control_event_valid = 1'b1;
      do @(posedge clk); while (!control_event_ready);
      @(negedge clk);
      control_event_valid = 1'b0;
      do @(negedge clk); while (!control_event_done_pulse);
      @(negedge clk);
    end
  endtask

  initial begin
    block_voice_state_snapshot_t initial_state;
    block_voice_state_snapshot_t observed;
    voice_event_params_t changed_event;
    volume_env_params_t changed_env;
    voice_dynamic_state_t changed_dynamic;

    render_busy = 1'b0;
    install_valid = 1'b0;
    install_voice = VOICE_ID_WIDTH'(7);
    install_state = '0;
    params_write_valid = 1'b0;
    params_write_voice = VOICE_ID_WIDTH'(7);
    params_write_generation = '0;
    params_write_event = '0;
    params_write_env = '0;
    control_event_valid = 1'b0;
    control_event = '0;
    state_read_req_valid = 1'b0;
    state_read_req_voice = VOICE_ID_WIDTH'(7);
    state_read_rsp_ready = 1'b0;
    dynamic_write_valid = 1'b0;
    dynamic_write_voice = VOICE_ID_WIDTH'(7);
    dynamic_write_data = '0;

    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    initial_state = '0;
    initial_state.region.base_addr = 32'h0010_0000;
    initial_state.region.length = 24'd200;
    initial_state.event_params.phase_inc = 32'h0000_0180;
    initial_state.event_params.gain_l = 16'sh4000;
    initial_state.event_params.gain_r = 16'sh2000;
    initial_state.env_params.delay_samples = 24'd3;
    initial_state.dynamic.active = 1'b1;
    initial_state.dynamic.generation = 16'h0052;
    initial_state.dynamic.phase = 32'h0000_0400;
    initial_state.dynamic.env_state.stage = ENV_DELAY;
    install_voice_state(VOICE_ID_WIDTH'(7), initial_state);
    if (!voice_active_bitmap[7])
      $fatal(1, "installed voice was absent from active bitmap");

    changed_event = initial_state.event_params;
    changed_event.gain_l = 16'sh6000;
    changed_env = initial_state.env_params;
    changed_env.delay_samples = 24'd5;
    write_params(16'h0051, changed_event, changed_env, 1'b1);
    write_params(16'h0052, changed_event, changed_env, 1'b0);

    render_busy = 1'b1;
    @(posedge clk);
    if (install_ready || params_write_ready)
      $fatal(1, "host writes were not blocked during render");
    read_state(observed);
    if (observed.region != initial_state.region ||
        observed.event_params != changed_event ||
        observed.env_params != changed_env ||
        observed.dynamic != initial_state.dynamic)
      $fatal(1, "state banks did not preserve ownership");

    changed_dynamic = initial_state.dynamic;
    changed_dynamic.generation = 16'h0051;
    changed_dynamic.phase = 32'h0000_0900;
    write_dynamic(changed_dynamic, 1'b1);
    if (completion_count != 0)
      $fatal(1, "stale dynamic write emitted a completion");
    read_state(observed);
    if (!observed.dynamic.active ||
        observed.dynamic.generation != initial_state.dynamic.generation)
      $fatal(1, "stale write changed dynamic state");

    changed_dynamic.generation = 16'h0052;
    changed_dynamic.active = 1'b0;
    write_dynamic(changed_dynamic, 1'b0);
    if (voice_active_bitmap[7])
      $fatal(1, "renderer completion did not clear active bitmap");
    if (completion_count != 1 || last_completion_voice != 7 ||
        last_completion_generation != 16'h0052 ||
        last_completion_reason != 2'd0)
      $fatal(1, "renderer completion event mismatch");
    read_state(observed);
    if (observed.dynamic.active)
      $fatal(1, "renderer completion did not remove inactive voice");

    render_busy = 1'b0;
    @(posedge clk);
    if (!install_ready || !params_write_ready)
      $fatal(1, "host writes did not reopen after render");

    // A render-session reset invalidates every slot without requiring the
    // state RAM contents themselves to be synchronously cleared.
    install_voice_state(VOICE_ID_WIDTH'(7), initial_state);
    @(negedge clk);
    rst = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    if (|voice_active_bitmap)
      $fatal(1, "reset did not clear active bitmap");
    render_busy = 1'b1;
    read_state(observed);
    if (observed.dynamic.active)
      $fatal(1, "reset allowed an installed voice to become active again");
    changed_dynamic = initial_state.dynamic;
    changed_dynamic.phase = 32'h0000_0a00;
    write_dynamic(changed_dynamic, 1'b1);

    render_busy = 1'b0;
    install_voice_state(VOICE_ID_WIDTH'(7), initial_state);
    render_busy = 1'b1;
    read_state(observed);
    if (!observed.dynamic.active ||
        observed.dynamic.generation != initial_state.dynamic.generation)
      $fatal(1, "post-reset install did not reactivate voice slot");

    render_busy = 1'b0;
    send_control(BLOCK_VOICE_RELEASE, 32'd7);
    if (!voice_active_bitmap[7])
      $fatal(1, "nonzero RELEASE cleared active bitmap early");
    send_control(BLOCK_VOICE_STOP, 32'd0);
    if (voice_active_bitmap[7])
      $fatal(1, "STOP did not clear active bitmap");
    if (completion_count != 1 || last_completion_voice != 7 ||
        last_completion_generation != 16'h0052 ||
        last_completion_reason != 2'd1)
      $fatal(1, "STOP completion event mismatch");

    install_voice_state(VOICE_ID_WIDTH'(7), initial_state);
    send_control(BLOCK_VOICE_RELEASE, 32'd0);
    if (voice_active_bitmap[7])
      $fatal(1, "zero-step RELEASE did not clear active bitmap");
    if (completion_count != 2 || last_completion_voice != 7 ||
        last_completion_generation != 16'h0052 ||
        last_completion_reason != 2'd2)
      $fatal(1, "zero-step RELEASE completion event mismatch");

    $display("PASS: block voice state banks and generation arbitration");
    $finish;
  end

  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "testbench timeout");
  end
endmodule
