module voice_pipeline (
  input  logic                       clk,
  input  logic                       rst,
  input  synth_pkg::voice_config_t   voice_config,
  input  logic                       config_valid,
  input  logic                       config_commit,
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
    IDLE, REQ_L0, WAIT_L0, REQ_L1, WAIT_L1,
    REQ_R0, WAIT_R0, REQ_R1, WAIT_R1, PRODUCE
  } state_t;

  state_t state;
  logic [31:0] phase;
  logic [15:0] frame_0;
  logic [15:0] frame_1;
  logic [15:0] fraction;
  pcm_t raw_l0, raw_l1, raw_r0, raw_r1;
  pcm_t interpolated_l, interpolated_r;
  pcm_t gained_l, gained_r;
  logic [32:0] phase_sum;
  logic [32:0] loop_end_phase;
  logic [32:0] loop_length_phase;
  logic [32:0] wrapped_phase;

  always_comb begin
    phase_sum = {1'b0, phase} + {1'b0, voice_config.phase_inc};
    loop_end_phase = {1'b0, voice_config.loop_end, 16'd0};
    loop_length_phase = {1'b0, (voice_config.loop_end - voice_config.loop_start), 16'd0};
    wrapped_phase = phase_sum - loop_length_phase;
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
    .sample_in(interpolated_l), .gain(voice_config.gain_l), .sample_out(gained_l)
  );
  gain_saturate gain_r_inst (
    .sample_in(interpolated_r), .gain(voice_config.gain_r), .sample_out(gained_r)
  );

  always_comb begin
    busy = (state != IDLE);
    mem_req_valid = 1'b0;
    mem_req_addr = 32'd0;
    unique case (state)
      REQ_L0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = voice_config.base_addr +
                       (voice_config.stereo ? {15'd0, frame_0, 1'b0} : {16'd0, frame_0});
      end
      REQ_L1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = voice_config.base_addr +
                       (voice_config.stereo ? {15'd0, frame_1, 1'b0} : {16'd0, frame_1});
      end
      REQ_R0: begin
        mem_req_valid = 1'b1;
        mem_req_addr = voice_config.base_addr + {15'd0, frame_0, 1'b0} + 32'd1;
      end
      REQ_R1: begin
        mem_req_valid = 1'b1;
        mem_req_addr = voice_config.base_addr + {15'd0, frame_1, 1'b0} + 32'd1;
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      phase <= 32'd0;
      frame_0 <= 16'd0;
      frame_1 <= 16'd0;
      fraction <= 16'd0;
      raw_l0 <= '0;
      raw_l1 <= '0;
      raw_r0 <= '0;
      raw_r1 <= '0;
      sample_valid <= 1'b0;
      sample_l <= '0;
      sample_r <= '0;
    end else begin
      sample_valid <= 1'b0;

      if (config_commit) begin
        phase <= voice_config.phase_init;
        state <= IDLE;
      end else begin
        unique case (state)
          IDLE: begin
            if (sample_tick && voice_config.enable && config_valid &&
                (voice_config.loop_end <= voice_config.length)) begin
              frame_0 <= phase[31:16];
              frame_1 <= (phase[31:16] + 16'd1 >= voice_config.loop_end) ?
                         voice_config.loop_start : phase[31:16] + 16'd1;
              fraction <= phase[15:0];

              if (phase_sum >= loop_end_phase)
                phase <= wrapped_phase[31:0];
              else
                phase <= phase_sum[31:0];
              state <= REQ_L0;
            end
          end
          REQ_L0:  if (mem_req_ready) state <= WAIT_L0;
          WAIT_L0: if (mem_rsp_valid) begin raw_l0 <= mem_rsp_data; state <= REQ_L1; end
          REQ_L1:  if (mem_req_ready) state <= WAIT_L1;
          WAIT_L1: if (mem_rsp_valid) begin
            raw_l1 <= mem_rsp_data;
            if (voice_config.stereo)
              state <= REQ_R0;
            else begin
              raw_r0 <= raw_l0;
              raw_r1 <= mem_rsp_data;
              state <= PRODUCE;
            end
          end
          REQ_R0:  if (mem_req_ready) state <= WAIT_R0;
          WAIT_R0: if (mem_rsp_valid) begin raw_r0 <= mem_rsp_data; state <= REQ_R1; end
          REQ_R1:  if (mem_req_ready) state <= WAIT_R1;
          WAIT_R1: if (mem_rsp_valid) begin raw_r1 <= mem_rsp_data; state <= PRODUCE; end
          PRODUCE: begin
            sample_l <= gained_l;
            sample_r <= gained_r;
            sample_valid <= 1'b1;
            state <= IDLE;
          end
          default: state <= IDLE;
        endcase
      end
    end
  end
endmodule
