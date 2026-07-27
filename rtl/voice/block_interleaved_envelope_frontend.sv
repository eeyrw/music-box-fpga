module block_interleaved_envelope_frontend (
  input  logic                                      clk,
  input  logic                                      rst,
  input  logic                                      start_valid,
  output logic                                      start_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      start_voice_index,
  input  logic [synth_pkg::BLOCK_FRAME_COUNT_WIDTH-1:0]
                                                    start_frame_count,
  input  synth_pkg::voice_playback_region_t         start_region,
  input  synth_pkg::voice_event_params_t            start_params,
  input  synth_pkg::volume_env_params_t             start_env_params,
  input  synth_pkg::voice_dynamic_state_t           start_dynamic,

  output logic                                      result_valid,
  input  logic                                      result_ready,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]      result_voice_index,
  output logic [synth_pkg::BLOCK_FRAME_COUNT_WIDTH-1:0]
                                                    result_frame_count,
  output synth_pkg::voice_playback_region_t         result_region,
  output synth_pkg::voice_event_params_t            result_params,
  output synth_pkg::voice_dynamic_state_t           result_dynamic,
  output synth_pkg::block_envelope_result_t         result_envelope
);
  import synth_pkg::*;
  import synth_dsp_lut_pkg::*;

  localparam int SLOT_COUNT = BLOCK_WORK_ENTRY_COUNT;
  localparam int SLOT_ID_WIDTH = $clog2(SLOT_COUNT);
  localparam logic [1:0] LEVEL_ZERO = 2'd0;
  localparam logic [1:0] LEVEL_DIRECT = 2'd1;
  localparam logic [1:0] LEVEL_CB = 2'd2;

  typedef enum logic [1:0] {SLOT_FREE, SLOT_WALK, SLOT_DRAIN, SLOT_READY} slot_state_t;
  typedef struct packed {
    logic valid;
    logic [SLOT_ID_WIDTH-1:0] slot;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic last;
    logic [1:0] level_kind;
    logic signed [15:0] direct_level;
    logic [31:0] attenuation;
  } level_stage0_t;
  typedef struct packed {
    logic valid;
    logic [SLOT_ID_WIDTH-1:0] slot;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic last;
    logic [1:0] level_kind;
    logic signed [15:0] direct_level;
    logic [31:0] attenuation;
    logic [4:0] octave;
  } level_stage1_t;
  typedef struct packed {
    logic valid;
    logic [SLOT_ID_WIDTH-1:0] slot;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic last;
    logic [1:0] level_kind;
    logic signed [15:0] direct_level;
    logic [4:0] octave;
    logic [6:0] mantissa_index;
  } level_stage2_t;
  typedef struct packed {
    logic valid;
    logic [SLOT_ID_WIDTH-1:0] slot;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic last;
    logic [1:0] level_kind;
    logic signed [15:0] direct_level;
    logic [4:0] octave;
    logic [23:0] mantissa;
  } level_stage3_t;

  slot_state_t slot_state_q [0:SLOT_COUNT-1];
  logic [VOICE_ID_WIDTH-1:0] voice_index_q [0:SLOT_COUNT-1];
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] frame_count_q [0:SLOT_COUNT-1];
  voice_playback_region_t region_q [0:SLOT_COUNT-1];
  voice_event_params_t params_q [0:SLOT_COUNT-1];
  volume_env_params_t env_params_q [0:SLOT_COUNT-1];
  voice_dynamic_state_t dynamic_q [0:SLOT_COUNT-1];
  logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index_q [0:SLOT_COUNT-1];
  block_envelope_result_t envelope_q [0:SLOT_COUNT-1];

  logic [SLOT_ID_WIDTH-1:0] walk_rr_q;
  logic walk_found;
  logic [SLOT_ID_WIDTH-1:0] walk_slot;
  logic [SLOT_ID_WIDTH-1:0] result_rr_q;
  logic result_found;
  logic [SLOT_ID_WIDTH-1:0] result_slot;
  logic free_found;
  logic [SLOT_ID_WIDTH-1:0] free_slot;
  logic result_fire;
  logic start_fire;

  volume_env_state_t advanced_state;
  logic advanced_active;
  logic [32:0] attack_sum;
  logic [32:0] cb_sum;
  logic render_frame;
  logic phase_advance_frame;
  logic [1:0] next_level_kind;
  logic signed [15:0] next_direct_level;

  level_stage0_t level_s0_q;
  level_stage1_t level_s1_q;
  level_stage2_t level_s2_q;
  level_stage3_t level_s3_q;
  logic [4:0] octave_next;
  logic [31:0] residual;
  logic [31:0] rounded_residual;
  logic [23:0] scaled_mantissa;
  logic [24:0] rounded_mantissa;

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

  always_comb begin
    walk_found = 1'b0;
    walk_slot = '0;
    for (int offset = 0; offset < SLOT_COUNT; offset++) begin
      logic [SLOT_ID_WIDTH-1:0] candidate;
      candidate = walk_rr_q + SLOT_ID_WIDTH'(offset);
      if (!walk_found && (slot_state_q[candidate] == SLOT_WALK)) begin
        walk_found = 1'b1;
        walk_slot = candidate;
      end
    end

    result_found = 1'b0;
    result_slot = '0;
    for (int offset = 0; offset < SLOT_COUNT; offset++) begin
      logic [SLOT_ID_WIDTH-1:0] candidate;
      candidate = result_rr_q + SLOT_ID_WIDTH'(offset);
      if (!result_found && (slot_state_q[candidate] == SLOT_READY)) begin
        result_found = 1'b1;
        result_slot = candidate;
      end
    end
  end

  assign result_valid = result_found;
  assign result_fire = result_valid && result_ready;
  assign result_voice_index = voice_index_q[result_slot];
  assign result_frame_count = frame_count_q[result_slot];
  assign result_region = region_q[result_slot];
  assign result_params = params_q[result_slot];
  assign result_dynamic = dynamic_q[result_slot];
  assign result_envelope = envelope_q[result_slot];
  assign start_fire = start_valid && start_ready;

  always_comb begin
    advanced_state = dynamic_q[walk_slot].env_state;
    advanced_active = dynamic_q[walk_slot].active;
    attack_sum = {1'b0, dynamic_q[walk_slot].env_state.attack_level_q0_32} +
                 {1'b0, env_params_q[walk_slot].attack_step_q0_32};
    cb_sum = {1'b0, dynamic_q[walk_slot].env_state.attenuation_cb_q12_20};
    if (dynamic_q[walk_slot].active) begin
      unique case (dynamic_q[walk_slot].env_state.stage)
        ENV_DELAY: begin
          if ((dynamic_q[walk_slot].env_state.elapsed + 1'b1) >=
              env_params_q[walk_slot].delay_samples) begin
            advanced_state.elapsed = '0;
            if (env_params_q[walk_slot].attack_step_q0_32 == '0) begin
              advanced_state.attack_level_q0_32 = 32'hffff_ffff;
              advanced_state.stage = stage_after_attack(
                  env_params_q[walk_slot].hold_samples,
                  env_params_q[walk_slot].sustain_cb_q12_20,
                  env_params_q[walk_slot].decay_step_cb_q12_20);
              if (advanced_state.stage == ENV_SUSTAIN)
                advanced_state.attenuation_cb_q12_20 =
                    env_params_q[walk_slot].sustain_cb_q12_20;
            end else begin
              advanced_state.stage = ENV_ATTACK;
            end
          end else begin
            advanced_state.elapsed =
                dynamic_q[walk_slot].env_state.elapsed + 1'b1;
          end
        end
        ENV_ATTACK: begin
          if (attack_sum[32] || (attack_sum[31:0] >= 32'hffff_ffff)) begin
            advanced_state.attack_level_q0_32 = 32'hffff_ffff;
            advanced_state.elapsed = '0;
            advanced_state.stage = stage_after_attack(
                env_params_q[walk_slot].hold_samples,
                env_params_q[walk_slot].sustain_cb_q12_20,
                env_params_q[walk_slot].decay_step_cb_q12_20);
            if (advanced_state.stage == ENV_SUSTAIN)
              advanced_state.attenuation_cb_q12_20 =
                  env_params_q[walk_slot].sustain_cb_q12_20;
          end else begin
            advanced_state.attack_level_q0_32 = attack_sum[31:0];
          end
        end
        ENV_HOLD: begin
          if ((dynamic_q[walk_slot].env_state.elapsed + 1'b1) >=
              env_params_q[walk_slot].hold_samples) begin
            advanced_state.elapsed = '0;
            if ((env_params_q[walk_slot].sustain_cb_q12_20 != '0) &&
                (env_params_q[walk_slot].decay_step_cb_q12_20 != '0))
              advanced_state.stage = ENV_DECAY;
            else begin
              advanced_state.stage = ENV_SUSTAIN;
              advanced_state.attenuation_cb_q12_20 =
                  env_params_q[walk_slot].sustain_cb_q12_20;
            end
          end else begin
            advanced_state.elapsed =
                dynamic_q[walk_slot].env_state.elapsed + 1'b1;
          end
        end
        ENV_DECAY: begin
          if (dynamic_q[walk_slot].env_state.attenuation_cb_q12_20 <
              env_params_q[walk_slot].sustain_cb_q12_20) begin
            cb_sum =
                {1'b0, dynamic_q[walk_slot].env_state.attenuation_cb_q12_20} +
                {1'b0, env_params_q[walk_slot].decay_step_cb_q12_20};
            if (cb_sum[32] ||
                (cb_sum[31:0] >= env_params_q[walk_slot].sustain_cb_q12_20)) begin
              advanced_state.attenuation_cb_q12_20 =
                  env_params_q[walk_slot].sustain_cb_q12_20;
              advanced_state.stage = ENV_SUSTAIN;
            end else begin
              advanced_state.attenuation_cb_q12_20 = cb_sum[31:0];
            end
          end else if (dynamic_q[walk_slot].env_state.attenuation_cb_q12_20 >
                       env_params_q[walk_slot].sustain_cb_q12_20) begin
            if ((dynamic_q[walk_slot].env_state.attenuation_cb_q12_20 -
                 env_params_q[walk_slot].sustain_cb_q12_20) <=
                env_params_q[walk_slot].decay_step_cb_q12_20) begin
              advanced_state.attenuation_cb_q12_20 =
                  env_params_q[walk_slot].sustain_cb_q12_20;
              advanced_state.stage = ENV_SUSTAIN;
            end else begin
              advanced_state.attenuation_cb_q12_20 =
                  dynamic_q[walk_slot].env_state.attenuation_cb_q12_20 -
                  env_params_q[walk_slot].decay_step_cb_q12_20;
            end
          end else begin
            advanced_state.stage = ENV_SUSTAIN;
          end
        end
        ENV_SUSTAIN:
          advanced_state.attenuation_cb_q12_20 =
              env_params_q[walk_slot].sustain_cb_q12_20;
        ENV_RELEASE: begin
          cb_sum =
              {1'b0, dynamic_q[walk_slot].env_state.attenuation_cb_q12_20} +
              {1'b0, env_params_q[walk_slot].release_step_cb_q12_20};
          if (cb_sum[32] || (cb_sum[31:0] >= ENV_CB_SILENCE_Q12_20)) begin
            advanced_state.attenuation_cb_q12_20 = ENV_CB_SILENCE_Q12_20;
            advanced_active = 1'b0;
          end else begin
            advanced_state.attenuation_cb_q12_20 = cb_sum[31:0];
          end
        end
        default: advanced_state.stage = ENV_DELAY;
      endcase
    end

    render_frame = advanced_active && (advanced_state.stage != ENV_DELAY);
    phase_advance_frame = advanced_active;
    next_level_kind = LEVEL_ZERO;
    next_direct_level = '0;
    if (advanced_active && (advanced_state.stage == ENV_ATTACK)) begin
      next_level_kind = LEVEL_DIRECT;
      next_direct_level = $signed(
          {1'b0, advanced_state.attack_level_q0_32[31:17]});
    end else if (advanced_active && (advanced_state.stage == ENV_HOLD)) begin
      next_level_kind = LEVEL_DIRECT;
      next_direct_level = 16'sh7fff;
    end else if (advanced_active && (advanced_state.stage != ENV_DELAY) &&
                 (advanced_state.attenuation_cb_q12_20 <
                  ENV_CB_SILENCE_Q12_20)) begin
      next_level_kind = LEVEL_CB;
    end

    octave_next = '0;
    if (level_s0_q.attenuation >= ENV_CB_OCTAVE_Q12_20_LUT[16]) begin
      octave_next = 5'd16;
    end else begin
      if (level_s0_q.attenuation >= ENV_CB_OCTAVE_Q12_20_LUT[8])
        octave_next = 5'd8;
      if (level_s0_q.attenuation >=
          ENV_CB_OCTAVE_Q12_20_LUT[octave_next + 5'd4])
        octave_next = octave_next + 5'd4;
      if (level_s0_q.attenuation >=
          ENV_CB_OCTAVE_Q12_20_LUT[octave_next + 5'd2])
        octave_next = octave_next + 5'd2;
      if (level_s0_q.attenuation >=
          ENV_CB_OCTAVE_Q12_20_LUT[octave_next + 5'd1])
        octave_next = octave_next + 5'd1;
    end
    residual = level_s1_q.attenuation -
               ENV_CB_OCTAVE_Q12_20_LUT[level_s1_q.octave];
    rounded_residual = residual +
        32'(1 << (ENV_CB_TO_Q15_RESIDUAL_INDEX_SHIFT - 1));
    scaled_mantissa = level_s3_q.mantissa >> level_s3_q.octave;
    rounded_mantissa = {1'b0, scaled_mantissa} +
        25'(1 << (ENV_CB_TO_Q15_GUARD_BITS - 1));

    free_found = 1'b0;
    free_slot = '0;
    for (int slot = 0; slot < SLOT_COUNT; slot++) begin
      if (!free_found && (slot_state_q[slot] == SLOT_FREE)) begin
        free_found = 1'b1;
        free_slot = SLOT_ID_WIDTH'(slot);
      end
    end
    if (!free_found && result_fire) begin
      free_found = 1'b1;
      free_slot = result_slot;
    end
    start_ready = free_found && (start_frame_count != '0) &&
        (start_frame_count <= BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES));
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      walk_rr_q <= '0;
      result_rr_q <= '0;
      level_s0_q <= '0;
      level_s1_q <= '0;
      level_s2_q <= '0;
      level_s3_q <= '0;
      for (int slot = 0; slot < SLOT_COUNT; slot++) begin
        slot_state_q[slot] <= SLOT_FREE;
        voice_index_q[slot] <= '0;
        frame_count_q[slot] <= '0;
        region_q[slot] <= '0;
        params_q[slot] <= '0;
        env_params_q[slot] <= '0;
        dynamic_q[slot] <= '0;
        frame_index_q[slot] <= '0;
        envelope_q[slot] <= '0;
      end
    end else begin
      level_s0_q.valid <= walk_found;
      if (walk_found) begin
        level_s0_q.slot <= walk_slot;
        level_s0_q.frame_index <= frame_index_q[walk_slot];
        level_s0_q.last <=
            (BLOCK_FRAME_COUNT_WIDTH'(frame_index_q[walk_slot]) + 1'b1) >=
            frame_count_q[walk_slot];
        level_s0_q.level_kind <= next_level_kind;
        level_s0_q.direct_level <= next_direct_level;
        level_s0_q.attenuation <= advanced_state.attenuation_cb_q12_20;
        walk_rr_q <= walk_slot + 1'b1;
        dynamic_q[walk_slot].env_state <= advanced_state;
        dynamic_q[walk_slot].active <= advanced_active;
        envelope_q[walk_slot].phase_advance_mask[frame_index_q[walk_slot]] <=
            phase_advance_frame;
        envelope_q[walk_slot].render_mask[frame_index_q[walk_slot]] <=
            render_frame;
        if ((BLOCK_FRAME_COUNT_WIDTH'(frame_index_q[walk_slot]) + 1'b1) >=
            frame_count_q[walk_slot]) begin
          envelope_q[walk_slot].active <= advanced_active;
          envelope_q[walk_slot].env_state <= advanced_state;
          slot_state_q[walk_slot] <= SLOT_DRAIN;
        end else begin
          frame_index_q[walk_slot] <= frame_index_q[walk_slot] + 1'b1;
        end
      end

      level_s1_q.valid <= level_s0_q.valid;
      level_s1_q.slot <= level_s0_q.slot;
      level_s1_q.frame_index <= level_s0_q.frame_index;
      level_s1_q.last <= level_s0_q.last;
      level_s1_q.level_kind <= level_s0_q.level_kind;
      level_s1_q.direct_level <= level_s0_q.direct_level;
      level_s1_q.attenuation <= level_s0_q.attenuation;
      level_s1_q.octave <= octave_next;
      level_s2_q.valid <= level_s1_q.valid;
      level_s2_q.slot <= level_s1_q.slot;
      level_s2_q.frame_index <= level_s1_q.frame_index;
      level_s2_q.last <= level_s1_q.last;
      level_s2_q.level_kind <= level_s1_q.level_kind;
      level_s2_q.direct_level <= level_s1_q.direct_level;
      level_s2_q.octave <= level_s1_q.octave;
      level_s2_q.mantissa_index <= 7'(
          rounded_residual >> ENV_CB_TO_Q15_RESIDUAL_INDEX_SHIFT);
      level_s3_q.valid <= level_s2_q.valid;
      level_s3_q.slot <= level_s2_q.slot;
      level_s3_q.frame_index <= level_s2_q.frame_index;
      level_s3_q.last <= level_s2_q.last;
      level_s3_q.level_kind <= level_s2_q.level_kind;
      level_s3_q.direct_level <= level_s2_q.direct_level;
      level_s3_q.octave <= level_s2_q.octave;
      level_s3_q.mantissa <=
          ENV_CB_TO_Q15_MANTISSA_LUT[level_s2_q.mantissa_index];

      if (level_s3_q.valid) begin
        unique case (level_s3_q.level_kind)
          LEVEL_DIRECT:
            envelope_q[level_s3_q.slot]
                .envelope_levels[level_s3_q.frame_index] <=
                level_s3_q.direct_level;
          LEVEL_CB:
            envelope_q[level_s3_q.slot]
                .envelope_levels[level_s3_q.frame_index] <=
                $signed(16'(rounded_mantissa >> ENV_CB_TO_Q15_GUARD_BITS));
          default:
            envelope_q[level_s3_q.slot]
                .envelope_levels[level_s3_q.frame_index] <= 16'sh0000;
        endcase
        if (level_s3_q.last)
          slot_state_q[level_s3_q.slot] <= SLOT_READY;
      end

      if (result_fire) begin
        result_rr_q <= result_slot + 1'b1;
        slot_state_q[result_slot] <= SLOT_FREE;
      end

      if (start_fire) begin
        slot_state_q[free_slot] <= SLOT_WALK;
        voice_index_q[free_slot] <= start_voice_index;
        frame_count_q[free_slot] <= start_frame_count;
        region_q[free_slot] <= start_region;
        params_q[free_slot] <= start_params;
        env_params_q[free_slot] <= start_env_params;
        dynamic_q[free_slot] <= start_dynamic;
        frame_index_q[free_slot] <= '0;
        envelope_q[free_slot] <= '0;
      end
    end
  end
endmodule
