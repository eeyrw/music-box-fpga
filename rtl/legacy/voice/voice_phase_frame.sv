module voice_phase_frame (
  input  logic                                  stereo,
  input  logic [1:0]                            loop_mode,
  input  logic                                  released,
  input  logic [synth_pkg::PHASE_WIDTH-1:0]     phase,
  input  logic [synth_pkg::PHASE_WIDTH-1:0]     phase_r,
  input  logic [synth_pkg::PHASE_WIDTH-1:0]     phase_inc,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] length,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] length_r,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] loop_start,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] loop_start_r,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] loop_end,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] loop_end_r,
  output logic                                  done,
  output logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] frame_0,
  output logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] frame_1,
  output logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] frame_r0,
  output logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] frame_r1,
  output logic [synth_pkg::PHASE_FRAC_WIDTH-1:0] fraction,
  output logic [synth_pkg::PHASE_WIDTH-1:0]     next_phase,
  output logic [synth_pkg::PHASE_WIDTH-1:0]     next_phase_r
);
  import synth_pkg::*;

  logic [PHASE_WIDTH:0] phase_sum;
  logic [PHASE_WIDTH:0] phase_r_sum;
  logic [PHASE_WIDTH:0] loop_end_phase;
  logic [PHASE_WIDTH:0] loop_end_phase_r;
  logic [PHASE_WIDTH-1:0] loop_length_phase;
  logic [PHASE_WIDTH-1:0] loop_length_phase_r;
  logic [PHASE_WIDTH-1:0] wrapped_phase;
  logic [PHASE_WIDTH-1:0] wrapped_phase_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_frame;
  logic [PHASE_FRAME_WIDTH-1:0] current_frame_r;
  logic loop_active;
  logic done_l;
  logic done_r;

  always_comb begin
    phase_sum = {1'b0, phase} + {1'b0, phase_inc};
    phase_r_sum = {1'b0, phase_r} + {1'b0, phase_inc};
    loop_end_phase = {1'b0, loop_end, {PHASE_FRAC_WIDTH{1'b0}}};
    loop_end_phase_r = {1'b0, loop_end_r, {PHASE_FRAC_WIDTH{1'b0}}};
    loop_length_phase = {(loop_end - loop_start), {PHASE_FRAC_WIDTH{1'b0}}};
    loop_length_phase_r = {(loop_end_r - loop_start_r), {PHASE_FRAC_WIDTH{1'b0}}};
    wrapped_phase = phase_sum[PHASE_WIDTH-1:0] - loop_length_phase;
    wrapped_phase_r = phase_r_sum[PHASE_WIDTH-1:0] - loop_length_phase_r;
    current_frame = phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH];
    current_frame_r = phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH];
    fraction = phase[PHASE_FRAC_WIDTH-1:0];

    loop_active = (loop_mode == LOOP_MODE_CONTINUOUS) ||
                  ((loop_mode == LOOP_MODE_UNTIL_RELEASE) && !released);
    done_l = (loop_mode == LOOP_MODE_NONE || !loop_active) &&
             (current_frame >= length);
    done_r = !stereo || ((loop_mode == LOOP_MODE_NONE || !loop_active) &&
             (current_frame_r >= length_r));
    done = done_l && done_r;

    if (done_l) begin
      frame_0 = length - PHASE_FRAME_WIDTH'(1);
      frame_1 = length - PHASE_FRAME_WIDTH'(1);
    end else begin
      frame_0 = current_frame;
      if (loop_active)
        frame_1 = (current_frame + PHASE_FRAME_WIDTH'(1) >= loop_end) ?
                  loop_start : current_frame + PHASE_FRAME_WIDTH'(1);
      else
        frame_1 = (current_frame + PHASE_FRAME_WIDTH'(1) >= length) ?
                  current_frame : current_frame + PHASE_FRAME_WIDTH'(1);
    end

    if (!stereo || done_r) begin
      frame_r0 = stereo ? (length_r - PHASE_FRAME_WIDTH'(1)) : '0;
      frame_r1 = stereo ? (length_r - PHASE_FRAME_WIDTH'(1)) : '0;
    end else begin
      frame_r0 = current_frame_r;
      if (loop_active)
        frame_r1 = (current_frame_r + PHASE_FRAME_WIDTH'(1) >= loop_end_r) ?
                   loop_start_r : current_frame_r + PHASE_FRAME_WIDTH'(1);
      else
        frame_r1 = (current_frame_r + PHASE_FRAME_WIDTH'(1) >= length_r) ?
                   current_frame_r : current_frame_r + PHASE_FRAME_WIDTH'(1);
    end

    next_phase = (loop_active && phase_sum >= loop_end_phase) ?
                 wrapped_phase : phase_sum[PHASE_WIDTH-1:0];
    next_phase_r = (loop_active && phase_r_sum >= loop_end_phase_r) ?
                   wrapped_phase_r : phase_r_sum[PHASE_WIDTH-1:0];
  end
endmodule
