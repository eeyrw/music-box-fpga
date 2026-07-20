module output_sample_fifo #(
  parameter int DEPTH = 8
) (
  input  logic            clk,
  input  logic            rst,
  input  logic            in_valid,
  output logic            in_ready,
  input  synth_pkg::pcm_t in_l,
  input  synth_pkg::pcm_t in_r,
  output logic            out_valid,
  input  logic            out_ready,
  output synth_pkg::pcm_t out_l,
  output synth_pkg::pcm_t out_r,
  output logic            overflow_pulse,
  output logic [$clog2(DEPTH+1)-1:0] level
);
  localparam int PTR_WIDTH = $clog2(DEPTH);

  synth_pkg::stereo_pcm_t fifo [0:DEPTH-1];
  synth_pkg::stereo_pcm_t in_sample;
  synth_pkg::stereo_pcm_t out_sample;
  logic [PTR_WIDTH-1:0] rd_ptr;
  logic [PTR_WIDTH-1:0] wr_ptr;

  logic do_pop;
  logic do_push;

  assign out_valid = level != '0;
  assign in_ready = (level != DEPTH[$clog2(DEPTH+1)-1:0]) || do_pop;
  assign do_pop = out_valid && out_ready;
  assign do_push = in_valid && in_ready;
  assign in_sample.l = in_l;
  assign in_sample.r = in_r;
  assign out_sample = fifo[rd_ptr];
  assign out_l = out_sample.l;
  assign out_r = out_sample.r;

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_ptr <= '0;
      wr_ptr <= '0;
      level <= '0;
      overflow_pulse <= 1'b0;
    end else begin
      overflow_pulse <= in_valid && !in_ready;

      if (do_push) begin
        fifo[wr_ptr] <= in_sample;
        if (wr_ptr == PTR_WIDTH'(DEPTH - 1))
          wr_ptr <= '0;
        else
          wr_ptr <= wr_ptr + 1'b1;
      end

      if (do_pop) begin
        if (rd_ptr == PTR_WIDTH'(DEPTH - 1))
          rd_ptr <= '0;
        else
          rd_ptr <= rd_ptr + 1'b1;
      end

      unique case ({do_push, do_pop})
        2'b10: level <= level + 1'b1;
        2'b01: level <= level - 1'b1;
        default: level <= level;
      endcase
    end
  end
endmodule
