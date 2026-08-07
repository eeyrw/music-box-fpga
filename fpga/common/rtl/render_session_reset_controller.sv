`timescale 1ns/1ps

module render_session_reset_controller (
  input  logic        clk,
  input  logic        rst,
  input  logic        request,
  input  logic        drain_complete,
  output logic        acknowledge,
  output logic        session_reset,
  output logic [31:0] session_epoch
);
  typedef enum logic [1:0] {
    RESET_IDLE,
    RESET_ASSERT,
    RESET_DRAIN,
    RESET_ACKNOWLEDGE
  } reset_state_t;

  reset_state_t state_q;

  assign session_reset = (state_q == RESET_ASSERT) ||
                         (state_q == RESET_DRAIN);
  assign acknowledge = state_q == RESET_ACKNOWLEDGE;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= RESET_IDLE;
      session_epoch <= 32'd0;
    end else begin
      unique case (state_q)
        RESET_IDLE: begin
          if (request)
            state_q <= RESET_ASSERT;
        end
        RESET_ASSERT: begin
          state_q <= RESET_DRAIN;
        end
        RESET_DRAIN: begin
          if (drain_complete) begin
            session_epoch <= session_epoch + 32'd1;
            state_q <= RESET_ACKNOWLEDGE;
          end
        end
        RESET_ACKNOWLEDGE: begin
          if (!request)
            state_q <= RESET_IDLE;
        end
        default: state_q <= RESET_IDLE;
      endcase
    end
  end
endmodule
