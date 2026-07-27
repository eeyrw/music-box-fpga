module mono_phase_frame (
  input  logic [1:0]                              loop_mode,
  input  logic                                    released,
  input  logic [synth_pkg::PHASE_WIDTH-1:0]       phase,
  input  logic [synth_pkg::PHASE_WIDTH-1:0]       phase_inc,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] length,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] loop_start,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] loop_end,
  output logic                                    done,
  output logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] frame_0,
  output logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] frame_1,
  output logic [synth_pkg::PHASE_FRAC_WIDTH-1:0]  fraction,
  output logic [synth_pkg::PHASE_WIDTH-1:0]       next_phase
);
  import synth_pkg::*;

  logic [PHASE_WIDTH:0] phase_sum;
  logic [PHASE_WIDTH:0] loop_end_phase;
  logic [PHASE_WIDTH-1:0] loop_length_phase;
  logic [PHASE_FRAME_WIDTH-1:0] current_frame;
  logic loop_active;

  always_comb begin
    phase_sum = {1'b0, phase} + {1'b0, phase_inc};
    loop_end_phase = {1'b0, loop_end, {PHASE_FRAC_WIDTH{1'b0}}};
    loop_length_phase = {(loop_end - loop_start),
                         {PHASE_FRAC_WIDTH{1'b0}}};
    current_frame = phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH];
    fraction = phase[PHASE_FRAC_WIDTH-1:0];
    loop_active = (loop_mode == LOOP_MODE_CONTINUOUS) ||
                  ((loop_mode == LOOP_MODE_UNTIL_RELEASE) && !released);
    done = !loop_active && (current_frame >= length);

    if (done) begin
      frame_0 = length - PHASE_FRAME_WIDTH'(1);
      frame_1 = length - PHASE_FRAME_WIDTH'(1);
    end else begin
      frame_0 = current_frame;
      if (loop_active) begin
        frame_1 = (current_frame + PHASE_FRAME_WIDTH'(1) >= loop_end) ?
                  loop_start : current_frame + PHASE_FRAME_WIDTH'(1);
      end else begin
        frame_1 = (current_frame + PHASE_FRAME_WIDTH'(1) >= length) ?
                  current_frame : current_frame + PHASE_FRAME_WIDTH'(1);
      end
    end

    next_phase = (loop_active && phase_sum >= loop_end_phase) ?
                 phase_sum[PHASE_WIDTH-1:0] - loop_length_phase :
                 phase_sum[PHASE_WIDTH-1:0];
  end
endmodule
