module envelope_event_engine (
  input  logic clk,
  input  logic rst,
  input  logic [31:0] current_sample,
  input  logic snapshot_prepare,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] snapshot_voice,
  input  logic signed [15:0] manual_envelope_level,
  input  logic manual_envelope_write,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] manual_envelope_write_voice,
  input  synth_pkg::envelope_event_t event_head,
  input  logic event_head_valid,
  input  synth_pkg::envelope_event_t event_head1,
  input  logic event_head1_valid,
  input  synth_pkg::envelope_event_t event_head2,
  input  logic event_head2_valid,
  input  synth_pkg::envelope_event_t event_head3,
  input  logic event_head3_valid,
  output logic [2:0] event_pop_count,
  output logic signed [15:0] prepared_envelope_level,
  output logic prepared_envelope_active,
  output logic release_write,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0] release_write_voice,
  output logic release_write_value,
  output logic late_flag,
  output logic order_error_flag
);
  import synth_pkg::*;
  import synth_envelope_lut_pkg::*;

  localparam logic [2:0] ENV_MODE_HOLD = 3'd0;
  localparam logic [2:0] ENV_MODE_ATTACK = 3'd1;
  localparam logic [2:0] ENV_MODE_DECAY_CB = 3'd2;
  localparam logic [2:0] ENV_MODE_RELEASE_CB = 3'd3;

  typedef struct packed {
    logic [2:0] mode;
    logic signed [ENV_GAIN_Q23_WIDTH-1:0] gain_q23;
    logic [ENV_CB_WIDTH-1:0] cb_q8_8;
    logic [31:0] step;
    logic [31:0] target;
    logic [31:0] phase;
    logic [31:0] duration;
    logic active;
    logic signed [15:0] envelope;
    logic release_write;
    logic release_value;
  } env_next_t;

  logic [2:0] state_mode;
  logic signed [ENV_GAIN_Q23_WIDTH-1:0] state_gain_q23;
  logic [ENV_CB_WIDTH-1:0] state_cb_q8_8;
  logic [31:0] state_step;
  logic [31:0] state_target;
  logic [31:0] state_phase;
  logic [31:0] state_duration;
  logic state_active;

  logic store_write;
  logic [VOICE_ID_WIDTH-1:0] store_write_voice;
  logic [2:0] store_write_mode;
  logic signed [ENV_GAIN_Q23_WIDTH-1:0] store_write_gain_q23;
  logic [ENV_CB_WIDTH-1:0] store_write_cb_q8_8;
  logic [31:0] store_write_step;
  logic [31:0] store_write_target;
  logic [31:0] store_write_phase;
  logic [31:0] store_write_duration;
  logic store_write_active;

  logic signed [15:0] next_envelope;
  logic next_active;
  logic [2:0] next_mode;
  logic signed [ENV_GAIN_Q23_WIDTH-1:0] next_gain_q23;
  logic [ENV_CB_WIDTH-1:0] next_cb_q8_8;
  logic [31:0] next_step;
  logic [31:0] next_target;
  logic [31:0] next_phase;
  logic [31:0] next_duration;
  logic signed [31:0] gain_step_signed;
  logic signed [31:0] gain_next_signed;
  logic [32:0] phase_next_wide;
  logic [ENV_CB_WIDTH-1:0] ramp_cb_next;
  env_next_t event_calc;

  envelope_state_store state_store (
    .clk,
    .rst,
    .write_en(store_write),
    .write_voice(store_write_voice),
    .write_mode(store_write_mode),
    .write_gain_q23(store_write_gain_q23),
    .write_cb_q8_8(store_write_cb_q8_8),
    .write_step(store_write_step),
    .write_target(store_write_target),
    .write_phase(store_write_phase),
    .write_duration(store_write_duration),
    .write_active(store_write_active),
    .read_voice(snapshot_voice),
    .read_mode(state_mode),
    .read_gain_q23(state_gain_q23),
    .read_cb_q8_8(state_cb_q8_8),
    .read_step(state_step),
    .read_target(state_target),
    .read_phase(state_phase),
    .read_duration(state_duration),
    .read_active(state_active)
  );

  function automatic logic signed [15:0] clamp_q15_signed(input logic signed [31:0] value);
    if (value > 32'sd32767)
      clamp_q15_signed = 16'sh7fff;
    else if (value < 32'sd0)
      clamp_q15_signed = 16'sh0000;
    else
      clamp_q15_signed = value[15:0];
  endfunction

  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic signed [15:0] cb_to_q15(input logic [ENV_CB_WIDTH-1:0] cb_q8_8);
    logic [31:0] cb_wide;
    logic [7:0] index;
    logic [9:0] fraction;
    logic [31:0] delta;
    logic [31:0] interp;
    begin
      cb_wide = {8'd0, cb_q8_8};
      if (cb_wide >= ENV_CB_SILENCE_Q8_8) begin
        cb_to_q15 = 16'sh0000;
      end else begin
        index = cb_wide[17:10];
        fraction = cb_wide[9:0];
        delta = {16'd0, CB_TO_Q15_LUT[index]} - {16'd0, CB_TO_Q15_LUT[index + 8'd1]};
        interp = {16'd0, CB_TO_Q15_LUT[index]} - ((delta * {22'd0, fraction} + 32'd512) >> 10);
        cb_to_q15 = interp[15:0];
      end
    end
  endfunction

  function automatic logic event_matches_snapshot(
    input envelope_event_t event_word,
    input logic event_valid
  );
    event_matches_snapshot = snapshot_prepare && event_valid &&
                             (event_word.timestamp <= current_sample) &&
                             (event_word.voice[VOICE_ID_WIDTH-1:0] == snapshot_voice);
  endfunction

  function automatic logic event_is_due(input envelope_event_t event_word,
                                        input logic event_valid);
    event_is_due = snapshot_prepare && event_valid && (event_word.timestamp <= current_sample);
  endfunction

  function automatic logic event_is_late(input envelope_event_t event_word,
                                         input logic event_valid);
    event_is_late = event_is_due(event_word, event_valid) &&
                    (event_word.timestamp < current_sample);
  endfunction

  function automatic logic event_is_order_error(input envelope_event_t event_word,
                                                input logic event_valid);
    event_is_order_error = event_is_due(event_word, event_valid) &&
                           (event_word.timestamp == current_sample) &&
                           (event_word.voice[VOICE_ID_WIDTH-1:0] < snapshot_voice);
  endfunction

  function automatic logic [31:0] duration24_or_one(input logic [31:0] duration);
    begin
      duration24_or_one = {8'd0, duration[23:0]};
      if (duration24_or_one == 32'd0) begin
        duration24_or_one = 32'd1;
      end
    end
  endfunction

  function automatic logic [31:0] phase_inc_for_duration(input logic [31:0] duration);
    logic [31:0] clipped_duration;
    logic [32:0] numerator;
    begin
      clipped_duration = duration24_or_one(duration);
      if (clipped_duration <= 32'd1) begin
        phase_inc_for_duration = 32'hffff_ffff;
      end else begin
        numerator = 33'h1_0000_0000 + {1'b0, clipped_duration} - 33'd1;
        phase_inc_for_duration = 32'(numerator / {1'b0, clipped_duration});
      end
    end
  endfunction

  function automatic logic [ENV_CB_WIDTH-1:0] ramp_cb_q8_8(
    input logic [ENV_CB_WIDTH-1:0] start_cb_q8_8,
    input logic [ENV_CB_WIDTH-1:0] target_cb_q8_8,
    input logic [31:0] phase_q0_32
  );
    logic [ENV_CB_WIDTH-1:0] delta;
    logic [63:0] scaled;
    begin
      if (target_cb_q8_8 <= start_cb_q8_8) begin
        ramp_cb_q8_8 = target_cb_q8_8;
      end else begin
        delta = target_cb_q8_8 - start_cb_q8_8;
        scaled = {40'd0, delta} * {32'd0, phase_q0_32};
        ramp_cb_q8_8 = start_cb_q8_8 + ENV_CB_WIDTH'(scaled >> 32);
      end
    end
  endfunction

  function automatic env_next_t apply_event_calc(input env_next_t in_state,
                                                 input envelope_event_t event_word);
    env_next_t out_state;
    begin
      out_state = in_state;
      unique case (event_word.opcode)
        EVT_ENV_SET: begin
          out_state.active = 1'b1;
          out_state.phase = 32'd0;
          out_state.mode = ENV_MODE_HOLD;
          out_state.gain_q23 = $signed({event_word.payload0, 8'd0});
          out_state.envelope = $signed(event_word.payload0);
        end
        EVT_VOL_ATTACK: begin
          out_state.active = 1'b1;
          out_state.phase = 32'd0;
          out_state.mode = ENV_MODE_ATTACK;
          out_state.gain_q23 = '0;
          out_state.target = {16'd0, event_word.payload0};
          out_state.duration = duration24_or_one(event_word.payload1);
          out_state.step = ({8'd0, event_word.payload0, 8'd0} /
                            duration24_or_one(event_word.payload1));
          out_state.envelope = 16'sh0000;
        end
        EVT_VOL_DECAY_CB: begin
          out_state.active = 1'b1;
          out_state.phase = 32'd0;
          out_state.mode = ENV_MODE_DECAY_CB;
          out_state.cb_q8_8 = {event_word.payload0, 8'd0};
          out_state.target = {8'd0, event_word.payload1[15:0], 8'd0};
          out_state.duration = duration24_or_one(event_word.payload2);
          out_state.step = phase_inc_for_duration(event_word.payload2);
          out_state.envelope = cb_to_q15({event_word.payload0, 8'd0});
          out_state.gain_q23 = $signed({cb_to_q15({event_word.payload0, 8'd0}), 8'd0});
        end
        EVT_VOL_RELEASE_CB: begin
          out_state.active = 1'b1;
          out_state.phase = 32'd0;
          out_state.mode = ENV_MODE_RELEASE_CB;
          out_state.cb_q8_8 = {event_word.payload0, 8'd0};
          out_state.target = ENV_CB_SILENCE_Q8_8;
          out_state.duration = duration24_or_one(event_word.payload2);
          out_state.step = phase_inc_for_duration(event_word.payload2);
          out_state.envelope = cb_to_q15({event_word.payload0, 8'd0});
          out_state.gain_q23 = $signed({cb_to_q15({event_word.payload0, 8'd0}), 8'd0});
        end
        EVT_RELEASE_FLAG: begin
          out_state.release_write = 1'b1;
          out_state.release_value = 1'b1;
        end
        EVT_STOP_VOICE: begin
          out_state.active = 1'b0;
          out_state.gain_q23 = '0;
          out_state.mode = ENV_MODE_HOLD;
          out_state.envelope = 16'sh0000;
        end
        default: begin
        end
      endcase
      apply_event_calc = out_state;
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    gain_step_signed = $signed({9'd0, state_step[22:0]});
    gain_next_signed = $signed({{8{state_gain_q23[23]}}, state_gain_q23});
    phase_next_wide = 33'd0;
    ramp_cb_next = '0;

    next_mode = state_mode;
    next_gain_q23 = state_gain_q23;
    next_cb_q8_8 = state_cb_q8_8;
    next_step = state_step;
    next_target = state_target;
    next_phase = state_phase;
    next_duration = state_duration;
    next_active = state_active;
    next_envelope = state_active ? clamp_q15_signed($signed({{8{state_gain_q23[23]}}, state_gain_q23}) >>> 8) :
                    manual_envelope_level;
    event_pop_count = 3'd0;
    release_write = 1'b0;
    release_write_voice = snapshot_voice;
    release_write_value = 1'b0;
    event_calc.mode = next_mode;
    event_calc.gain_q23 = next_gain_q23;
    event_calc.cb_q8_8 = next_cb_q8_8;
    event_calc.step = next_step;
    event_calc.target = next_target;
    event_calc.phase = next_phase;
    event_calc.duration = next_duration;
    event_calc.active = next_active;
    event_calc.envelope = next_envelope;
    event_calc.release_write = 1'b0;
    event_calc.release_value = 1'b0;

    if (state_active && snapshot_prepare) begin
      unique case (state_mode)
        ENV_MODE_ATTACK: begin
          gain_next_signed = $signed({{8{state_gain_q23[23]}}, state_gain_q23}) + gain_step_signed;
          if ((state_phase + 1'b1) >= state_duration ||
              gain_next_signed >= $signed({8'd0, state_target[15:0], 8'd0})) begin
            next_gain_q23 = $signed({state_target[15:0], 8'd0});
            next_mode = ENV_MODE_HOLD;
            next_phase = 32'd0;
            next_envelope = clamp_q15_signed({16'd0, state_target[15:0]});
          end else begin
            next_gain_q23 = gain_next_signed[ENV_GAIN_Q23_WIDTH-1:0];
            next_phase = state_phase + 1'b1;
            next_envelope = clamp_q15_signed(gain_next_signed >>> 8);
          end
        end
        ENV_MODE_DECAY_CB: begin
          phase_next_wide = {1'b0, state_phase} + {1'b0, state_step};
          if (phase_next_wide[32]) begin
            next_mode = ENV_MODE_HOLD;
            next_phase = 32'd0;
            next_cb_q8_8 = state_target[ENV_CB_WIDTH-1:0];
            next_envelope = cb_to_q15(state_target[ENV_CB_WIDTH-1:0]);
            next_gain_q23 = $signed({cb_to_q15(state_target[ENV_CB_WIDTH-1:0]), 8'd0});
          end else begin
            ramp_cb_next = ramp_cb_q8_8(state_cb_q8_8, state_target[ENV_CB_WIDTH-1:0],
                                        phase_next_wide[31:0]);
            next_phase = phase_next_wide[31:0];
            next_envelope = cb_to_q15(ramp_cb_next);
            next_gain_q23 = $signed({cb_to_q15(ramp_cb_next), 8'd0});
          end
        end
        ENV_MODE_RELEASE_CB: begin
          phase_next_wide = {1'b0, state_phase} + {1'b0, state_step};
          if (phase_next_wide[32]) begin
            next_gain_q23 = '0;
            next_active = 1'b0;
            next_mode = ENV_MODE_HOLD;
            next_phase = 32'd0;
            next_envelope = 16'sh0000;
          end else begin
            ramp_cb_next = ramp_cb_q8_8(state_cb_q8_8, state_target[ENV_CB_WIDTH-1:0],
                                        phase_next_wide[31:0]);
            next_phase = phase_next_wide[31:0];
            next_envelope = cb_to_q15(ramp_cb_next);
            next_gain_q23 = $signed({cb_to_q15(ramp_cb_next), 8'd0});
          end
        end
        default: begin
          next_envelope = clamp_q15_signed($signed({{8{state_gain_q23[23]}}, state_gain_q23}) >>> 8);
        end
      endcase
    end

    if (event_matches_snapshot(event_head, event_head_valid)) begin
      event_calc = apply_event_calc(event_calc, event_head);
      event_pop_count = 3'd1;
      if (event_matches_snapshot(event_head1, event_head1_valid)) begin
        event_calc = apply_event_calc(event_calc, event_head1);
        event_pop_count = 3'd2;
        if (event_matches_snapshot(event_head2, event_head2_valid)) begin
          event_calc = apply_event_calc(event_calc, event_head2);
          event_pop_count = 3'd3;
          if (event_matches_snapshot(event_head3, event_head3_valid)) begin
            event_calc = apply_event_calc(event_calc, event_head3);
            event_pop_count = 3'd4;
          end
        end
      end
      next_mode = event_calc.mode;
      next_gain_q23 = event_calc.gain_q23;
      next_cb_q8_8 = event_calc.cb_q8_8;
      next_step = event_calc.step;
      next_target = event_calc.target;
      next_phase = event_calc.phase;
      next_duration = event_calc.duration;
      next_active = event_calc.active;
      next_envelope = event_calc.envelope;
      release_write = event_calc.release_write;
      release_write_value = event_calc.release_value;
    end

    store_write = (snapshot_prepare && state_active) || (event_pop_count != 3'd0) ||
                  manual_envelope_write;
    store_write_voice = manual_envelope_write ? manual_envelope_write_voice : snapshot_voice;
    store_write_mode = manual_envelope_write ? ENV_MODE_HOLD : next_mode;
    store_write_gain_q23 = manual_envelope_write ? '0 : next_gain_q23;
    store_write_cb_q8_8 = manual_envelope_write ? '0 : next_cb_q8_8;
    store_write_step = manual_envelope_write ? '0 : next_step;
    store_write_target = manual_envelope_write ? '0 : next_target;
    store_write_phase = manual_envelope_write ? '0 : next_phase;
    store_write_duration = manual_envelope_write ? '0 : next_duration;
    store_write_active = manual_envelope_write ? 1'b0 : next_active;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      prepared_envelope_level <= '0;
      prepared_envelope_active <= 1'b0;
      late_flag <= 1'b0;
      order_error_flag <= 1'b0;
    end else begin
      if (snapshot_prepare) begin
        prepared_envelope_level <= next_envelope;
        prepared_envelope_active <= next_active;
      end
      if (snapshot_prepare) begin
        late_flag <= late_flag ||
                     event_is_late(event_head, event_head_valid) ||
                     event_is_late(event_head1, event_head1_valid) ||
                     event_is_late(event_head2, event_head2_valid) ||
                     event_is_late(event_head3, event_head3_valid);
        order_error_flag <= order_error_flag ||
                            event_is_order_error(event_head, event_head_valid) ||
                            event_is_order_error(event_head1, event_head1_valid) ||
                            event_is_order_error(event_head2, event_head2_valid) ||
                            event_is_order_error(event_head3, event_head3_valid);
      end
    end
  end
endmodule
