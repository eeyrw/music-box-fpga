module tb_voice_phase_frame;
  import synth_pkg::*;

  logic stereo;
  logic [1:0] loop_mode;
  logic released;
  logic [PHASE_WIDTH-1:0] phase;
  logic [PHASE_WIDTH-1:0] phase_r;
  logic [PHASE_WIDTH-1:0] phase_inc;
  logic [PHASE_FRAME_WIDTH-1:0] length;
  logic [PHASE_FRAME_WIDTH-1:0] length_r;
  logic [PHASE_FRAME_WIDTH-1:0] loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] loop_start_r;
  logic [PHASE_FRAME_WIDTH-1:0] loop_end;
  logic [PHASE_FRAME_WIDTH-1:0] loop_end_r;
  logic done;
  logic [PHASE_FRAME_WIDTH-1:0] frame_0;
  logic [PHASE_FRAME_WIDTH-1:0] frame_1;
  logic [PHASE_FRAME_WIDTH-1:0] frame_r0;
  logic [PHASE_FRAME_WIDTH-1:0] frame_r1;
  logic [PHASE_FRAC_WIDTH-1:0] fraction;
  logic [PHASE_WIDTH-1:0] next_phase;
  logic [PHASE_WIDTH-1:0] next_phase_r;
  int errors;

  voice_phase_frame dut (
    .stereo,
    .loop_mode,
    .released,
    .phase,
    .phase_r,
    .phase_inc,
    .length,
    .length_r,
    .loop_start,
    .loop_start_r,
    .loop_end,
    .loop_end_r,
    .done,
    .frame_0,
    .frame_1,
    .frame_r0,
    .frame_r1,
    .fraction,
    .next_phase,
    .next_phase_r
  );

  function automatic logic [PHASE_WIDTH-1:0] q8(input int frame, input int frac);
    q8 = (PHASE_WIDTH'(frame) << PHASE_FRAC_WIDTH) | PHASE_WIDTH'(frac);
  endfunction

  task automatic set_defaults;
    begin
      stereo = 1'b0;
      loop_mode = LOOP_MODE_NONE;
      released = 1'b0;
      phase = '0;
      phase_r = '0;
      phase_inc = q8(1, 0);
      length = 24'd8;
      length_r = 24'd8;
      loop_start = 24'd2;
      loop_start_r = 24'd2;
      loop_end = 24'd6;
      loop_end_r = 24'd6;
    end
  endtask

  task automatic check_case(
    input string name,
    input logic exp_done,
    input logic [PHASE_FRAME_WIDTH-1:0] exp_frame_0,
    input logic [PHASE_FRAME_WIDTH-1:0] exp_frame_1,
    input logic [PHASE_FRAME_WIDTH-1:0] exp_frame_r0,
    input logic [PHASE_FRAME_WIDTH-1:0] exp_frame_r1,
    input logic [PHASE_FRAC_WIDTH-1:0] exp_fraction,
    input logic [PHASE_WIDTH-1:0] exp_next_phase,
    input logic [PHASE_WIDTH-1:0] exp_next_phase_r
  );
    begin
      #1;
      if (done !== exp_done) begin
        $display("FAIL %s: done got %0d expected %0d", name, done, exp_done);
        errors++;
      end
      if (frame_0 !== exp_frame_0 || frame_1 !== exp_frame_1 ||
          frame_r0 !== exp_frame_r0 || frame_r1 !== exp_frame_r1) begin
        $display("FAIL %s: frames got L=%0d/%0d R=%0d/%0d expected L=%0d/%0d R=%0d/%0d",
                 name, frame_0, frame_1, frame_r0, frame_r1,
                 exp_frame_0, exp_frame_1, exp_frame_r0, exp_frame_r1);
        errors++;
      end
      if (fraction !== exp_fraction) begin
        $display("FAIL %s: fraction got %0d expected %0d", name, fraction, exp_fraction);
        errors++;
      end
      if (next_phase !== exp_next_phase || next_phase_r !== exp_next_phase_r) begin
        $display("FAIL %s: next phase got L=%08x R=%08x expected L=%08x R=%08x",
                 name, next_phase, next_phase_r, exp_next_phase, exp_next_phase_r);
        errors++;
      end
    end
  endtask

  initial begin
    errors = 0;

    set_defaults();
    phase = q8(3, 128);
    check_case("mono no-loop fractional", 1'b0,
               24'd3, 24'd4, 24'd0, 24'd0, 8'h80, q8(4, 128), q8(1, 0));

    set_defaults();
    phase = q8(7, 0);
    check_case("mono no-loop endpoint clamp", 1'b0,
               24'd7, 24'd7, 24'd0, 24'd0, 8'h00, q8(8, 0), q8(1, 0));

    set_defaults();
    phase = q8(8, 0);
    check_case("mono no-loop done clamp", 1'b1,
               24'd7, 24'd7, 24'd0, 24'd0, 8'h00, q8(9, 0), q8(1, 0));

    set_defaults();
    loop_mode = LOOP_MODE_CONTINUOUS;
    phase = q8(5, 128);
    phase_inc = q8(1, 0);
    check_case("mono loop wraps next phase", 1'b0,
               24'd5, 24'd2, 24'd0, 24'd0, 8'h80, q8(2, 128), q8(1, 0));

    set_defaults();
    stereo = 1'b1;
    loop_mode = LOOP_MODE_CONTINUOUS;
    phase = q8(2, 64);
    phase_r = q8(6, 0);
    phase_inc = q8(1, 0);
    length_r = 24'd10;
    loop_start_r = 24'd4;
    loop_end_r = 24'd7;
    check_case("stereo independent right loop", 1'b0,
               24'd2, 24'd3, 24'd6, 24'd4, 8'h40, q8(3, 64), q8(4, 0));

    set_defaults();
    loop_mode = LOOP_MODE_UNTIL_RELEASE;
    released = 1'b1;
    phase = q8(8, 0);
    check_case("loop until release stops", 1'b1,
               24'd7, 24'd7, 24'd0, 24'd0, 8'h00, q8(9, 0), q8(1, 0));

    if (errors != 0) begin
      $fatal(1, "FAIL: voice_phase_frame errors=%0d", errors);
    end
    $display("PASS: voice_phase_frame");
    $finish;
  end
endmodule
