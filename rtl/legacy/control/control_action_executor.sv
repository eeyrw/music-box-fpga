module control_action_executor (
  input  logic clk,
  input  logic rst,
  input  logic frame_start,
  input  logic action_valid,
  output logic action_ready,
  input  synth_pkg::control_action_t action,
  output logic action_done,
  output logic stream_flush,
  output logic command_error_pulse,
  output logic stale_seq_pulse,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] render_voice_index,
  input  logic snapshot_prepare,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] snapshot_voice,
  output logic snapshot_valid,
  input  logic debug_read_select,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] debug_read_voice,
  output logic [7:0] debug_prepared_seq,
  output synth_pkg::active_voice_t debug_active,
  output synth_pkg::voice_config_t render_config,
  output synth_pkg::voice_runtime_t render_runtime,
  output synth_pkg::global_audio_config_t audio_config,
  output logic [1:0] effect_clear,
  output logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0] commit_pulse,
  output logic [synth_pkg::NUM_VOICES-1:0] prepared_valid
);
  import synth_pkg::*;
  import synth_dsp_lut_pkg::*;

  localparam int PREPARED_WIDTH = $bits(prepared_voice_t);
  localparam int ACTIVE_WIDTH = $bits(active_voice_t);

  typedef enum logic [2:0] {
    EXEC_IDLE, EXEC_DEFINE, EXEC_READ, EXEC_RELEASE_INDEX, EXEC_RELEASE_VALUE,
    EXEC_APPLY, EXEC_COMMIT
  } exec_state_t;
  exec_state_t state;
  // Voice is retained separately for the RAM address; payload_words was
  // already validated by the parser before this action is latched.
/* verilator lint_off UNUSEDSIGNAL */
  control_action_t current_action;
