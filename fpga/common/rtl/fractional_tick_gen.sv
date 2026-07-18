module fractional_tick_gen #(
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int TICK_HZ = 48_000,
  parameter int ACC_WIDTH = 32
) (
  input  logic clk,
  input  logic rst,
  output logic tick
);
  localparam longint unsigned PHASE_SCALE = 64'd1 << ACC_WIDTH;
  localparam longint unsigned PHASE_INC_LONG =
      ((longint'(TICK_HZ) * PHASE_SCALE) + (longint'(SYS_CLK_HZ) / 2)) /
      longint'(SYS_CLK_HZ);
  localparam logic [ACC_WIDTH-1:0] PHASE_INC = PHASE_INC_LONG[ACC_WIDTH-1:0];

  logic [ACC_WIDTH-1:0] phase;
  logic [ACC_WIDTH:0] phase_sum;

  assign phase_sum = {1'b0, phase} + {1'b0, PHASE_INC};

  always_ff @(posedge clk) begin
    if (rst) begin
      phase <= '0;
      tick <= 1'b0;
    end else begin
      phase <= phase_sum[ACC_WIDTH-1:0];
      tick <= phase_sum[ACC_WIDTH];
    end
  end
endmodule
