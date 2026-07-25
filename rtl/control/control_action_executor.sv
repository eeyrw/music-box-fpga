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
  output synth_pkg::compressor_config_t compressor_config,
  output logic signed [15:0] master_volume,
  output logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0] commit_pulse,
  output logic [synth_pkg::NUM_VOICES-1:0] prepared_valid
);
  import synth_pkg::*;
  import synth_dsp_lut_pkg::*;

  localparam int PREPARED_WIDTH = $bits(prepared_voice_t);
  localparam int ACTIVE_WIDTH = $bits(active_voice_t);

  typedef enum logic [1:0] {EXEC_IDLE, EXEC_READ, EXEC_APPLY} exec_state_t;
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
  prepared_voice_t define_data;
  active_voice_t action_next_data;
  active_voice_t envelope_next_data;
  logic define_valid;
  logic action_semantic_valid;
  logic prepared_write;
  logic active_action_write;
  logic active_envelope_write;
  logic snapshot_accept;
  logic active_write;
  logic [VOICE_ID_WIDTH-1:0] active_write_voice;
  active_voice_t active_write_data;
  logic [NUM_VOICES-1:0] active_valid;
  logic [NUM_VOICES-1:0] pending_commit;
  logic action_seq_match;
  logic env_update_payload_valid;
  integer env_update_payload_index;
  logic snapshot_stage0_valid;
  logic [1:0] snapshot_stage0_kind;
  logic signed [15:0] snapshot_stage0_direct_level;
  logic [31:0] snapshot_stage0_attenuation;
  logic snapshot_stage1_valid;
  logic [1:0] snapshot_stage1_kind;
  logic signed [15:0] snapshot_stage1_direct_level;
  logic [4:0] snapshot_stage1_octave;
  logic [6:0] snapshot_stage1_mantissa_index;
  logic snapshot_stage2_valid;
  logic [1:0] snapshot_stage2_kind;
  logic signed [15:0] snapshot_stage2_direct_level;
  logic [4:0] snapshot_stage2_octave;
  logic [23:0] snapshot_stage2_mantissa;
  logic [4:0] snapshot_octave_next;
  logic [31:0] snapshot_residual_next;
  logic [31:0] snapshot_rounded_residual_next;
  logic [6:0] snapshot_mantissa_index_next;
  logic compressor_config_valid;

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

  function automatic logic [31:0] q15_to_cb(input logic signed [15:0] level);
    logic [14:0] magnitude;
    logic [14:0] normalized;
    logic [3:0] leading_zeros;
    logic [ENV_Q15_TO_CB_MANTISSA_BITS-1:0] mantissa_index;
    logic found;
    logic [32:0] approximation;
    begin
      q15_to_cb = ENV_CB_SILENCE_Q12_20;
      magnitude = level[14:0];
      normalized = '0;
      leading_zeros = '0;
      mantissa_index = '0;
      found = 1'b0;
      approximation = '0;
      if (level >= 16'sh7fff) begin
        q15_to_cb = 32'd0;
      end else if (level > 0) begin
        for (int bit_index = 14; bit_index >= 0; bit_index--) begin
          if (!found && magnitude[bit_index]) begin
            leading_zeros = 4'(14 - bit_index);
            found = 1'b1;
          end
        end
        normalized = magnitude << leading_zeros;
        mantissa_index = ENV_Q15_TO_CB_MANTISSA_BITS'(
            normalized >> (14 - ENV_Q15_TO_CB_MANTISSA_BITS));
        approximation =
            {1'b0, ENV_CB_OCTAVE_Q12_20_LUT[5'(leading_zeros)]} +
            {1'b0, ENV_Q15_TO_CB_MANTISSA_LUT[mantissa_index]};
        if (approximation < {1'b0, ENV_CB_SILENCE_Q12_20})
          q15_to_cb = approximation[31:0];
      end
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
    define_data.seq = action.seq;
    define_data.voice.enable = 1'b1;
    define_data.voice.stereo = action.opcode == VOICE_DEFINE_STEREO;
    define_data.voice.base_addr = action.payload[0];
    if (action.opcode == VOICE_DEFINE_STEREO) begin
      define_data.voice.base_addr_r = action.payload[1];
      define_data.voice.length = action.payload[2][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.length_r = action.payload[3][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_start = action.payload[4][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_start_r = action.payload[5][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_end = action.payload[6][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_end_r = action.payload[7][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.phase_init = action.payload[8];
      define_data.voice.loop_mode = action.payload[9][1:0];
      define_data.filter_b0 = action.payload[10][15:0];
      define_data.filter_b1 = action.payload[10][31:16];
      define_data.filter_b2 = action.payload[11][15:0];
      define_data.filter_a1 = action.payload[11][31:16];
      define_data.filter_a2 = action.payload[12][15:0];
      define_data.filter_enable = action.payload[12][16];
    end else begin
      define_data.voice.length = action.payload[1][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_start = action.payload[2][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.loop_end = action.payload[3][PHASE_FRAME_WIDTH-1:0];
      define_data.voice.phase_init = action.payload[4];
      define_data.voice.loop_mode = action.payload[5][1:0];
      define_data.filter_b0 = action.payload[6][15:0];
      define_data.filter_b1 = action.payload[6][31:16];
      define_data.filter_b2 = action.payload[7][15:0];
      define_data.filter_a1 = action.payload[7][31:16];
      define_data.filter_a2 = action.payload[8][15:0];
      define_data.filter_enable = action.payload[8][16];
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
    if (action.opcode == VOICE_DEFINE_STEREO)
      define_valid = define_valid && (define_data.voice.length_r != '0) &&
                     (define_data.voice.phase_init[31:8] < define_data.voice.length_r) &&
                     (action.payload[9][31:2] == '0) &&
                     (action.payload[12][31:17] == '0) &&
                     (action.payload[13] == '0) && (action.payload[14] == '0);
    else
      define_valid = define_valid && (action.payload[5][31:2] == '0) &&
                     (action.payload[8][31:17] == '0) &&
                     (action.payload[9] == '0) && (action.payload[10] == '0);

    prepared_read_data = prepared_voice_t'(prepared_read_word);
    active_read_data = active_voice_t'(active_read_word);
    debug_prepared_seq = prepared_read_data.seq;
    debug_active = active_read_data;
    action_seq_match = active_valid[action_voice] &&
                       (active_read_data.seq == current_action.seq);
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

    action_next_data = active_read_data;
    unique case (current_action.opcode)
      VOICE_START: begin
        action_next_data = '0;
        action_next_data.audible = 1'b1;
        action_next_data.seq = current_action.seq;
        action_next_data.voice = prepared_read_data.voice;
        action_next_data.phase_inc = current_action.payload[1];
        action_next_data.gain_l = current_action.payload[0][15:0];
        action_next_data.gain_r = current_action.payload[0][31:16];
        action_next_data.filter_enable = prepared_read_data.filter_enable;
        action_next_data.filter_b0 = prepared_read_data.filter_b0;
        action_next_data.filter_b1 = prepared_read_data.filter_b1;
        action_next_data.filter_b2 = prepared_read_data.filter_b2;
        action_next_data.filter_a1 = prepared_read_data.filter_a1;
        action_next_data.filter_a2 = prepared_read_data.filter_a2;
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
                if ((active_read_data.env_state.stage == ENV_DELAY) &&
                    (active_read_data.env_state.elapsed >= current_action.payload[payload_index][23:0]))
                  action_next_data.env_state.stage = ENV_ATTACK;
              end
              1: action_next_data.env_params.attack_step_q0_32 = current_action.payload[payload_index];
              2: begin
                action_next_data.env_params.hold_samples = current_action.payload[payload_index][23:0];
                if ((active_read_data.env_state.stage == ENV_HOLD) &&
                    (active_read_data.env_state.elapsed >= current_action.payload[payload_index][23:0])) begin
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
                if (active_read_data.env_state.stage == ENV_SUSTAIN) begin
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
          unique case (active_read_data.env_state.stage)
            ENV_ATTACK: action_next_data.env_state.attenuation_cb_q12_20 =
                q15_to_cb($signed({1'b0,
                    active_read_data.env_state.attack_level_q0_32[31:17]}));
            ENV_HOLD: action_next_data.env_state.attenuation_cb_q12_20 = '0;
            ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE:
                action_next_data.env_state.attenuation_cb_q12_20 =
                    active_read_data.env_state.attenuation_cb_q12_20;
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

    envelope_next_data = advance_envelope(active_read_data);
    action_ready = state == EXEC_IDLE;
    prepared_write = action_valid && action_ready &&
                     ((action.opcode == VOICE_DEFINE_MONO) ||
                      (action.opcode == VOICE_DEFINE_STEREO)) && define_valid;
    active_action_write = (state == EXEC_APPLY) && action_semantic_valid &&
                          (((current_action.opcode == VOICE_START) &&
                            prepared_valid[action_voice] &&
                            (prepared_read_data.seq == current_action.seq)) ||
                           ((current_action.opcode != VOICE_START) && action_seq_match));
    snapshot_accept = snapshot_prepare && (state == EXEC_IDLE);
    active_envelope_write = snapshot_accept && active_valid[snapshot_voice];
    active_write = active_action_write || active_envelope_write;
    active_write_voice = active_action_write ? action_voice : snapshot_voice;
    active_write_data = active_action_write ? action_next_data : envelope_next_data;

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
    snapshot_residual_next = snapshot_stage0_attenuation -
                             ENV_CB_OCTAVE_Q12_20_LUT[snapshot_octave_next];
    snapshot_rounded_residual_next = snapshot_residual_next +
        32'(1 << (ENV_CB_TO_Q15_RESIDUAL_INDEX_SHIFT - 1));
    snapshot_mantissa_index_next = 7'(
        snapshot_rounded_residual_next >> ENV_CB_TO_Q15_RESIDUAL_INDEX_SHIFT);
    config_valid = active_valid;
  end

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES), .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(PREPARED_WIDTH), .DEFAULT_WORD('0)
  ) prepared_ram (
    .clk, .write_en(prepared_write), .write_addr(action.voice[VOICE_ID_WIDTH-1:0]),
    .write_data(define_data), .read_addr(prepared_read_voice), .read_data(prepared_read_word)
  );

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES), .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(ACTIVE_WIDTH), .DEFAULT_WORD('0)
  ) active_ram (
    .clk, .write_en(active_write), .write_addr(active_write_voice),
    .write_data(active_write_data), .read_addr(active_read_voice), .read_data(active_read_word)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= EXEC_IDLE;
      current_action <= '0;
      action_voice <= '0;
      prepared_valid <= '0;
      active_valid <= '0;
      pending_commit <= '0;
      commit_pulse <= '0;
      action_done <= 1'b0;
      stream_flush <= 1'b0;
      command_error_pulse <= 1'b0;
      stale_seq_pulse <= 1'b0;
      snapshot_valid <= 1'b0;
      snapshot_stage0_valid <= 1'b0;
      snapshot_stage0_kind <= SNAPSHOT_LEVEL_ZERO;
      snapshot_stage0_direct_level <= '0;
      snapshot_stage0_attenuation <= '0;
      snapshot_stage1_valid <= 1'b0;
      snapshot_stage1_kind <= SNAPSHOT_LEVEL_ZERO;
      snapshot_stage1_direct_level <= '0;
      snapshot_stage1_octave <= '0;
      snapshot_stage1_mantissa_index <= '0;
      snapshot_stage2_valid <= 1'b0;
      snapshot_stage2_kind <= SNAPSHOT_LEVEL_ZERO;
      snapshot_stage2_direct_level <= '0;
      snapshot_stage2_octave <= '0;
      snapshot_stage2_mantissa <= '0;
      render_config <= '0;
      render_runtime <= '0;
      compressor_config <= '0;
      master_volume <= 16'sh7fff;
    end else begin
      action_done <= 1'b0;
      stream_flush <= 1'b0;
      command_error_pulse <= 1'b0;
      stale_seq_pulse <= 1'b0;
      snapshot_valid <= snapshot_stage2_valid;
      snapshot_stage0_valid <= snapshot_accept;
      snapshot_stage1_valid <= snapshot_stage0_valid;
      snapshot_stage2_valid <= snapshot_stage1_valid;

      if (snapshot_accept) begin
        render_config <= active_read_data.voice;
        render_config.enable <= active_envelope_write &&
                                active_read_data.voice.enable &&
                                envelope_next_data.audible;
        render_runtime.phase_inc <= active_read_data.phase_inc;
        render_runtime.gain_l <= active_read_data.gain_l;
        render_runtime.gain_r <= active_read_data.gain_r;
        render_runtime.envelope_delay <= active_envelope_write &&
                                         envelope_next_data.audible &&
                                         (envelope_next_data.env_state.stage == ENV_DELAY);
        render_runtime.released <= active_read_data.released;
        render_runtime.filter_enable <= active_read_data.filter_enable;
        render_runtime.filter_b0 <= active_read_data.filter_b0;
        render_runtime.filter_b1 <= active_read_data.filter_b1;
        render_runtime.filter_b2 <= active_read_data.filter_b2;
        render_runtime.filter_a1 <= active_read_data.filter_a1;
        render_runtime.filter_a2 <= active_read_data.filter_a2;
        snapshot_stage0_kind <= SNAPSHOT_LEVEL_ZERO;
        snapshot_stage0_direct_level <= '0;
        snapshot_stage0_attenuation <= envelope_next_data.env_state.attenuation_cb_q12_20;
        if (active_envelope_write && envelope_next_data.audible &&
            (envelope_next_data.env_state.stage == ENV_ATTACK)) begin
          snapshot_stage0_kind <= SNAPSHOT_LEVEL_DIRECT;
          snapshot_stage0_direct_level <= $signed(
              {1'b0, envelope_next_data.env_state.attack_level_q0_32[31:17]});
        end else if (active_envelope_write && envelope_next_data.audible &&
                     (envelope_next_data.env_state.stage == ENV_HOLD)) begin
          snapshot_stage0_kind <= SNAPSHOT_LEVEL_DIRECT;
          snapshot_stage0_direct_level <= 16'sh7fff;
        end else if (active_envelope_write && envelope_next_data.audible &&
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
        snapshot_stage1_mantissa_index <= snapshot_mantissa_index_next;
      end

      if (snapshot_stage1_valid) begin
        snapshot_stage2_kind <= snapshot_stage1_kind;
        snapshot_stage2_direct_level <= snapshot_stage1_direct_level;
        snapshot_stage2_octave <= snapshot_stage1_octave;
        snapshot_stage2_mantissa <=
            ENV_CB_TO_Q15_MANTISSA_LUT[snapshot_stage1_mantissa_index];
      end

      if (snapshot_stage2_valid) begin
        unique case (snapshot_stage2_kind)
          SNAPSHOT_LEVEL_DIRECT:
              render_runtime.envelope_level <= snapshot_stage2_direct_level;
          SNAPSHOT_LEVEL_CB:
              render_runtime.envelope_level <= scaled_mantissa_to_q15(
                  snapshot_stage2_mantissa, snapshot_stage2_octave);
          default: render_runtime.envelope_level <= 16'sh0000;
        endcase
      end
      commit_pulse <= pending_commit;
      if (frame_start)
        pending_commit <= '0;

      if (prepared_write) begin
        prepared_valid[action.voice] <= 1'b1;
      end
      if (active_envelope_write && !envelope_next_data.audible)
        active_valid[snapshot_voice] <= 1'b0;

      unique case (state)
        EXEC_IDLE: begin
          if (action_valid && action_ready) begin
            if ((action.opcode == VOICE_DEFINE_MONO) ||
                (action.opcode == VOICE_DEFINE_STEREO)) begin
              if (!define_valid)
                command_error_pulse <= 1'b1;
              action_done <= 1'b1;
            end else if (action.opcode == STREAM_FLUSH) begin
              stream_flush <= 1'b1;
              action_done <= 1'b1;
            end else if (action.opcode == COMPRESSOR_CONFIG) begin
              if (!compressor_config_valid) begin
                command_error_pulse <= 1'b1;
              end else begin
                compressor_config.enable <= action.payload[0][0];
                compressor_config.threshold_cb_q12_20 <= action.payload[1];
                compressor_config.ratio_slope_q0_16 <= action.payload[0][16:1];
                compressor_config.attack_step_cb_q12_20 <= action.payload[2];
                compressor_config.release_step_cb_q12_20 <= action.payload[3];
              end
              action_done <= 1'b1;
            end else if (action.opcode == MASTER_VOLUME) begin
              if (action.payload[0][31:15] != '0)
                command_error_pulse <= 1'b1;
              else
                master_volume <= $signed(action.payload[0][15:0]);
              action_done <= 1'b1;
            end else begin
              current_action <= action;
              action_voice <= action.voice[VOICE_ID_WIDTH-1:0];
              state <= EXEC_READ;
            end
          end
        end
        EXEC_READ: state <= EXEC_APPLY;
        EXEC_APPLY: begin
          if (!action_semantic_valid) begin
            command_error_pulse <= 1'b1;
          end else if ((current_action.opcode == VOICE_START) ?
                       !(prepared_valid[action_voice] &&
                         (prepared_read_data.seq == current_action.seq)) :
                       !action_seq_match) begin
            stale_seq_pulse <= 1'b1;
          end else begin
            if (current_action.opcode == VOICE_START) begin
              active_valid[action_voice] <= 1'b1;
              pending_commit[action_voice] <= 1'b1;
            end else if ((current_action.opcode == VOICE_STOP) ||
                         ((current_action.opcode == VOICE_RELEASE) &&
                          (current_action.payload[0] == '0))) begin
              active_valid[action_voice] <= 1'b0;
            end
          end
          action_done <= 1'b1;
          state <= EXEC_IDLE;
        end
        default: state <= EXEC_IDLE;
      endcase
    end
  end
endmodule
