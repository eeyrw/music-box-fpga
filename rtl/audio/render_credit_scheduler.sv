module render_credit_scheduler #(
  parameter int FIFO_DEPTH = 64,
  parameter int TARGET_LEVEL = 48
) (
  input  logic clk,
  input  logic rst,
  input  logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_level,
  input  logic renderer_busy,
  input  logic control_batch_complete,
  output logic render_inflight,
  output logic render_credit,
  output logic render_start
);
  localparam int LEVEL_WIDTH = $clog2(FIFO_DEPTH + 1);
  logic [LEVEL_WIDTH:0] occupancy;

  initial begin
    if ((TARGET_LEVEL < 1) || (TARGET_LEVEL > FIFO_DEPTH))
      $error("TARGET_LEVEL must be within the PCM FIFO");
  end

  assign render_inflight = renderer_busy;
  assign occupancy = {1'b0, fifo_level} + {{LEVEL_WIDTH{1'b0}}, render_inflight};
  assign render_credit = occupancy < (LEVEL_WIDTH+1)'(TARGET_LEVEL);
  assign render_start = !rst && !renderer_busy && render_credit && control_batch_complete;

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_clk;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_clk = clk;
endmodule
