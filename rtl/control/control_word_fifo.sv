module control_word_fifo #(
  parameter int DEPTH = 16,
  parameter int WIDTH = 32
) (
  input  logic clk,
  input  logic rst,
  input  logic flush,
  input  logic push,
  input  logic [WIDTH-1:0] push_word,
  output logic push_ready,
  input  logic pop,
  output logic head_valid,
  output logic [WIDTH-1:0] head_word,
  output logic empty,
  output logic full,
  output logic [$clog2(DEPTH+1)-1:0] level
);
  localparam int PTR_WIDTH = $clog2(DEPTH);

  logic [WIDTH-1:0] storage [DEPTH];
  logic [PTR_WIDTH-1:0] rd_ptr;
  logic [PTR_WIDTH-1:0] wr_ptr;
  logic [$clog2(DEPTH+1)-1:0] count;
  logic do_push;
  logic do_pop;

  assign empty = (count == '0);
  assign full = (count == DEPTH[$clog2(DEPTH+1)-1:0]);
  assign push_ready = !full;
  assign head_valid = !empty;
  assign head_word = storage[rd_ptr];
  assign level = count;
  assign do_push = push && push_ready;
  assign do_pop = pop && head_valid;

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      rd_ptr <= '0;
      wr_ptr <= '0;
      count <= '0;
      storage <= '{default: '0};
    end else begin
      if (do_push) begin
        storage[wr_ptr] <= push_word;
        wr_ptr <= (wr_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
      end
      if (do_pop) begin
        rd_ptr <= (rd_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : rd_ptr + 1'b1;
      end
      count <= count + {{($clog2(DEPTH+1)-1){1'b0}}, do_push} -
               {{($clog2(DEPTH+1)-1){1'b0}}, do_pop};
    end
  end
endmodule
