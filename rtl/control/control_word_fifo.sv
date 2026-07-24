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

  (* ram_style = "block" *) logic [WIDTH-1:0] storage [0:DEPTH-1];
  logic [PTR_WIDTH-1:0] rd_ptr;
  logic [PTR_WIDTH-1:0] wr_ptr;
  logic [$clog2(DEPTH+1)-1:0] count;
  logic do_push;
  logic do_pop;
  logic ram_read_enable;

  assign empty = (count == '0);
  assign full = (count == DEPTH[$clog2(DEPTH+1)-1:0]);
  assign push_ready = !full || do_pop;
  assign level = count;
  assign do_pop = pop && head_valid;
  assign do_push = push && push_ready;
  assign ram_read_enable = (!head_valid && !empty) ||
                           (do_pop && (count > 1));

  always_ff @(posedge clk) begin
    if (do_push)
      storage[wr_ptr] <= push_word;
    if (ram_read_enable)
      head_word <= storage[rd_ptr];
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      rd_ptr <= '0;
      wr_ptr <= '0;
      count <= '0;
      head_valid <= 1'b0;
    end else begin
      if (do_push) begin
        wr_ptr <= (wr_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
      end
      if (ram_read_enable) begin
        rd_ptr <= (rd_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : rd_ptr + 1'b1;
      end
      if (do_pop)
        head_valid <= (count > 1);
      else if (ram_read_enable)
        head_valid <= 1'b1;

      unique case ({do_push, do_pop})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
      endcase
    end
  end
endmodule
