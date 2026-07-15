module multi_voice_pipeline (
  input  logic                       clk,
  input  logic                       rst,
  output logic [$clog2(synth_pkg::NUM_VOICES)-1:0] voice_read_index,
  input  synth_pkg::voice_config_t   voice_config,
  input  synth_pkg::voice_runtime_t  voice_runtime,
  input  logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  input  logic [synth_pkg::NUM_VOICES-1:0] config_commit,
  input  logic                       sample_tick,
  output logic                       busy,
  output logic                       sample_valid,
  output synth_pkg::pcm_t            sample_l,
  output synth_pkg::pcm_t            sample_r,
  output logic                       mem_req_valid,
  output logic [31:0]                mem_req_addr,
  input  logic                       mem_req_ready,
  input  logic                       mem_rsp_valid,
  input  synth_pkg::pcm_t            mem_rsp_data
);
  import synth_pkg::*;

  typedef enum logic [4:0] {
    IDLE, READ_VOICE, WAIT_VOICE, START_VOICE, PROCESS_VOICE, REQ_L0, WAIT_L0, REQ_L1, WAIT_L1,
    REQ_R0, WAIT_R0, REQ_R1, WAIT_R1, INTERPOLATE, FILTER_INPUT, FILTER_MUL_X,
    FILTER_Y, FILTER_MUL_Y, FILTER_ACC, GAIN, ACCUMULATE, FINISH
  } state_t;

  localparam int VOICE_INDEX_WIDTH = $clog2(NUM_VOICES);
  localparam logic [VOICE_INDEX_WIDTH-1:0] LAST_VOICE = VOICE_INDEX_WIDTH'(NUM_VOICES - 1);

  state_t state;
  logic [VOICE_INDEX_WIDTH-1:0] voice_index;
  logic [NUM_VOICES-1:0] frame_commit;
  logic [PHASE_WIDTH-1:0] phase [NUM_VOICES];
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_l [NUM_VOICES];
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_l [NUM_VOICES];
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_r [NUM_VOICES];
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_r [NUM_VOICES];
  logic [PHASE_FRAME_WIDTH-1:0] frame_0;
  logic [PHASE_FRAME_WIDTH-1:0] frame_1;
  logic [PHASE_FRAC_WIDTH-1:0] fraction;
  pcm_t raw_l0, raw_l1, raw_r0, raw_r1;
  pcm_t interpolated_l, interpolated_r;
  (* keep = "true", dont_touch = "true" *) pcm_t interp_stage_l, interp_stage_r;
  (* keep = "true", dont_touch = "true" *) pcm_t filter_input_l, filter_input_r;
  pcm_t filtered_l, filtered_r;
  pcm_t gain_input_l, gain_input_r;
  pcm_t gain_stage_input_l, gain_stage_input_r;
  pcm_t gained_l, gained_r;
  pcm_t gained_stage_l, gained_stage_r;
  pcm_t envelope_scaled_l, envelope_scaled_r;
  pcm_t enveloped_l, enveloped_r;
  logic signed [31:0] accum_l;
  logic signed [31:0] accum_r;
  logic signed [31:0] next_accum_l;
  logic signed [31:0] next_accum_r;
  logic [32:0] phase_sum;
  logic [32:0] loop_end_phase;
  logic [31:0] loop_length_phase;
  logic [31:0] wrapped_phase;
  logic loop_active;
  logic voice_done;
  logic cfg_enable;
  logic cfg_stereo;
  logic [ADDR_WIDTH-1:0] cfg_base_addr;
  logic [ADDR_WIDTH-1:0] cfg_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_length;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_end;
  logic [PHASE_WIDTH-1:0] cfg_phase_inc;
  logic signed [15:0] cfg_gain_l;
  logic signed [15:0] cfg_gain_r;
  logic signed [15:0] cfg_envelope_level;
  logic [1:0] cfg_loop_mode;
  logic cfg_released;
  logic cfg_filter_enable;
  logic signed [31:0] cfg_filter_b0;
  logic signed [31:0] cfg_filter_b1;
  logic signed [31:0] cfg_filter_b2;
  logic signed [31:0] cfg_filter_a1;
  logic signed [31:0] cfg_filter_a2;
  logic current_enable;
  logic current_config_valid;
  logic current_commit;
  logic current_stereo;
  logic [ADDR_WIDTH-1:0] current_base_addr;
  logic [ADDR_WIDTH-1:0] current_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_length;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_end;
  logic [PHASE_WIDTH-1:0] current_phase_inc;
  logic signed [15:0] current_gain_l;
  logic signed [15:0] current_gain_r;
  logic signed [15:0] current_envelope_level;
  logic [1:0] current_loop_mode;
  logic current_released;
  logic current_filter_enable;
  logic signed [31:0] current_filter_b0;
  logic signed [31:0] current_filter_b1;
  logic signed [31:0] current_filter_b2;
  logic signed [31:0] current_filter_a1;
  logic signed [31:0] current_filter_a2;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_next_z1_l;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_next_z2_l;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_next_z1_r;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_next_z2_r;
  logic [PHASE_WIDTH-1:0] current_phase;

  function automatic pcm_t saturate_pcm(input logic signed [63:0] value);
    if (value > 64'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -64'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  assign voice_read_index = voice_index;
  assign cfg_enable = voice_config.enable;
  assign cfg_stereo = voice_config.stereo;
  assign cfg_base_addr = voice_config.base_addr;
  assign cfg_base_addr_r = voice_config.base_addr_r;
  assign cfg_length = voice_config.length;
  assign cfg_loop_start = voice_config.loop_start;
  assign cfg_loop_end = voice_config.loop_end;
  assign cfg_phase_inc = voice_runtime.phase_inc;
  assign cfg_gain_l = voice_runtime.gain_l;
  assign cfg_gain_r = voice_runtime.gain_r;
  assign cfg_envelope_level = voice_runtime.envelope_level;
  assign cfg_loop_mode = voice_config.loop_mode;
  assign cfg_released = voice_runtime.released;
  assign cfg_filter_enable = voice_runtime.filter_enable;
  assign cfg_filter_b0 = voice_runtime.filter_b0;
  assign cfg_filter_b1 = voice_runtime.filter_b1;
  assign cfg_filter_b2 = voice_runtime.filter_b2;
  assign cfg_filter_a1 = voice_runtime.filter_a1;
  assign cfg_filter_a2 = voice_runtime.filter_a2;
  always_comb begin
    phase_sum = {1'b0, current_phase} + {1'b0, current_phase_inc};
    loop_end_phase = {1'b0, current_loop_end, {PHASE_FRAC_WIDTH{1'b0}}};
    loop_length_phase = {(current_loop_end - current_loop_start), {PHASE_FRAC_WIDTH{1'b0}}};
    wrapped_phase = phase_sum[31:0] - loop_length_phase;
    loop_active = (current_loop_mode == LOOP_MODE_CONTINUOUS) ||
                  ((current_loop_mode == LOOP_MODE_UNTIL_RELEASE) && !current_released);
    voice_done = (current_loop_mode == LOOP_MODE_NONE || !loop_active) &&
                 (current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] >= current_length);
    next_accum_l = accum_l + $signed({{16{enveloped_l[15]}}, enveloped_l});
    next_accum_r = accum_r + $signed({{16{enveloped_r[15]}}, enveloped_r});
    gain_input_l = gain_stage_input_l;
    gain_input_r = gain_stage_input_r;
  end

  linear_interpolator interp_l (
    .sample_0(raw_l0), .sample_1(raw_l1),
    .fraction(fraction), .sample_out(interpolated_l)
  );
  linear_interpolator interp_r (
    .sample_0(raw_r0), .sample_1(raw_r1),
    .fraction(fraction), .sample_out(interpolated_r)
  );
  gain_saturate gain_l_inst (
    .sample_in(gain_input_l), .gain(current_gain_l), .sample_out(gained_l)
  );
  gain_saturate gain_r_inst (
    .sample_in(gain_input_r), .gain(current_gain_r), .sample_out(gained_r)
  );
  gain_saturate envelope_l_inst (
    .sample_in(gained_stage_l),
    .gain(current_envelope_level),
    .sample_out(envelope_scaled_l)
  );
  gain_saturate envelope_r_inst (
    .sample_in(gained_stage_r),
    .gain(current_envelope_level),
    .sample_out(envelope_scaled_r)
  );

  biquad_filter_datapath filter_datapath (
    .clk,
    .rst,
    .load_x(state == FILTER_MUL_X),
    .capture_y(state == FILTER_Y),
    .load_y(state == FILTER_MUL_Y),
    .sample_l(filter_input_l),
    .sample_r(filter_input_r),
    .coeff_b0(current_filter_b0),
    .coeff_b1(current_filter_b1),
    .coeff_b2(current_filter_b2),
    .coeff_a1(current_filter_a1),
    .coeff_a2(current_filter_a2),
    .z1_l(filter_z1_l[voice_index]),
    .z2_l(filter_z2_l[voice_index]),
    .z1_r(filter_z1_r[voice_index]),
    .z2_r(filter_z2_r[voice_index]),
    .filtered_l,
    .filtered_r,
    .next_z1_l(filter_next_z1_l),
    .next_z2_l(filter_next_z2_l),
    .next_z1_r(filter_next_z1_r),
    .next_z2_r(filter_next_z2_r)
  );

  assign enveloped_l = (current_envelope_level == 16'sh7fff) ? gained_stage_l : envelope_scaled_l;
  assign enveloped_r = (current_envelope_level == 16'sh7fff) ? gained_stage_r : envelope_scaled_r;

  always_comb begin
    busy = (state != IDLE);
    mem_req_valid = 1'b0;
    mem_req_addr = 32'd0;
    unique case (state)
      REQ_L0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_0};
      end
      REQ_L1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_1};
      end
      REQ_R0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr_r + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_0};
      end
      REQ_R1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr_r + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_1};
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      voice_index <= '0;
      frame_0 <= '0;
      frame_1 <= '0;
      fraction <= '0;
      current_stereo <= 1'b0;
      current_base_addr <= '0;
      current_base_addr_r <= '0;
      current_enable <= 1'b0;
      current_config_valid <= 1'b0;
      current_commit <= 1'b0;
      current_length <= '0;
      current_loop_start <= '0;
      current_loop_end <= '0;
      current_phase <= '0;
      current_phase_inc <= '0;
      current_gain_l <= '0;
      current_gain_r <= '0;
      current_envelope_level <= '0;
      current_loop_mode <= LOOP_MODE_NONE;
      current_released <= 1'b0;
      current_filter_enable <= 1'b0;
      current_filter_b0 <= '0;
      current_filter_b1 <= '0;
      current_filter_b2 <= '0;
      current_filter_a1 <= '0;
      current_filter_a2 <= '0;
      raw_l0 <= '0;
      raw_l1 <= '0;
      raw_r0 <= '0;
      raw_r1 <= '0;
      interp_stage_l <= '0;
      interp_stage_r <= '0;
      filter_input_l <= '0;
      filter_input_r <= '0;
      gain_stage_input_l <= '0;
      gain_stage_input_r <= '0;
      gained_stage_l <= '0;
      gained_stage_r <= '0;
      accum_l <= 32'sd0;
      accum_r <= 32'sd0;
      sample_valid <= 1'b0;
      sample_l <= '0;
      sample_r <= '0;
      frame_commit <= '0;
      for (int v = 0; v < NUM_VOICES; v++) begin
        phase[v] <= 32'd0;
        filter_z1_l[v] <= '0;
        filter_z2_l[v] <= '0;
        filter_z1_r[v] <= '0;
        filter_z2_r[v] <= '0;
      end
    end else begin
      sample_valid <= 1'b0;

      unique case (state)
        IDLE: begin
          if (sample_tick) begin
            accum_l <= 32'sd0;
            accum_r <= 32'sd0;
            frame_commit <= config_commit;
            voice_index <= '0;
            state <= READ_VOICE;
          end
        end
        READ_VOICE: begin
          state <= WAIT_VOICE;
        end
        WAIT_VOICE: begin
          state <= START_VOICE;
        end
        START_VOICE: begin
          current_enable <= cfg_enable;
          current_config_valid <= config_valid[voice_index];
          current_commit <= frame_commit[voice_index];
          current_stereo <= cfg_stereo;
          current_base_addr <= cfg_base_addr;
          current_base_addr_r <= cfg_base_addr_r;
          current_length <= cfg_length;
          current_loop_start <= cfg_loop_start;
          current_loop_end <= cfg_loop_end;
          current_phase <= frame_commit[voice_index] ? voice_config.phase_init : phase[voice_index];
          current_phase_inc <= cfg_phase_inc;
          current_gain_l <= cfg_gain_l;
          current_gain_r <= cfg_gain_r;
          current_envelope_level <= cfg_envelope_level;
          current_loop_mode <= cfg_loop_mode;
          current_released <= cfg_released;
          current_filter_enable <= cfg_filter_enable;
          current_filter_b0 <= cfg_filter_b0;
          current_filter_b1 <= cfg_filter_b1;
          current_filter_b2 <= cfg_filter_b2;
          current_filter_a1 <= cfg_filter_a1;
          current_filter_a2 <= cfg_filter_a2;
          state <= PROCESS_VOICE;
        end
        PROCESS_VOICE: begin
          if (!current_enable || !current_config_valid || voice_done) begin
            if (voice_index == LAST_VOICE)
              state <= FINISH;
            else begin
              voice_index <= voice_index + 1'b1;
              state <= READ_VOICE;
            end
          end else begin
            if (current_commit) begin
              filter_z1_l[voice_index] <= '0;
              filter_z2_l[voice_index] <= '0;
              filter_z1_r[voice_index] <= '0;
              filter_z2_r[voice_index] <= '0;
            end
            frame_0 <= current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH];
            if (loop_active)
              frame_1 <= (current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1 >= current_loop_end) ?
                         current_loop_start : current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1;
            else
              frame_1 <= (current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1 >= current_length) ?
                         current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] : current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1;
            fraction <= current_phase[PHASE_FRAC_WIDTH-1:0];
            if (loop_active && phase_sum >= loop_end_phase)
              phase[voice_index] <= wrapped_phase;
            else
              phase[voice_index] <= phase_sum[31:0];
            state <= REQ_L0;
          end
        end
        REQ_L0:  if (mem_req_ready) state <= WAIT_L0;
        WAIT_L0: if (mem_rsp_valid) begin raw_l0 <= mem_rsp_data; state <= REQ_L1; end
        REQ_L1:  if (mem_req_ready) state <= WAIT_L1;
        WAIT_L1: if (mem_rsp_valid) begin
          raw_l1 <= mem_rsp_data;
          if (current_stereo)
            state <= REQ_R0;
          else begin
            raw_r0 <= raw_l0;
            raw_r1 <= mem_rsp_data;
            state <= INTERPOLATE;
          end
        end
        REQ_R0:  if (mem_req_ready) state <= WAIT_R0;
        WAIT_R0: if (mem_rsp_valid) begin raw_r0 <= mem_rsp_data; state <= REQ_R1; end
        REQ_R1:  if (mem_req_ready) state <= WAIT_R1;
        WAIT_R1: if (mem_rsp_valid) begin
          raw_r1 <= mem_rsp_data;
          state <= INTERPOLATE;
        end
        INTERPOLATE: begin
          interp_stage_l <= interpolated_l;
          interp_stage_r <= interpolated_r;
          state <= FILTER_INPUT;
        end
        FILTER_INPUT: begin
          filter_input_l <= interp_stage_l;
          filter_input_r <= interp_stage_r;
          state <= FILTER_MUL_X;
        end
        FILTER_MUL_X: begin
          state <= FILTER_Y;
        end
        FILTER_Y: begin
          gain_stage_input_l <= current_filter_enable ? filtered_l : filter_input_l;
          gain_stage_input_r <= current_filter_enable ? filtered_r : filter_input_r;
          state <= FILTER_MUL_Y;
        end
        FILTER_MUL_Y: begin
          state <= FILTER_ACC;
        end
        FILTER_ACC: begin
          gain_stage_input_l <= current_filter_enable ? filtered_l : filter_input_l;
          gain_stage_input_r <= current_filter_enable ? filtered_r : filter_input_r;
          state <= GAIN;
        end
        GAIN: begin
          gained_stage_l <= gained_l;
          gained_stage_r <= gained_r;
          state <= ACCUMULATE;
        end
        ACCUMULATE: begin
          if (current_filter_enable) begin
            filter_z1_l[voice_index] <= filter_next_z1_l;
            filter_z2_l[voice_index] <= filter_next_z2_l;
            filter_z1_r[voice_index] <= filter_next_z1_r;
            filter_z2_r[voice_index] <= filter_next_z2_r;
          end
          accum_l <= next_accum_l;
          accum_r <= next_accum_r;
          if (voice_index == LAST_VOICE)
            state <= FINISH;
          else begin
            voice_index <= voice_index + 1'b1;
            state <= READ_VOICE;
          end
        end
        FINISH: begin
          sample_l <= saturate_pcm({{32{accum_l[31]}}, accum_l});
          sample_r <= saturate_pcm({{32{accum_r[31]}}, accum_r});
          sample_valid <= 1'b1;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
