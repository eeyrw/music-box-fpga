module wavetable_i2s_output #(
  parameter int OUTPUT_FIFO_DEPTH = 8,
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
) (
  input  logic            clk,
  input  logic            rst,
  input  logic            sample_valid,
  input  synth_pkg::pcm_t sample_l,
  input  synth_pkg::pcm_t sample_r,
  output logic            i2s_sample_ready,
  output logic            fifo_sample_valid,
  output logic            underrun_pulse,
  output logic            sample_drop_pulse,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic            i2s_bclk,
  output logic            i2s_lrclk,
  output logic            i2s_sdata
);
  logic fifo_input_ready;
  logic fifo_sample_ready;
  synth_pkg::pcm_t fifo_sample_l;
  synth_pkg::pcm_t fifo_sample_r;

  output_sample_fifo #(.DEPTH(OUTPUT_FIFO_DEPTH)) output_fifo (
    .clk,
    .rst,
    .in_valid(sample_valid),
    .in_ready(fifo_input_ready),
    .in_l(sample_l),
    .in_r(sample_r),
    .out_valid(fifo_sample_valid),
    .out_ready(fifo_sample_ready),
    .out_l(fifo_sample_l),
    .out_r(fifo_sample_r),
    .overflow_pulse(sample_drop_pulse),
    .level(output_fifo_level)
  );

  assign fifo_sample_ready = fifo_sample_valid && i2s_sample_ready;

  i2s_tx #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) audio_tx (
    .clk,
    .rst,
    .sample_valid(fifo_sample_valid && i2s_sample_ready),
    .sample_ready(i2s_sample_ready),
    .sample_l(fifo_sample_l),
    .sample_r(fifo_sample_r),
    .underrun_pulse,
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata
  );

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_fifo_input_ready;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_fifo_input_ready = fifo_input_ready;
endmodule