/* verilator lint_on UNUSEDSIGNAL */
  logic [VOICE_ID_WIDTH-1:0] action_voice;
  logic [VOICE_ID_WIDTH-1:0] prepared_read_voice;
  logic [VOICE_ID_WIDTH-1:0] active_read_voice;
  logic [PREPARED_WIDTH-1:0] prepared_read_word;
  logic [ACTIVE_WIDTH-1:0] active_read_word;
  prepared_voice_t prepared_read_data;
  active_voice_t active_read_data;
  prepared_voice_t prepared_action_data_q;
  active_voice_t active_action_data_q;
  prepared_voice_t define_data;
  active_voice_t action_next_data;
  active_voice_t envelope_next_data;
  logic define_valid;
  logic action_semantic_valid;
  logic prepared_write;
  logic active_envelope_write;
  logic snapshot_accept;
  logic active_write_q;
  logic [VOICE_ID_WIDTH-1:0] active_write_voice_q;
  active_voice_t active_write_data_q;
  logic [NUM_VOICES-1:0] active_valid;
  logic [NUM_VOICES-1:0] pending_commit;
  logic action_seq_match;
  logic env_update_payload_valid;
  integer env_update_payload_index;
  logic snapshot_stage0_valid;
  active_voice_t snapshot_active_data_q;
  logic snapshot_active_valid_q;
  logic [VOICE_ID_WIDTH-1:0] snapshot_voice_q;
  logic snapshot_read_valid;
  logic [1:0] snapshot_stage0_kind;
  logic signed [15:0] snapshot_stage0_direct_level;
  logic [31:0] snapshot_stage0_attenuation;
  logic snapshot_stage1_valid;
  logic [1:0] snapshot_stage1_kind;
  logic signed [15:0] snapshot_stage1_direct_level;
  logic [4:0] snapshot_stage1_octave;
  logic [31:0] snapshot_stage1_attenuation;
  logic snapshot_stage2_valid;
  logic [1:0] snapshot_stage2_kind;
  logic signed [15:0] snapshot_stage2_direct_level;
  logic [4:0] snapshot_stage2_octave;
  logic [6:0] snapshot_stage2_mantissa_index;
  logic snapshot_stage3_valid;
  logic [1:0] snapshot_stage3_kind;
  logic signed [15:0] snapshot_stage3_direct_level;
  logic [4:0] snapshot_stage3_octave;
  logic [23:0] snapshot_stage3_mantissa;
  logic [4:0] snapshot_octave_next;
  logic [31:0] snapshot_residual_next;
  logic [31:0] snapshot_rounded_residual_next;
  logic [6:0] snapshot_mantissa_index_next;
  logic [3:0] release_leading_zeros;
  logic [14:0] release_normalized;
  logic [ENV_Q15_TO_CB_MANTISSA_BITS-1:0] release_mantissa_index;
  logic release_level_positive;
  logic release_level_full;
  logic [3:0] release_leading_zeros_q;
  logic [ENV_Q15_TO_CB_MANTISSA_BITS-1:0] release_mantissa_index_q;
  logic release_level_positive_q;
  logic release_level_full_q;
  logic [32:0] release_approximation;
  logic [31:0] release_attenuation;
  logic [31:0] release_attenuation_q;
  logic compressor_config_valid;
  logic chorus_config_valid;
  logic reverb_config_valid;
  logic effect_clear_valid;

  localparam logic [1:0] SNAPSHOT_LEVEL_ZERO = 2'd0;
  localparam logic [1:0] SNAPSHOT_LEVEL_DIRECT = 2'd1;
  localparam logic [1:0] SNAPSHOT_LEVEL_CB = 2'd2;

  function automatic logic loop_valid(
    input logic [1:0] loop_mode,
    input logic stereo,
    input logic [PHASE_FRAME_WIDTH-1:0] length,
    input logic [PHASE_FRAME_WIDTH-1:0] length_r,
    input logic [PHASE_FRAME_WIDTH-1:0] loop_start,
    input logic [PHASE_FRAME_WIDTH-1:0] loop_start_r,
    input logic [PHASE_FRAME_WIDTH-1:0] loop_end,
    input logic [PHASE_FRAME_WIDTH-1:0] loop_end_r
  );
    logic left_valid;
    logic right_valid;
    begin
      left_valid = (loop_start < loop_end) && (loop_end <= length);
      right_valid = (loop_start_r < loop_end_r) && (loop_end_r <= length_r);
      loop_valid = (loop_mode == LOOP_MODE_NONE) ||
                   (left_valid && (!stereo || right_valid));
    end
  endfunction

  function automatic logic signed [15:0] scaled_mantissa_to_q15(
    input logic [23:0] mantissa,
    input logic [4:0] octave_index
  );
    logic [23:0] scaled_mantissa;
    logic [24:0] rounded_mantissa;
    begin
      scaled_mantissa = mantissa >> octave_index;
      rounded_mantissa = {1'b0, scaled_mantissa} +
                         25'(1 << (ENV_CB_TO_Q15_GUARD_BITS - 1));
      scaled_mantissa_to_q15 = $signed(16'(rounded_mantissa >> 8));
    end
  endfunction

  function automatic volume_env_stage_t stage_after_attack(
    input logic [23:0] hold_samples,
    input logic [31:0] sustain_cb_q12_20,
    input logic [31:0] decay_step_cb_q12_20
  );
    if (hold_samples != '0)
      stage_after_attack = ENV_HOLD;
    else if ((sustain_cb_q12_20 != '0) && (decay_step_cb_q12_20 != '0))
      stage_after_attack = ENV_DECAY;
    else
      stage_after_attack = ENV_SUSTAIN;
  endfunction

  function automatic active_voice_t advance_envelope(input active_voice_t in_voice);
    active_voice_t out_voice;
    logic [32:0] attack_sum;
    logic [32:0] cb_sum;
    begin
      out_voice = in_voice;
      if (in_voice.audible) begin
        unique case (in_voice.env_state.stage)
          ENV_DELAY: begin
            if ((in_voice.env_state.elapsed + 1'b1) >= in_voice.env_params.delay_samples) begin
              out_voice.env_state.elapsed = '0;
              if (in_voice.env_params.attack_step_q0_32 == '0) begin
                out_voice.env_state.attack_level_q0_32 = 32'hffff_ffff;
                out_voice.env_state.stage = stage_after_attack(
                    in_voice.env_params.hold_samples,
                    in_voice.env_params.sustain_cb_q12_20,
                    in_voice.env_params.decay_step_cb_q12_20);
                if (out_voice.env_state.stage == ENV_SUSTAIN)
                  out_voice.env_state.attenuation_cb_q12_20 =
                      in_voice.env_params.sustain_cb_q12_20;
              end else begin
                out_voice.env_state.stage = ENV_ATTACK;
              end
            end else begin
              out_voice.env_state.elapsed = in_voice.env_state.elapsed + 1'b1;
            end
          end
          ENV_ATTACK: begin
            attack_sum = {1'b0, in_voice.env_state.attack_level_q0_32} +
                         {1'b0, in_voice.env_params.attack_step_q0_32};
            if (attack_sum[32] || (attack_sum[31:0] >= 32'hffff_ffff)) begin
              out_voice.env_state.attack_level_q0_32 = 32'hffff_ffff;
              out_voice.env_state.elapsed = '0;
              out_voice.env_state.stage = stage_after_attack(
                  in_voice.env_params.hold_samples,
                  in_voice.env_params.sustain_cb_q12_20,
                  in_voice.env_params.decay_step_cb_q12_20);
              if (out_voice.env_state.stage == ENV_SUSTAIN)
                out_voice.env_state.attenuation_cb_q12_20 =
                    in_voice.env_params.sustain_cb_q12_20;
            end else begin
              out_voice.env_state.attack_level_q0_32 = attack_sum[31:0];
            end
          end
          ENV_HOLD: begin
            if ((in_voice.env_state.elapsed + 1'b1) >= in_voice.env_params.hold_samples) begin
              out_voice.env_state.elapsed = '0;
              if ((in_voice.env_params.sustain_cb_q12_20 != '0) &&
                  (in_voice.env_params.decay_step_cb_q12_20 != '0)) begin
                out_voice.env_state.stage = ENV_DECAY;
              end else begin
                out_voice.env_state.stage = ENV_SUSTAIN;
                out_voice.env_state.attenuation_cb_q12_20 =
                    in_voice.env_params.sustain_cb_q12_20;
              end
            end else begin
              out_voice.env_state.elapsed = in_voice.env_state.elapsed + 1'b1;
            end
          end
          ENV_DECAY: begin
            if (in_voice.env_state.attenuation_cb_q12_20 < in_voice.env_params.sustain_cb_q12_20) begin
              cb_sum = {1'b0, in_voice.env_state.attenuation_cb_q12_20} +
                       {1'b0, in_voice.env_params.decay_step_cb_q12_20};
              if (cb_sum[32] || (cb_sum[31:0] >= in_voice.env_params.sustain_cb_q12_20)) begin
                out_voice.env_state.attenuation_cb_q12_20 = in_voice.env_params.sustain_cb_q12_20;
                out_voice.env_state.stage = ENV_SUSTAIN;
              end else begin
                out_voice.env_state.attenuation_cb_q12_20 = cb_sum[31:0];
              end
            end else if (in_voice.env_state.attenuation_cb_q12_20 >
                         in_voice.env_params.sustain_cb_q12_20) begin
              if (in_voice.env_state.attenuation_cb_q12_20 -
                  in_voice.env_params.sustain_cb_q12_20 <=
                  in_voice.env_params.decay_step_cb_q12_20) begin
                out_voice.env_state.attenuation_cb_q12_20 = in_voice.env_params.sustain_cb_q12_20;
                out_voice.env_state.stage = ENV_SUSTAIN;
              end else begin
                out_voice.env_state.attenuation_cb_q12_20 =
                    in_voice.env_state.attenuation_cb_q12_20 -
                    in_voice.env_params.decay_step_cb_q12_20;
              end
            end else begin
              out_voice.env_state.stage = ENV_SUSTAIN;
            end
          end
          ENV_SUSTAIN: begin
            out_voice.env_state.attenuation_cb_q12_20 = in_voice.env_params.sustain_cb_q12_20;
          end
          ENV_RELEASE: begin
            cb_sum = {1'b0, in_voice.env_state.attenuation_cb_q12_20} +
                     {1'b0, in_voice.env_params.release_step_cb_q12_20};
            if (cb_sum[32] || (cb_sum[31:0] >= ENV_CB_SILENCE_Q12_20)) begin
              out_voice.env_state.attenuation_cb_q12_20 = ENV_CB_SILENCE_Q12_20;
              out_voice.audible = 1'b0;
            end else begin
              out_voice.env_state.attenuation_cb_q12_20 = cb_sum[31:0];
            end
          end
          default: out_voice.env_state.stage = ENV_DELAY;
        endcase
      end
      advance_envelope = out_voice;
    end
  endfunction

  always_comb begin
    env_update_payload_valid = 1'b1;
    env_update_payload_index = 1;
    for (int field = 0; field < 6; field++) begin
      if (current_action.payload[0][field]) begin
        if (((field == 0) || (field == 2)) &&
            (current_action.payload[env_update_payload_index][31:24] != '0))
          env_update_payload_valid = 1'b0;
        env_update_payload_index++;
      end
    end

    define_data = '0;
    define_data.seq = current_action.seq;
    define_data.voice.enable = 1'b1;
    define_data.voice.stereo = current_action.opcode == VOICE_DEFINE_STEREO;
    define_data.voice.base_addr = current_action.payload[0];
    if (current_action.opcode == VOICE_DEFINE_STEREO) begin
      define_data.voice.base_addr_r = current_action.payload[1];
      define_data.voice.length = current_action.payload[2][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.length_r = current_action.payload[3][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_start = current_action.payload[4][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_start_r = current_action.payload[5][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_end = current_action.payload[6][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_end_r = current_action.payload[7][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.phase_init = current_action.payload[8];
      define_data.voice.loop_mode = current_action.payload[9][1:0];
      define_data.filter_b0 = current_action.payload[10][15:0];
      define_data.filter_b1 = current_action.payload[10][31:16];
      define_data.filter_b2 = current_action.payload[11][15:0];
      define_data.filter_a1 = current_action.payload[11][31:16];
      define_data.filter_a2 = current_action.payload[12][15:0];
      define_data.filter_enable = current_action.payload[12][16];
    end else begin
      define_data.voice.length = current_action.payload[1][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_start = current_action.payload[2][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_end = current_action.payload[3][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.phase_init = current_action.payload[4];
      define_data.voice.loop_mode = current_action.payload[5][1:0];
      define_data.filter_b0 = current_action.payload[6][15:0];
      define_data.filter_b1 = current_action.payload[6][31:16];
      define_data.filter_b2 = current_action.payload[7][15:0];
      define_data.filter_a1 = current_action.payload[7][31:16];
      define_data.filter_a2 = current_action.payload[8][15:0];
      define_data.filter_enable = current_action.payload[8][16];
    end

    define_valid = (define_data.voice.length != '0) &&
                   (define_data.voice.loop_mode != 2'b11) &&
                   (define_data.voice.phase_init[31:8] < define_data.voice.length) &&
                   loop_valid(define_data.voice.loop_mode,
                              define_data.voice.stereo,
                              define_data.voice.length,
                              define_data.voice.length_r,
                              define_data.voice.loop_start,
                              define_data.voice.loop_start_r,
                              define_data.voice.loop_end,
                              define_data.voice.loop_end_r);
    if (current_action.opcode == VOICE_DEFINE_STEREO)
      define_valid = define_valid && (define_data.voice.length_r != '0) &&
                     (define_data.voice.phase_init[31:8] < define_data.voice.length_r) &&
                     (current_action.payload[9][31:2] == '0) &&
                     (current_action.payload[12][31:17] == '0) &&
                     (current_action.payload[13] == '0) &&
                     (current_action.payload[14] == '0);
    else
      define_valid = define_valid && (current_action.payload[5][31:2] == '0) &&
                     (current_action.payload[8][31:17] == '0) &&
                     (current_action.payload[9] == '0) &&
                     (current_action.payload[10] == '0);

    prepared_read_data = prepared_voice_t'(prepared_read_word);
    active_read_data = active_voice_t'(active_read_word);
    debug_prepared_seq = prepared_read_data.seq;
    debug_active = active_read_data;
    action_seq_match = active_valid[action_voice] &&
                       (active_action_data_q.seq == current_action.seq);
    action_semantic_valid = 1'b1;
    if (current_action.opcode == VOICE_START)
      action_semantic_valid = (current_action.payload[2][31:24] == '0) &&
                              (current_action.payload[4][31:24] == '0);
    else if (current_action.opcode == VOICE_ENV_UPDATE)
      action_semantic_valid = env_update_payload_valid;
    else if (current_action.opcode == VOICE_FILTER)
      action_semantic_valid = current_action.payload[2][31:17] == '0;
    compressor_config_valid = (action.payload[0][31:17] == '0) &&
                              (action.payload[1] <= ENV_CB_SILENCE_Q12_20) &&
                              (action.payload[2] <= ENV_CB_SILENCE_Q12_20) &&
                              (action.payload[3] <= ENV_CB_SILENCE_Q12_20);
    chorus_config_valid = (action.payload[0][15:1] == '0) &&
                          (action.payload[1][31:24] == '0) &&
                          (action.payload[2][31:24] == '0) &&
                          ($signed(action.payload[0][31:16]) <= 16'sh6000) &&
                          ($signed(action.payload[0][31:16]) >= -16'sh6000) &&
                          (action.payload[4][15:0] <= 16'h7fff) &&
                          (action.payload[4][31:16] <= 16'h7fff);
    reverb_config_valid = (action.payload[0][31:12] == '0) &&
                          (action.payload[1][31:16] == '0) &&
                          (action.payload[2][31:16] == '0) &&
                          (action.payload[3][31:16] == '0) &&
                          (action.payload[4][31:16] == '0) &&
                          (action.payload[1][15:0] <= 16'h7fff) &&
                          (action.payload[2][15:0] <= 16'h7fff) &&
                          (action.payload[3][15:0] <= 16'h7fff) &&
                          (action.payload[4][15:0] <= 16'h7fff);
    for (int word = 5; word < 9; word++) begin
      reverb_config_valid = reverb_config_valid &&
                            (action.payload[word][15:0] <= 16'h2d41) &&
                            (action.payload[word][31:16] <= 16'h2d41);
    end
    effect_clear_valid = (action.payload[0][31:2] == '0) &&
                         (action.payload[0][1:0] != 2'b00);

    action_next_data = active_action_data_q;
    unique case (current_action.opcode)
      VOICE_START: begin
        action_next_data = '0;
        action_next_data.audible = 1'b1;
        action_next_data.seq = current_action.seq;
        action_next_data.voice = prepared_action_data_q.voice;
        action_next_data.phase_inc = current_action.payload[1];
        action_next_data.gain_l = current_action.payload[0][15:0];
        action_next_data.gain_r = current_action.payload[0][31:16];
        action_next_data.filter_enable = prepared_action_data_q.filter_enable;
        action_next_data.filter_b0 = prepared_action_data_q.filter_b0;
        action_next_data.filter_b1 = prepared_action_data_q.filter_b1;
        action_next_data.filter_b2 = prepared_action_data_q.filter_b2;
        action_next_data.filter_a1 = prepared_action_data_q.filter_a1;
        action_next_data.filter_a2 = prepared_action_data_q.filter_a2;
        action_next_data.env_params.delay_samples = current_action.payload[2][23:0];
        action_next_data.env_params.attack_step_q0_32 = current_action.payload[3];
        action_next_data.env_params.hold_samples = current_action.payload[4][23:0];
        action_next_data.env_params.decay_step_cb_q12_20 = current_action.payload[5];
        action_next_data.env_params.sustain_cb_q12_20 = current_action.payload[6];
        action_next_data.env_params.release_step_cb_q12_20 = current_action.payload[7];
        action_next_data.env_state.stage = (current_action.payload[2][23:0] != '0) ?
                                           ENV_DELAY : ENV_ATTACK;
        if ((current_action.payload[2][23:0] == '0) && (current_action.payload[3] == '0)) begin
          action_next_data.env_state.attack_level_q0_32 = 32'hffff_ffff;
          action_next_data.env_state.stage = stage_after_attack(
              action_next_data.env_params.hold_samples,
              action_next_data.env_params.sustain_cb_q12_20,
              action_next_data.env_params.decay_step_cb_q12_20);
          if (action_next_data.env_state.stage == ENV_SUSTAIN)
            action_next_data.env_state.attenuation_cb_q12_20 =
                action_next_data.env_params.sustain_cb_q12_20;
        end
      end
      VOICE_ENV_UPDATE: begin
        int payload_index;
        payload_index = 1;
        for (int field = 0; field < 6; field++) begin
          if (current_action.payload[0][field]) begin
            unique case (field)
              0: begin
                action_next_data.env_params.delay_samples = current_action.payload[payload_index][23:0];
                if ((active_action_data_q.env_state.stage == ENV_DELAY) &&
                    (active_action_data_q.env_state.elapsed >= current_action.payload[payload_index][23:0]))
                  action_next_data.env_state.stage = ENV_ATTACK;
              end
              1: action_next_data.env_params.attack_step_q0_32 = current_action.payload[payload_index];
              2: begin
                action_next_data.env_params.hold_samples = current_action.payload[payload_index][23:0];
                if ((active_action_data_q.env_state.stage == ENV_HOLD) &&
                    (active_action_data_q.env_state.elapsed >= current_action.payload[payload_index][23:0])) begin
                  if ((action_next_data.env_params.sustain_cb_q12_20 != '0) &&
                      (action_next_data.env_params.decay_step_cb_q12_20 != '0)) begin
                    action_next_data.env_state.stage = ENV_DECAY;
                  end else begin
                    action_next_data.env_state.stage = ENV_SUSTAIN;
                    action_next_data.env_state.attenuation_cb_q12_20 =
                        action_next_data.env_params.sustain_cb_q12_20;
                  end
                end
              end
              3: action_next_data.env_params.decay_step_cb_q12_20 = current_action.payload[payload_index];
              4: begin
                action_next_data.env_params.sustain_cb_q12_20 = current_action.payload[payload_index];
                if (active_action_data_q.env_state.stage == ENV_SUSTAIN) begin
                  if (action_next_data.env_params.decay_step_cb_q12_20 != '0)
                    action_next_data.env_state.stage = ENV_DECAY;
                  else
                    action_next_data.env_state.attenuation_cb_q12_20 =
                        current_action.payload[payload_index];
                end
              end
              5: action_next_data.env_params.release_step_cb_q12_20 = current_action.payload[payload_index];
              default: begin end
            endcase
            payload_index++;
          end
        end
      end
      VOICE_RELEASE: begin
        action_next_data.env_params.release_step_cb_q12_20 = current_action.payload[0];
        if (current_action.payload[0] == '0) begin
          action_next_data.env_state.attenuation_cb_q12_20 = ENV_CB_SILENCE_Q12_20;
        end else begin
          unique case (active_action_data_q.env_state.stage)
            ENV_ATTACK: action_next_data.env_state.attenuation_cb_q12_20 =
                release_attenuation_q;
            ENV_HOLD: action_next_data.env_state.attenuation_cb_q12_20 = '0;
            ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE:
                action_next_data.env_state.attenuation_cb_q12_20 =
                    active_action_data_q.env_state.attenuation_cb_q12_20;
            default: action_next_data.env_state.attenuation_cb_q12_20 =
                ENV_CB_SILENCE_Q12_20;
          endcase
        end
        action_next_data.env_state.stage = ENV_RELEASE;
        action_next_data.env_state.elapsed = '0;
        action_next_data.released = 1'b1;
        if (current_action.payload[0] == '0)
          action_next_data.audible = 1'b0;
      end
      VOICE_STOP: action_next_data.audible = 1'b0;
      VOICE_GAIN_PHASE: begin
        action_next_data.gain_l = current_action.payload[0][15:0];
        action_next_data.gain_r = current_action.payload[0][31:16];
        action_next_data.phase_inc = current_action.payload[1];
      end
      VOICE_FILTER: begin
        action_next_data.filter_b0 = current_action.payload[0][15:0];
        action_next_data.filter_b1 = current_action.payload[0][31:16];
        action_next_data.filter_b2 = current_action.payload[1][15:0];
        action_next_data.filter_a1 = current_action.payload[1][31:16];
        action_next_data.filter_a2 = current_action.payload[2][15:0];
        action_next_data.filter_enable = current_action.payload[2][16];
      end
      default: begin end
    endcase

    envelope_next_data = advance_envelope(snapshot_active_data_q);
    action_ready = state == EXEC_IDLE;
    prepared_write = (state == EXEC_DEFINE) && define_valid;
    snapshot_accept = snapshot_prepare && (state == EXEC_IDLE);
    active_envelope_write = snapshot_accept && active_valid[snapshot_voice];
    active_read_voice = ((state != EXEC_IDLE) || (action_valid && action_ready)) ?
                        ((state != EXEC_IDLE) ? action_voice : action.voice[VOICE_ID_WIDTH-1:0]) :
                        (debug_read_select ? debug_read_voice : render_voice_index);
    prepared_read_voice = ((state != EXEC_IDLE) || (action_valid && action_ready)) ?
                          ((state != EXEC_IDLE) ? action_voice : action.voice[VOICE_ID_WIDTH-1:0]) :
                          (debug_read_select ? debug_read_voice : render_voice_index);

    snapshot_octave_next = '0;
    if (snapshot_stage0_attenuation >= ENV_CB_OCTAVE_Q12_20_LUT[16]) begin
      snapshot_octave_next = 5'd16;
    end else begin
      if (snapshot_stage0_attenuation >= ENV_CB_OCTAVE_Q12_20_LUT[8])
        snapshot_octave_next = 5'd8;
      if (snapshot_stage0_attenuation >=
          ENV_CB_OCTAVE_Q12_20_LUT[snapshot_octave_next + 5'd4])
        snapshot_octave_next = snapshot_octave_next + 5'd4;
      if (snapshot_stage0_attenuation >=
          ENV_CB_OCTAVE_Q12_20_LUT[snapshot_octave_next + 5'd2])
        snapshot_octave_next = snapshot_octave_next + 5'd2;
      if (snapshot_stage0_attenuation >=
          ENV_CB_OCTAVE_Q12_20_LUT[snapshot_octave_next + 5'd1])
        snapshot_octave_next = snapshot_octave_next + 5'd1;
    end
    snapshot_residual_next = snapshot_stage1_attenuation -
                             ENV_CB_OCTAVE_Q12_20_LUT[snapshot_stage1_octave];
    snapshot_rounded_residual_next = snapshot_residual_next +
        32'(1 << (ENV_CB_TO_Q15_RESIDUAL_INDEX_SHIFT - 1));
    snapshot_mantissa_index_next = 7'(
        snapshot_rounded_residual_next >> ENV_CB_TO_Q15_RESIDUAL_INDEX_SHIFT);

    release_leading_zeros = '0;
    release_level_positive =
        active_action_data_q.env_state.attack_level_q0_32[31:17] != '0;
    release_level_full =
        active_action_data_q.env_state.attack_level_q0_32[31:17] >= 15'h7fff;
    begin
      logic found;
      found = 1'b0;
      for (int bit_index = 14; bit_index >= 0; bit_index--) begin
        if (!found &&
            active_action_data_q.env_state.attack_level_q0_32[17 + bit_index]) begin
          release_leading_zeros = 4'(14 - bit_index);
          found = 1'b1;
        end
      end
    end
    release_normalized =
        active_action_data_q.env_state.attack_level_q0_32[31:17] <<
        release_leading_zeros;
    release_mantissa_index = ENV_Q15_TO_CB_MANTISSA_BITS'(
        release_normalized >> (14 - ENV_Q15_TO_CB_MANTISSA_BITS));
    release_approximation =
        {1'b0, ENV_CB_OCTAVE_Q12_20_LUT[5'(release_leading_zeros_q)]} +
        {1'b0, ENV_Q15_TO_CB_MANTISSA_LUT[release_mantissa_index_q]};
    release_attenuation = ENV_CB_SILENCE_Q12_20;
    if (release_level_full_q)
      release_attenuation = 32'd0;
    else if (release_level_positive_q &&
             (release_approximation < {1'b0, ENV_CB_SILENCE_Q12_20}))
      release_attenuation = release_approximation[31:0];
    config_valid = active_valid;
  end

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES), .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(PREPARED_WIDTH), .DEFAULT_WORD('0)
  ) prepared_ram (
    .clk, .write_en(prepared_write), .write_addr(action_voice),
    .write_data(define_data), .read_addr(prepared_read_voice), .read_data(prepared_read_word)
  );

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES), .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(ACTIVE_WIDTH), .DEFAULT_WORD('0)
  ) active_ram (
    .clk, .write_en(active_write_q), .write_addr(active_write_voice_q),
    .write_data(active_write_data_q), .read_addr(active_read_voice), .read_data(active_read_word)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= EXEC_IDLE;
      current_action <= '0;
      action_voice <= '0;
      prepared_valid <= '0;
      active_valid <= '0;
      active_write_q <= 1'b0;
      active_write_voice_q <= '0;
      active_write_data_q <= '0;
      prepared_action_data_q <= '0;
      active_action_data_q <= '0;
      release_leading_zeros_q <= '0;
      release_mantissa_index_q <= '0;
      release_level_positive_q <= 1'b0;
      release_level_full_q <= 1'b0;
      release_attenuation_q <= ENV_CB_SILENCE_Q12_20;
      pending_commit <= '0;
      commit_pulse <= '0;
      action_done <= 1'b0;
      stream_flush <= 1'b0;
      command_error_pulse <= 1'b0;
      stale_seq_pulse <= 1'b0;
      snapshot_valid <= 1'b0;
      snapshot_active_data_q <= '0;
      snapshot_active_valid_q <= 1'b0;
      snapshot_voice_q <= '0;
      snapshot_read_valid <= 1'b0;
      snapshot_stage0_valid <= 1'b0;
      snapshot_stage0_kind <= SNAPSHOT_LEVEL_ZERO;
      snapshot_stage0_direct_level <= '0;
      snapshot_stage0_attenuation <= '0;
      snapshot_stage1_valid <= 1'b0;
      snapshot_stage1_kind <= SNAPSHOT_LEVEL_ZERO;
      snapshot_stage1_direct_level <= '0;
      snapshot_stage1_octave <= '0;
      snapshot_stage1_attenuation <= '0;
      snapshot_stage2_valid <= 1'b0;
      snapshot_stage2_kind <= SNAPSHOT_LEVEL_ZERO;
      snapshot_stage2_direct_level <= '0;
      snapshot_stage2_octave <= '0;
      snapshot_stage2_mantissa_index <= '0;
      snapshot_stage3_valid <= 1'b0;
      snapshot_stage3_kind <= SNAPSHOT_LEVEL_ZERO;
      snapshot_stage3_direct_level <= '0;
      snapshot_stage3_octave <= '0;
      snapshot_stage3_mantissa <= '0;
      render_config <= '0;
      render_runtime <= '0;
      audio_config <= '0;
      audio_config.master_volume <= 16'sh7fff;
      effect_clear <= 2'b00;
    end else begin
      action_done <= 1'b0;
      active_write_q <= 1'b0;
      if (snapshot_read_valid && snapshot_active_valid_q) begin
        active_write_q <= 1'b1;
        active_write_voice_q <= snapshot_voice_q;
        active_write_data_q <= envelope_next_data;
      end
      stream_flush <= 1'b0;
      command_error_pulse <= 1'b0;
      stale_seq_pulse <= 1'b0;
      effect_clear <= 2'b00;
      snapshot_valid <= snapshot_stage3_valid;
      snapshot_read_valid <= snapshot_accept;
      snapshot_stage0_valid <= snapshot_read_valid;
      snapshot_stage1_valid <= snapshot_stage0_valid;
      snapshot_stage2_valid <= snapshot_stage1_valid;
      snapshot_stage3_valid <= snapshot_stage2_valid;

      if (snapshot_accept) begin
        snapshot_active_data_q <= active_read_data;
        snapshot_active_valid_q <= active_envelope_write;
        snapshot_voice_q <= snapshot_voice;
      end

      if (snapshot_read_valid) begin
        render_config <= snapshot_active_data_q.voice;
        render_config.enable <= snapshot_active_valid_q &&
                                snapshot_active_data_q.voice.enable &&
                                envelope_next_data.audible;
        render_runtime.phase_inc <= snapshot_active_data_q.phase_inc;
        render_runtime.gain_l <= snapshot_active_data_q.gain_l;
        render_runtime.gain_r <= snapshot_active_data_q.gain_r;
        render_runtime.envelope_delay <= snapshot_active_valid_q &&
                                         envelope_next_data.audible &&
                                         (envelope_next_data.env_state.stage == ENV_DELAY);
        render_runtime.released <= snapshot_active_data_q.released;
        render_runtime.filter_enable <= snapshot_active_data_q.filter_enable;
        render_runtime.filter_b0 <= snapshot_active_data_q.filter_b0;
        render_runtime.filter_b1 <= snapshot_active_data_q.filter_b1;
        render_runtime.filter_b2 <= snapshot_active_data_q.filter_b2;
        render_runtime.filter_a1 <= snapshot_active_data_q.filter_a1;
        render_runtime.filter_a2 <= snapshot_active_data_q.filter_a2;
        snapshot_stage0_kind <= SNAPSHOT_LEVEL_ZERO;
        snapshot_stage0_direct_level <= '0;
        snapshot_stage0_attenuation <= envelope_next_data.env_state.attenuation_cb_q12_20;
        if (snapshot_active_valid_q && envelope_next_data.audible &&
            (envelope_next_data.env_state.stage == ENV_ATTACK)) begin
          snapshot_stage0_kind <= SNAPSHOT_LEVEL_DIRECT;
          snapshot_stage0_direct_level <= $signed(
              {1'b0, envelope_next_data.env_state.attack_level_q0_32[31:17]});
        end else if (snapshot_active_valid_q && envelope_next_data.audible &&
                     (envelope_next_data.env_state.stage == ENV_HOLD)) begin
          snapshot_stage0_kind <= SNAPSHOT_LEVEL_DIRECT;
          snapshot_stage0_direct_level <= 16'sh7fff;
        end else if (snapshot_active_valid_q && envelope_next_data.audible &&
                     (envelope_next_data.env_state.stage != ENV_DELAY) &&
                     (envelope_next_data.env_state.attenuation_cb_q12_20 <
                      ENV_CB_SILENCE_Q12_20)) begin
          snapshot_stage0_kind <= SNAPSHOT_LEVEL_CB;
        end
      end

      if (snapshot_stage0_valid) begin
        snapshot_stage1_kind <= snapshot_stage0_kind;
        snapshot_stage1_direct_level <= snapshot_stage0_direct_level;
        snapshot_stage1_octave <= snapshot_octave_next;
        snapshot_stage1_attenuation <= snapshot_stage0_attenuation;
      end

      if (snapshot_stage1_valid) begin
        snapshot_stage2_kind <= snapshot_stage1_kind;
        snapshot_stage2_direct_level <= snapshot_stage1_direct_level;
        snapshot_stage2_octave <= snapshot_stage1_octave;
        snapshot_stage2_mantissa_index <= snapshot_mantissa_index_next;
      end

      if (snapshot_stage2_valid) begin
        snapshot_stage3_kind <= snapshot_stage2_kind;
        snapshot_stage3_direct_level <= snapshot_stage2_direct_level;
        snapshot_stage3_octave <= snapshot_stage2_octave;
        snapshot_stage3_mantissa <=
            ENV_CB_TO_Q15_MANTISSA_LUT[snapshot_stage2_mantissa_index];
      end

      if (snapshot_stage3_valid) begin
        unique case (snapshot_stage3_kind)
          SNAPSHOT_LEVEL_DIRECT:
              render_runtime.envelope_level <= snapshot_stage3_direct_level;
          SNAPSHOT_LEVEL_CB:
              render_runtime.envelope_level <= scaled_mantissa_to_q15(
                  snapshot_stage3_mantissa, snapshot_stage3_octave);
          default: render_runtime.envelope_level <= 16'sh0000;
        endcase
      end
      commit_pulse <= pending_commit;
      if (frame_start)
        pending_commit <= '0;

      if (prepared_write) begin
        prepared_valid[action_voice] <= 1'b1;
      end
      if (snapshot_read_valid && snapshot_active_valid_q && !envelope_next_data.audible)
        active_valid[snapshot_voice_q] <= 1'b0;

      unique case (state)
        EXEC_IDLE: begin
          if (action_valid && action_ready) begin
            if ((action.opcode == VOICE_DEFINE_MONO) ||
                (action.opcode == VOICE_DEFINE_STEREO)) begin
              current_action <= action;
              action_voice <= action.voice[VOICE_ID_WIDTH-1:0];
              state <= EXEC_DEFINE;
            end else if (action.opcode == STREAM_FLUSH) begin
              stream_flush <= 1'b1;
              action_done <= 1'b1;
            end else if (action.opcode == COMPRESSOR_CONFIG) begin
              if (!compressor_config_valid) begin
                command_error_pulse <= 1'b1;
              end else begin
                audio_config.compressor.enable <= action.payload[0][0];
                audio_config.compressor.threshold_cb_q12_20 <= action.payload[1];
                audio_config.compressor.ratio_slope_q0_16 <= action.payload[0][16:1];
                audio_config.compressor.attack_step_cb_q12_20 <= action.payload[2];
                audio_config.compressor.release_step_cb_q12_20 <= action.payload[3];
              end
              action_done <= 1'b1;
            end else if (action.opcode == MASTER_VOLUME) begin
              if (action.payload[0][31:15] != '0)
                command_error_pulse <= 1'b1;
              else
                audio_config.master_volume <= $signed(action.payload[0][15:0]);
              action_done <= 1'b1;
            end else if (action.opcode == CHORUS_CONFIG) begin
              if (!chorus_config_valid) begin
                command_error_pulse <= 1'b1;
              end else begin
                audio_config.chorus.enable <= action.payload[0][0];
                audio_config.chorus.feedback_q1_15 <=
                    $signed(action.payload[0][31:16]);
                audio_config.chorus.base_delay_q16_8 <= action.payload[1][23:0];
                audio_config.chorus.depth_q16_8 <= action.payload[2][23:0];
                audio_config.chorus.lfo_phase_inc_q0_32 <= action.payload[3];
                audio_config.chorus.input_send_q1_15 <= action.payload[4][15:0];
                audio_config.chorus.return_gain_q1_15 <= action.payload[4][31:16];
                audio_config.chorus.stereo_phase_offset_q0_32 <= action.payload[5];
              end
              action_done <= 1'b1;
            end else if (action.opcode == REVERB_CONFIG) begin
              if (!reverb_config_valid) begin
                command_error_pulse <= 1'b1;
              end else begin
                audio_config.reverb.enable <= action.payload[0][0];
                audio_config.reverb.pre_delay_frames <= action.payload[0][11:1];
                audio_config.reverb.input_send_q1_15 <= action.payload[1][15:0];
                audio_config.reverb.return_gain_q1_15 <= action.payload[2][15:0];
                audio_config.reverb.damping_q1_15 <= action.payload[3][15:0];
                audio_config.reverb.chorus_to_reverb_q1_15 <= action.payload[4][15:0];
                for (int pair = 0; pair < 4; pair++) begin
                  audio_config.reverb.feedback_gain_q1_15[pair * 2] <=
                      action.payload[5 + pair][15:0];
                  audio_config.reverb.feedback_gain_q1_15[pair * 2 + 1] <=
                      action.payload[5 + pair][31:16];
                end
              end
              action_done <= 1'b1;
            end else if (action.opcode == EFFECT_CLEAR) begin
              if (!effect_clear_valid)
                command_error_pulse <= 1'b1;
              else
                effect_clear <= action.payload[0][1:0];
              action_done <= 1'b1;
            end else begin
              current_action <= action;
              action_voice <= action.voice[VOICE_ID_WIDTH-1:0];
              state <= EXEC_READ;
            end
          end
        end
        EXEC_DEFINE: begin
          if (!define_valid)
            command_error_pulse <= 1'b1;
          action_done <= 1'b1;
          state <= EXEC_IDLE;
        end
        EXEC_READ: begin
          prepared_action_data_q <= prepared_read_data;
          active_action_data_q <= active_read_data;
          state <= EXEC_RELEASE_INDEX;
        end
        EXEC_RELEASE_INDEX: begin
          release_leading_zeros_q <= release_leading_zeros;
          release_mantissa_index_q <= release_mantissa_index;
          release_level_positive_q <= release_level_positive;
          release_level_full_q <= release_level_full;
          state <= EXEC_RELEASE_VALUE;
        end
        EXEC_RELEASE_VALUE: begin
          release_attenuation_q <= release_attenuation;
          state <= EXEC_APPLY;
        end
        EXEC_APPLY: begin
          if (!action_semantic_valid) begin
            command_error_pulse <= 1'b1;
            action_done <= 1'b1;
            state <= EXEC_IDLE;
          end else if ((current_action.opcode == VOICE_START) ?
                       !(prepared_valid[action_voice] &&
                         (prepared_action_data_q.seq == current_action.seq)) :
                       !action_seq_match) begin
            stale_seq_pulse <= 1'b1;
            action_done <= 1'b1;
            state <= EXEC_IDLE;
          end else begin
            active_write_q <= 1'b1;
            active_write_voice_q <= action_voice;
            active_write_data_q <= action_next_data;
            if (current_action.opcode == VOICE_START) begin
              active_valid[action_voice] <= 1'b1;
              pending_commit[action_voice] <= 1'b1;
            end else if ((current_action.opcode == VOICE_STOP) ||
                         ((current_action.opcode == VOICE_RELEASE) &&
                          (current_action.payload[0] == '0))) begin
              active_valid[action_voice] <= 1'b0;
            end
            state <= EXEC_COMMIT;
          end
        end
        EXEC_COMMIT: begin
          action_done <= 1'b1;
          state <= EXEC_IDLE;
        end
        default: state <= EXEC_IDLE;
      endcase
    end
  end
endmodule
