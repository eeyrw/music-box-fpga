module tb_transactional_control_plane;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic word_push;
  logic [31:0] word_push_data;
  logic word_push_ready;
  logic frame_request;
  logic frame_start;
  logic control_busy;
  logic [$clog2(65)-1:0] word_level;
  logic [$clog2(33)-1:0] action_level;
  logic [31:0] command_error_count;
  logic [31:0] stale_seq_count;
  logic [VOICE_ID_WIDTH-1:0] render_voice_index;
  logic snapshot_prepare;
  logic [VOICE_ID_WIDTH-1:0] snapshot_voice;
  logic snapshot_valid;
  logic debug_read_select;
  logic [VOICE_ID_WIDTH-1:0] debug_read_voice;
  logic [7:0] debug_prepared_seq;
  active_voice_t debug_active;
  voice_config_t render_config;
  voice_runtime_t render_runtime;
  global_audio_config_t audio_config;
  logic [1:0] effect_clear;
  logic [NUM_VOICES-1:0] config_valid;
  logic [NUM_VOICES-1:0] commit_pulse;
  logic [NUM_VOICES-1:0] prepared_valid;
  logic saw_commit_voice3;
  int effect_clear_pulse_count;
  int errors = 0;

  always #5 clk <= ~clk;

  transactional_control_plane #(
    .WORD_FIFO_DEPTH(64),
    .ACTION_FIFO_DEPTH(32),
    .MAX_ACTION_BATCH(16)
  ) dut (.*);

  always_ff @(posedge clk) begin
    if (rst) begin
      saw_commit_voice3 <= 1'b0;
      effect_clear_pulse_count <= 0;
    end else begin
      if (effect_clear != 0)
        effect_clear_pulse_count <= effect_clear_pulse_count + 1;
      if (commit_pulse[3])
      saw_commit_voice3 <= 1'b1;
    end
  end

  function automatic logic [31:0] header(
    input logic [7:0] opcode,
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic [7:0] words
  );
    header = {opcode, voice, seq, words};
  endfunction

  task automatic push_word(input logic [31:0] data);
    begin
      @(negedge clk);
      while (!word_push_ready) @(negedge clk);
      word_push_data = data;
      word_push = 1'b1;
      @(negedge clk);
      word_push = 1'b0;
    end
  endtask

  task automatic push_define_mono(input logic [7:0] voice, input logic [7:0] seq);
    begin
      push_word(header(VOICE_DEFINE_MONO, voice, seq, 8'd11));
      push_word(32'h0010_0000 + 32'(voice));
      push_word(32'd64);
      push_word(32'd8);
      push_word(32'd56);
      push_word(32'h0000_0200);
      push_word({30'd0, LOOP_MODE_CONTINUOUS});
      push_word(32'h0000_4000);
      push_word(32'h0000_0000);
      push_word(32'h0000_0000);
      push_word(32'd0);
      push_word(32'd0);
    end
  endtask

  task automatic push_start(input logic [7:0] voice, input logic [7:0] seq);
    begin
      push_word(header(VOICE_START, voice, seq, 8'd8));
      push_word(32'h2000_3000);
      push_word(32'h0000_0180);
      push_word(32'd0);
      push_word(32'h4000_0000);
      push_word(32'd1);
      push_word(32'h1000_0000);
      push_word(32'h2000_0000);
      push_word(32'h1000_0000);
    end
  endtask

  task automatic push_gain_phase(input logic [7:0] seq);
    begin
      push_word(header(VOICE_GAIN_PHASE, 8'd3, seq, 8'd2));
      push_word(32'h1111_2222);
      push_word(32'h0000_0240);
    end
  endtask

  task automatic push_env_update(
    input logic [7:0] seq,
    input logic [31:0] mask,
    input logic [31:0] value
  );
    begin
      push_word(header(VOICE_ENV_UPDATE, 8'd3, seq, 8'd2));
      push_word(mask);
      push_word(value);
    end
  endtask

  task automatic request_frame;
    begin
      @(negedge clk);
      frame_request = 1'b1;
      @(negedge clk);
      frame_request = 1'b0;
      wait (frame_start);
      @(negedge clk);
    end
  endtask

  task automatic wait_actions(input int expected);
    int timeout;
    begin
      timeout = 0;
      while ((int'(action_level) < expected) && (timeout < 3000)) begin
        @(negedge clk);
        timeout++;
      end
      if (int'(action_level) < expected) begin
        $error("action FIFO timeout: got %0d expected %0d", action_level, expected);
        errors++;
      end
    end
  endtask

  task automatic select_voice(input logic [VOICE_ID_WIDTH-1:0] voice);
    begin
      render_voice_index = voice;
      snapshot_voice = voice;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic snapshot_voice_once;
    begin
      @(negedge clk);
      snapshot_prepare = 1'b1;
      @(negedge clk);
      snapshot_prepare = 1'b0;
      while (!snapshot_valid) @(negedge clk);
      @(negedge clk);
    end
  endtask

  initial begin
    rst = 1'b1;
    word_push = 1'b0;
    word_push_data = '0;
    frame_request = 1'b0;
    render_voice_index = '0;
    snapshot_prepare = 1'b0;
    snapshot_voice = '0;
    debug_read_select = 1'b0;
    debug_read_voice = '0;
    repeat (4) @(negedge clk);
    rst = 1'b0;

    push_word(header(COMPRESSOR_CONFIG, 8'd0, 8'd0, 8'd4));
    push_word(32'h0001_0001);
    push_word(32'd120 << 20);
    push_word(32'd4 << 20);
    push_word(32'd1 << 20);
    wait_actions(1);
    request_frame();
    if (!audio_config.compressor.enable ||
        audio_config.compressor.threshold_cb_q12_20 != (32'd120 << 20) ||
        audio_config.compressor.ratio_slope_q0_16 != 16'h8000 ||
        audio_config.compressor.attack_step_cb_q12_20 != (32'd4 << 20) ||
        audio_config.compressor.release_step_cb_q12_20 != (32'd1 << 20)) begin
      $error("compressor config action did not commit atomically");
      errors++;
    end
    push_word(header(MASTER_VOLUME, 8'd0, 8'd0, 8'd1));
    push_word(32'h0000_4000);
    wait_actions(1);
    request_frame();
    if (audio_config.master_volume != 16'sh4000) begin
      $error("master volume action mismatch: %h", audio_config.master_volume);
      errors++;
    end

    push_word(header(CHORUS_CONFIG, 8'd0, 8'd0, 8'd6));
    push_word(32'hf000_0001);
    push_word(32'd3072);
    push_word(32'd768);
    push_word(32'h1234_5678);
    push_word(32'h2000_6000);
    push_word(32'h4000_0000);
    push_word(header(REVERB_CONFIG, 8'd0, 8'd0, 8'd9));
    push_word(32'd35);
    push_word(32'h0000_3000);
    push_word(32'h0000_2000);
    push_word(32'h0000_1000);
    push_word(32'h0000_0800);
    push_word(32'h0002_0001);
    push_word(32'h0004_0003);
    push_word(32'h0006_0005);
    push_word(32'h0008_0007);
    push_word(header(EFFECT_CLEAR, 8'd0, 8'd0, 8'd1));
    push_word(32'd3);
    wait_actions(3);
    request_frame();
    if (!audio_config.chorus.enable ||
        audio_config.chorus.feedback_q1_15 != -16'sh1000 ||
        audio_config.chorus.base_delay_q16_8 != 24'd3072 ||
        audio_config.chorus.return_gain_q1_15 != 16'h2000 ||
        !audio_config.reverb.enable ||
        audio_config.reverb.pre_delay_frames != 11'd17 ||
        audio_config.reverb.feedback_gain_q1_15[7] != 16'd8 ||
        effect_clear_pulse_count != 1 || effect_clear != 0) begin
      $error("effect global actions did not commit atomically");
      errors++;
    end

    push_define_mono(8'd3, 8'h21);
    wait_actions(1);
    request_frame();
    if (!prepared_valid[3] || config_valid[3]) begin
      $error("DEFINE did not remain isolated from active state");
      errors++;
    end

    push_start(8'd3, 8'h20);
    wait_actions(1);
    request_frame();
    if (stale_seq_count != 32'd1 || config_valid[3]) begin
      $error("stale START was not rejected");
      errors++;
    end

    push_start(8'd3, 8'h21);
    wait_actions(1);
    request_frame();
    select_voice(3);
    if (!config_valid[3] || !debug_active.audible ||
        debug_active.voice.base_addr != 32'h0010_0003 ||
        debug_active.phase_inc != 32'h0000_0180 ||
        debug_active.gain_l != 16'sh3000 || debug_active.gain_r != 16'sh2000) begin
      $error("matching START did not atomically promote prepared state: valid=%0b audible=%0b base=%h phase_inc=%h gain_l=%h gain_r=%h",
             config_valid[3], debug_active.audible, debug_active.voice.base_addr,
             debug_active.phase_inc, debug_active.gain_l, debug_active.gain_r);
      errors++;
    end
    if (!saw_commit_voice3) begin
      $error("START did not generate frame commit pulse");
      errors++;
    end

    snapshot_voice_once();
    if (render_runtime.envelope_level != 16'sh2000) begin
      $error("first attack sample mismatch: %h", render_runtime.envelope_level);
      errors++;
    end
    snapshot_voice_once();
    if (render_runtime.envelope_level != 16'sh4000) begin
      $error("second attack sample mismatch: %h", render_runtime.envelope_level);
      errors++;
    end

    push_gain_phase(8'h20);
    wait_actions(1);
    request_frame();
    if (stale_seq_count != 32'd2) begin
      $error("stale runtime action was not rejected");
      errors++;
    end

    push_gain_phase(8'h21);
    wait_actions(1);
    request_frame();
    select_voice(3);
    if (debug_active.gain_l != 16'sh2222 || debug_active.gain_r != 16'sh1111 ||
        debug_active.phase_inc != 32'h0000_0240) begin
      $error("GAIN_PHASE update mismatch");
      errors++;
    end

    push_word(header(VOICE_RELEASE, 8'd3, 8'h21, 8'd1));
    push_word(32'h3c00_0000);
    wait_actions(1);
    request_frame();
    select_voice(3);
    if (debug_active.env_state.attenuation_cb_q12_20 != 32'd62424477) begin
      $error("attack-to-release attenuation mismatch: %0d",
             debug_active.env_state.attenuation_cb_q12_20);
      errors++;
    end
    snapshot_voice_once();
    snapshot_voice_once();
    if (config_valid[3] || render_config.enable || render_runtime.envelope_level != 0) begin
      $error("release did not reach silence and clear audibility");
      errors++;
    end

    push_start(8'd3, 8'h21);
    wait_actions(1);
    request_frame();
    push_env_update(8'h21, 32'h0000_0002, 32'h8000_0000);
    wait_actions(1);
    request_frame();
    snapshot_voice_once();
    if (render_runtime.envelope_level != 16'sh4000) begin
      $error("ENV_UPDATE did not replace the active attack step");
      errors++;
    end

    push_env_update(8'h21, 32'h0000_0001, 32'hff00_0001);
    wait_actions(1);
    request_frame();
    if (command_error_count != 1) begin
      $error("ENV_UPDATE accepted reserved duration bits");
      errors++;
    end

    snapshot_voice_once();
    snapshot_voice_once();
    snapshot_voice_once();
    if (render_runtime.envelope_level != 16'sh06bb) begin
      $error("range-reduced 256 cB envelope gain mismatch: %h",
             render_runtime.envelope_level);
      errors++;
    end

    push_word(header(VOICE_RELEASE, 8'd3, 8'h21, 8'd1));
    push_word(32'd0);
    wait_actions(1);
    request_frame();
    select_voice(3);
    if (config_valid[3] || debug_active.audible) begin
      $error("zero-step RELEASE did not stop immediately");
      errors++;
    end

    for (int voice = 16; voice < 33; voice++)
      push_define_mono(8'(voice), 8'(voice));
    wait_actions(17);
    request_frame();
    for (int voice = 16; voice < 32; voice++) begin
      if (!prepared_valid[voice]) begin
        $error("batched DEFINE missing voice %0d", voice);
        errors++;
      end
    end
    if (prepared_valid[32] || action_level != 1) begin
      $error("MAX_ACTION_BATCH did not leave the 17th action queued");
      errors++;
    end
    request_frame();
    if (!prepared_valid[32] || action_level != 0) begin
      $error("second frame did not consume remaining action");
      errors++;
    end

    if (command_error_count != 1) begin
      $error("unexpected command errors: %0d", command_error_count);
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: transactional control plane errors=%0d", errors);
    $display("PASS: transactional control plane");
    $finish;
  end
endmodule
