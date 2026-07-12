module multi_voice_pipeline (
  input  logic                       clk,
  input  logic                       rst,
  input  synth_pkg::voice_config_t   voice_config [synth_pkg::NUM_VOICES],
  input  synth_pkg::voice_runtime_t  voice_runtime [synth_pkg::NUM_VOICES],
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

  typedef enum logic [3:0] {
    IDLE, START_VOICE, REQ_L0, WAIT_L0, REQ_L1, WAIT_L1,
    REQ_R0, WAIT_R0, REQ_R1, WAIT_R1, INTERPOLATE, FILTER,
    GAIN, ACCUMULATE, FINISH
  } state_t;

  localparam int VOICE_INDEX_WIDTH = $clog2(NUM_VOICES);
  localparam logic [VOICE_INDEX_WIDTH-1:0] LAST_VOICE = VOICE_INDEX_WIDTH'(NUM_VOICES - 1);

  typedef struct packed {
    pcm_t sample;
    logic signed [63:0] z1;
    logic signed [63:0] z2;
  } biquad_result_t;

  state_t state;
  logic [VOICE_INDEX_WIDTH-1:0] voice_index;
  voice_config_t frame_config [NUM_VOICES];
  voice_runtime_t frame_runtime [NUM_VOICES];
  logic [NUM_VOICES-1:0] frame_config_valid;
  logic [NUM_VOICES-1:0] pending_commit;
  logic [PHASE_WIDTH-1:0] phase [NUM_VOICES];
  logic signed [63:0] filter_z1_l [NUM_VOICES];
  logic signed [63:0] filter_z2_l [NUM_VOICES];
  logic signed [63:0] filter_z1_r [NUM_VOICES];
  logic signed [63:0] filter_z2_r [NUM_VOICES];
  logic [15:0] frame_0;
  logic [15:0] frame_1;
  logic [15:0] fraction;
  pcm_t raw_l0, raw_l1, raw_r0, raw_r1;
  pcm_t interpolated_l, interpolated_r;
  pcm_t interp_stage_l, interp_stage_r;
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
  logic [15:0] cfg_length;
  logic [15:0] cfg_loop_start;
  logic [15:0] cfg_loop_end;
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
  logic current_stereo;
  logic [ADDR_WIDTH-1:0] current_base_addr;
  logic [ADDR_WIDTH-1:0] current_base_addr_r;
  logic signed [15:0] current_gain_l;
  logic signed [15:0] current_gain_r;
  logic signed [15:0] current_envelope_level;
  logic current_filter_enable;
  logic signed [31:0] current_filter_b0;
  logic signed [31:0] current_filter_b1;
  logic signed [31:0] current_filter_b2;
  logic signed [31:0] current_filter_a1;
  logic signed [31:0] current_filter_a2;
  biquad_result_t filter_result_l;
  biquad_result_t filter_result_r;
  logic signed [63:0] filter_next_z1_l;
  logic signed [63:0] filter_next_z2_l;
  logic signed [63:0] filter_next_z1_r;
  logic signed [63:0] filter_next_z2_r;

  function automatic logic signed [63:0] saturate_i64(input logic signed [95:0] value);
    if (value > 96'sd9223372036854775807)
      saturate_i64 = 64'sh7fff_ffff_ffff_ffff;
    else if (value < -96'sd9223372036854775808)
      saturate_i64 = 64'sh8000_0000_0000_0000;
    else
      saturate_i64 = value[63:0];
  endfunction

  function automatic pcm_t saturate_pcm(input logic signed [63:0] value);
    if (value > 64'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -64'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  function automatic biquad_result_t biquad_iir(
    input logic signed [63:0] z1,
    input logic signed [63:0] z2,
    input pcm_t sample,
    input logic signed [31:0] b0,
    input logic signed [31:0] b1,
    input logic signed [31:0] b2,
    input logic signed [31:0] a1,
    input logic signed [31:0] a2
  );
    logic signed [31:0] x_ext;
    logic signed [31:0] y_pcm_ext;
    logic signed [63:0] y_q28;
    logic signed [63:0] b0_x;
    logic signed [63:0] b1_x;
    logic signed [63:0] b2_x;
    logic signed [63:0] a1_y;
    logic signed [63:0] a2_y;
    logic signed [95:0] next_z1;
    logic signed [95:0] next_z2;
    biquad_result_t result;
    begin
      x_ext = {{16{sample[15]}}, sample};
      b0_x = $signed(x_ext) * $signed(b0);
      y_q28 = b0_x + z1;
      result.sample = saturate_pcm(y_q28 >>> 28);
      y_pcm_ext = {{16{result.sample[15]}}, result.sample};
      b1_x = $signed(x_ext) * $signed(b1);
      b2_x = $signed(x_ext) * $signed(b2);
      a1_y = $signed(y_pcm_ext) * $signed(a1);
      a2_y = $signed(y_pcm_ext) * $signed(a2);
      next_z1 = $signed({{32{b1_x[63]}}, b1_x}) - $signed({{32{a1_y[63]}}, a1_y}) + $signed({{32{z2[63]}}, z2});
      next_z2 = $signed({{32{b2_x[63]}}, b2_x}) - $signed({{32{a2_y[63]}}, a2_y});
      result.z1 = saturate_i64(next_z1);
      result.z2 = saturate_i64(next_z2);
      biquad_iir = result;
    end
  endfunction

  assign cfg_enable = frame_config[voice_index].enable;
  assign cfg_stereo = frame_config[voice_index].stereo;
  assign cfg_base_addr = frame_config[voice_index].base_addr;
  assign cfg_base_addr_r = frame_config[voice_index].base_addr_r;
  assign cfg_length = frame_config[voice_index].length;
  assign cfg_loop_start = frame_config[voice_index].loop_start;
  assign cfg_loop_end = frame_config[voice_index].loop_end;
  assign cfg_phase_inc = frame_runtime[voice_index].phase_inc;
  assign cfg_gain_l = frame_runtime[voice_index].gain_l;
  assign cfg_gain_r = frame_runtime[voice_index].gain_r;
  assign cfg_envelope_level = frame_runtime[voice_index].envelope_level;
  assign cfg_loop_mode = frame_config[voice_index].loop_mode;
  assign cfg_released = frame_runtime[voice_index].released;
  assign cfg_filter_enable = frame_runtime[voice_index].filter_enable;
  assign cfg_filter_b0 = frame_runtime[voice_index].filter_b0;
  assign cfg_filter_b1 = frame_runtime[voice_index].filter_b1;
  assign cfg_filter_b2 = frame_runtime[voice_index].filter_b2;
  assign cfg_filter_a1 = frame_runtime[voice_index].filter_a1;
  assign cfg_filter_a2 = frame_runtime[voice_index].filter_a2;

  always_comb begin
    phase_sum = {1'b0, phase[voice_index]} + {1'b0, cfg_phase_inc};
    loop_end_phase = {1'b0, cfg_loop_end, 16'd0};
    loop_length_phase = {(cfg_loop_end - cfg_loop_start), 16'd0};
    wrapped_phase = phase_sum[31:0] - loop_length_phase;
    loop_active = (cfg_loop_mode == LOOP_MODE_CONTINUOUS) ||
                  ((cfg_loop_mode == LOOP_MODE_UNTIL_RELEASE) && !cfg_released);
    voice_done = (cfg_loop_mode == LOOP_MODE_NONE || !loop_active) &&
                 (phase[voice_index][31:16] >= cfg_length);
    next_accum_l = accum_l + $signed({{16{enveloped_l[15]}}, enveloped_l});
    next_accum_r = accum_r + $signed({{16{enveloped_r[15]}}, enveloped_r});
    filter_result_l = biquad_iir(filter_z1_l[voice_index], filter_z2_l[voice_index], interp_stage_l,
                                 current_filter_b0, current_filter_b1, current_filter_b2,
                                 current_filter_a1, current_filter_a2);
    filter_result_r = biquad_iir(filter_z1_r[voice_index], filter_z2_r[voice_index], interp_stage_r,
                                 current_filter_b0, current_filter_b1, current_filter_b2,
                                 current_filter_a1, current_filter_a2);
    filtered_l = filter_result_l.sample;
    filtered_r = filter_result_r.sample;
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

  assign enveloped_l = (current_envelope_level == 16'sh7fff) ? gained_stage_l : envelope_scaled_l;
  assign enveloped_r = (current_envelope_level == 16'sh7fff) ? gained_stage_r : envelope_scaled_r;

  always_comb begin
    busy = (state != IDLE);
    mem_req_valid = 1'b0;
    mem_req_addr = 32'd0;
    unique case (state)
      REQ_L0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr + {16'd0, frame_0};
      end
      REQ_L1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr + {16'd0, frame_1};
      end
      REQ_R0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr_r + {16'd0, frame_0};
      end
      REQ_R1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr_r + {16'd0, frame_1};
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      voice_index <= '0;
      frame_0 <= 16'd0;
      frame_1 <= 16'd0;
      fraction <= 16'd0;
      current_stereo <= 1'b0;
      current_base_addr <= '0;
      current_base_addr_r <= '0;
      current_gain_l <= '0;
      current_gain_r <= '0;
      current_envelope_level <= '0;
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
      gain_stage_input_l <= '0;
      gain_stage_input_r <= '0;
      gained_stage_l <= '0;
      gained_stage_r <= '0;
      filter_next_z1_l <= '0;
      filter_next_z2_l <= '0;
      filter_next_z1_r <= '0;
      filter_next_z2_r <= '0;
      accum_l <= 32'sd0;
      accum_r <= 32'sd0;
      sample_valid <= 1'b0;
      sample_l <= '0;
      sample_r <= '0;
      frame_config_valid <= '0;
      pending_commit <= '0;
      for (int v = 0; v < NUM_VOICES; v++) begin
        frame_config[v] <= '0;
        frame_runtime[v] <= '0;
        phase[v] <= 32'd0;
        filter_z1_l[v] <= '0;
        filter_z2_l[v] <= '0;
        filter_z1_r[v] <= '0;
        filter_z2_r[v] <= '0;
      end
    end else begin
      sample_valid <= 1'b0;

      for (int v = 0; v < NUM_VOICES; v++) begin
        if (config_commit[v])
          pending_commit[v] <= 1'b1;
        if ((state == IDLE) && pending_commit[v]) begin
          phase[v] <= voice_config[v].phase_init;
          filter_z1_l[v] <= '0;
          filter_z2_l[v] <= '0;
          filter_z1_r[v] <= '0;
          filter_z2_r[v] <= '0;
          pending_commit[v] <= 1'b0;
        end
      end

      unique case (state)
        IDLE: begin
          if (sample_tick) begin
            for (int v = 0; v < NUM_VOICES; v++) begin
              frame_config[v] <= voice_config[v];
              frame_runtime[v] <= voice_runtime[v];
              frame_config_valid[v] <= config_valid[v];
            end
            accum_l <= 32'sd0;
            accum_r <= 32'sd0;
            voice_index <= '0;
            state <= START_VOICE;
          end
        end
        START_VOICE: begin
          if (!cfg_enable || !frame_config_valid[voice_index] || voice_done) begin
            if (voice_index == LAST_VOICE)
              state <= FINISH;
            else
              voice_index <= voice_index + 1'b1;
          end else begin
            current_stereo <= cfg_stereo;
            current_base_addr <= cfg_base_addr;
            current_base_addr_r <= cfg_base_addr_r;
            current_gain_l <= cfg_gain_l;
            current_gain_r <= cfg_gain_r;
            current_envelope_level <= cfg_envelope_level;
            current_filter_enable <= cfg_filter_enable;
            current_filter_b0 <= cfg_filter_b0;
            current_filter_b1 <= cfg_filter_b1;
            current_filter_b2 <= cfg_filter_b2;
            current_filter_a1 <= cfg_filter_a1;
            current_filter_a2 <= cfg_filter_a2;
            frame_0 <= phase[voice_index][31:16];
            if (loop_active)
              frame_1 <= (phase[voice_index][31:16] + 16'd1 >= cfg_loop_end) ?
                         cfg_loop_start : phase[voice_index][31:16] + 16'd1;
            else
              frame_1 <= (phase[voice_index][31:16] + 16'd1 >= cfg_length) ?
                         phase[voice_index][31:16] : phase[voice_index][31:16] + 16'd1;
            fraction <= phase[voice_index][15:0];
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
          state <= FILTER;
        end
        FILTER: begin
          gain_stage_input_l <= current_filter_enable ? filtered_l : interp_stage_l;
          gain_stage_input_r <= current_filter_enable ? filtered_r : interp_stage_r;
          filter_next_z1_l <= filter_result_l.z1;
          filter_next_z2_l <= filter_result_l.z2;
          filter_next_z1_r <= filter_result_r.z1;
          filter_next_z2_r <= filter_result_r.z2;
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
            state <= START_VOICE;
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
