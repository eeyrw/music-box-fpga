module control_action_fifo #(
  parameter int DEPTH = 32
) (
  input  logic clk,
  input  logic rst,
  input  logic flush,
  input  logic push_valid,
  output logic push_ready,
  input  synth_pkg::control_action_t push_action,
  output logic head_valid,
  input  logic head_ready,
  output synth_pkg::control_action_t head_action,
  output logic [$clog2(DEPTH+1)-1:0] level
);
  localparam int PTR_WIDTH = $clog2(DEPTH);
  synth_pkg::control_action_t storage [0:DEPTH-1];
  logic [PTR_WIDTH-1:0] read_pointer;
  logic [PTR_WIDTH-1:0] write_pointer;
  logic push;
  logic pop;

  assign head_valid = level != '0;
  assign push_ready = (level != $bits(level)'(DEPTH)) || pop;
  assign push = push_valid && push_ready;
  assign pop = head_valid && head_ready;
  assign head_action = storage[read_pointer];

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      read_pointer <= '0;
      write_pointer <= '0;
      level <= '0;
    end else begin
      if (push) begin
        storage[write_pointer] <= push_action;
        write_pointer <= (write_pointer == PTR_WIDTH'(DEPTH-1)) ? '0 : write_pointer + 1'b1;
      end
      if (pop)
        read_pointer <= (read_pointer == PTR_WIDTH'(DEPTH-1)) ? '0 : read_pointer + 1'b1;

      unique case ({push, pop})
        2'b10: level <= level + 1'b1;
        2'b01: level <= level - 1'b1;
        default: level <= level;
      endcase
    end
  end
endmodule
