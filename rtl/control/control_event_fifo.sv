module control_event_fifo #(
  parameter int DEPTH = 16
) (
  input  logic clk,
  input  logic rst,
  input  logic push,
  input  synth_pkg::envelope_event_t push_event,
  output logic push_ready,
  input  logic [2:0] pop_count,
  output logic head_valid,
  output synth_pkg::envelope_event_t head_event,
  output logic head1_valid,
  output synth_pkg::envelope_event_t head1_event,
  output logic head2_valid,
  output synth_pkg::envelope_event_t head2_event,
  output logic head3_valid,
  output synth_pkg::envelope_event_t head3_event,
  output logic empty,
  output logic full,
  output logic [$clog2(DEPTH+1)-1:0] level
);
  import synth_pkg::*;

  localparam int PTR_WIDTH = $clog2(DEPTH);

  envelope_event_t storage [DEPTH];
  logic [PTR_WIDTH-1:0] rd_ptr;
  logic [PTR_WIDTH-1:0] wr_ptr;
  logic [$clog2(DEPTH+1)-1:0] count;
  logic [$clog2(DEPTH+1)-1:0] pop_actual;
  logic [$clog2(DEPTH+1)-1:0] pop_requested;
  logic do_push;

  function automatic logic [PTR_WIDTH-1:0] ptr_add(input logic [PTR_WIDTH-1:0] ptr,
                                                   input int unsigned amount);
    int unsigned next;
    begin
      next = int'(ptr) + amount;
      if (next >= DEPTH)
        ptr_add = PTR_WIDTH'(next - DEPTH);
      else
        ptr_add = PTR_WIDTH'(next);
    end
  endfunction

  assign empty = (count == '0);
  assign full = (count == DEPTH[$clog2(DEPTH+1)-1:0]);
  assign push_ready = !full;
  assign head_valid = !empty;
  assign head_event = storage[rd_ptr];
  assign head1_valid = (count >= 2);
  assign head1_event = storage[ptr_add(rd_ptr, 1)];
  assign head2_valid = (count >= 3);
  assign head2_event = storage[ptr_add(rd_ptr, 2)];
  assign head3_valid = (count >= 4);
  assign head3_event = storage[ptr_add(rd_ptr, 3)];
  assign level = count;
  assign do_push = push && push_ready;
  assign pop_requested = {{($clog2(DEPTH+1)-3){1'b0}}, pop_count};
  assign pop_actual = (pop_requested > count) ? count : pop_requested;

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_ptr <= '0;
      wr_ptr <= '0;
      count <= '0;
      storage <= '{default: '0};
    end else begin
      if (do_push) begin
        storage[wr_ptr] <= push_event;
        wr_ptr <= (wr_ptr == PTR_WIDTH'(DEPTH - 1)) ? '0 : wr_ptr + 1'b1;
      end
      if (pop_actual != '0) begin
        rd_ptr <= ptr_add(rd_ptr, int'(pop_actual));
      end
      count <= count + {{($clog2(DEPTH+1)-1){1'b0}}, do_push} - pop_actual;
    end
  end
endmodule
