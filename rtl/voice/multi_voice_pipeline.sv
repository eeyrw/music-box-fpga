module multi_voice_pipeline (
  input  logic                       clk,
  input  logic                       rst,
  input  synth_pkg::voice_config_t   voice_config [synth_pkg::NUM_VOICES],
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
    REQ_R0, WAIT_R0, REQ_R1, WAIT_R1, ACCUMULATE, FINISH
  } state_t;

  localparam int VOICE_INDEX_WIDTH = $clog2(NUM_VOICES);
  localparam logic [VOICE_INDEX_WIDTH-1:0] LAST_VOICE = VOICE_INDEX_WIDTH'(NUM_VOICES - 1);

  state_t state;
  logic [VOICE_INDEX_WIDTH-1:0] voice_index;
  logic [PHASE_WIDTH-1:0] phase [NUM_VOICES];
  logic [15:0] frame_0;
  logic [15:0] frame_1;
  logic [15:0] fraction;
  pcm_t raw_l0, raw_l1, raw_r0, raw_r1;
  pcm_t interpolated_l, interpolated_r;
  pcm_t gained_l, gained_r;
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
  logic current_enable;
  logic current_stereo;
  logic [ADDR_WIDTH-1:0] current_base_addr;
  logic [15:0] current_loop_start;
  logic [15:0] current_loop_end;
  logic [PHASE_WIDTH-1:0] current_phase_inc;
  logic signed [15:0] current_gain_l;
  logic signed [15:0] current_gain_r;
  logic signed [15:0] current_envelope_level;

  function automatic pcm_t saturate_pcm(input logic signed [31:0] value);
    if (value > 32'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -32'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  assign current_enable = voice_config[voice_index].enable;
  assign current_stereo = voice_config[voice_index].stereo;
  assign current_base_addr = voice_config[voice_index].base_addr;
  assign current_loop_start = voice_config[voice_index].loop_start;
  assign current_loop_end = voice_config[voice_index].loop_end;
  assign current_phase_inc = voice_config[voice_index].phase_inc;
  assign current_gain_l = voice_config[voice_index].gain_l;
  assign current_gain_r = voice_config[voice_index].gain_r;
  assign current_envelope_level = voice_config[voice_index].envelope_level;

  always_comb begin
    phase_sum = {1'b0, phase[voice_index]} + {1'b0, current_phase_inc};
    loop_end_phase = {1'b0, current_loop_end, 16'd0};
    loop_length_phase = {(current_loop_end - current_loop_start), 16'd0};
    wrapped_phase = phase_sum[31:0] - loop_length_phase;
    next_accum_l = accum_l + $signed({{16{enveloped_l[15]}}, enveloped_l});
    next_accum_r = accum_r + $signed({{16{enveloped_r[15]}}, enveloped_r});
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
    .sample_in(interpolated_l), .gain(current_gain_l), .sample_out(gained_l)
  );
  gain_saturate gain_r_inst (
    .sample_in(interpolated_r), .gain(current_gain_r), .sample_out(gained_r)
  );
  gain_saturate envelope_l_inst (
    .sample_in(gained_l), .gain(current_envelope_level), .sample_out(envelope_scaled_l)
  );
  gain_saturate envelope_r_inst (
    .sample_in(gained_r), .gain(current_envelope_level), .sample_out(envelope_scaled_r)
  );

  assign enveloped_l = (current_envelope_level == 16'sh7fff) ? gained_l : envelope_scaled_l;
  assign enveloped_r = (current_envelope_level == 16'sh7fff) ? gained_r : envelope_scaled_r;

  always_comb begin
    busy = (state != IDLE);
    mem_req_valid = 1'b0;
    mem_req_addr = 32'd0;
    unique case (state)
      REQ_L0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr +
                       (current_stereo ? {15'd0, frame_0, 1'b0} : {16'd0, frame_0});
      end
      REQ_L1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr +
                       (current_stereo ? {15'd0, frame_1, 1'b0} : {16'd0, frame_1});
      end
      REQ_R0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr + {15'd0, frame_0, 1'b0} + 32'd1;
      end
      REQ_R1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = current_base_addr + {15'd0, frame_1, 1'b0} + 32'd1;
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
      raw_l0 <= '0;
      raw_l1 <= '0;
      raw_r0 <= '0;
      raw_r1 <= '0;
      accum_l <= 32'sd0;
      accum_r <= 32'sd0;
      sample_valid <= 1'b0;
      sample_l <= '0;
      sample_r <= '0;
      for (int v = 0; v < NUM_VOICES; v++)
        phase[v] <= 32'd0;
    end else begin
      sample_valid <= 1'b0;

      for (int v = 0; v < NUM_VOICES; v++) begin
        if (config_commit[v])
          phase[v] <= voice_config[v].phase_init;
      end

      unique case (state)
        IDLE: begin
          if (sample_tick) begin
            accum_l <= 32'sd0;
            accum_r <= 32'sd0;
            voice_index <= '0;
            state <= START_VOICE;
          end
        end
        START_VOICE: begin
          if (!current_enable || !config_valid[voice_index]) begin
            if (voice_index == LAST_VOICE)
              state <= FINISH;
            else
              voice_index <= voice_index + 1'b1;
          end else begin
            frame_0 <= phase[voice_index][31:16];
            frame_1 <= (phase[voice_index][31:16] + 16'd1 >= current_loop_end) ?
                       current_loop_start : phase[voice_index][31:16] + 16'd1;
            fraction <= phase[voice_index][15:0];
            if (phase_sum >= loop_end_phase)
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
            state <= ACCUMULATE;
          end
        end
        REQ_R0:  if (mem_req_ready) state <= WAIT_R0;
        WAIT_R0: if (mem_rsp_valid) begin raw_r0 <= mem_rsp_data; state <= REQ_R1; end
        REQ_R1:  if (mem_req_ready) state <= WAIT_R1;
        WAIT_R1: if (mem_rsp_valid) begin raw_r1 <= mem_rsp_data; state <= ACCUMULATE; end
        ACCUMULATE: begin
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
          sample_l <= saturate_pcm(accum_l);
          sample_r <= saturate_pcm(accum_r);
          sample_valid <= 1'b1;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
