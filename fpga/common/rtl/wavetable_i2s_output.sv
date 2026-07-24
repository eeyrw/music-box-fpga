module wavetable_i2s_output #(
  parameter int OUTPUT_FIFO_DEPTH = 64,
  parameter int START_LEVEL = 48,
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
) (
  input  logic            clk,
  input  logic            rst,
  input  logic            sample_valid,
  output logic            sample_ready,
  input  synth_pkg::pcm_t sample_l,
  input  synth_pkg::pcm_t sample_r,
  output logic            i2s_sample_ready,
  output logic            fifo_sample_valid,
  output logic            underrun_pulse,
  output logic            sample_drop_pulse,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic            playback_started,
  output logic [31:0]     render_sample_counter,
  output logic [31:0]     played_sample_counter,
  output logic [31:0]     audio_lead,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] minimum_fifo_level,
  output logic            i2s_bclk,
  output logic            i2s_lrclk,
  output logic            i2s_sdata
);
  logic fifo_input_ready;
  logic fifo_sample_ready;
  synth_pkg::pcm_t fifo_sample_l;
  synth_pkg::pcm_t fifo_sample_r;
  logic raw_underrun_pulse;
  logic i2s_frame_pulse;

  initial begin
    if (START_LEVEL > OUTPUT_FIFO_DEPTH)
      $error("START_LEVEL must not exceed OUTPUT_FIFO_DEPTH");
  end

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

  assign sample_ready = fifo_input_ready;
  assign fifo_sample_ready = playback_started && fifo_sample_valid && i2s_sample_ready;
  assign underrun_pulse = playback_started && raw_underrun_pulse;
  assign audio_lead = render_sample_counter - played_sample_counter;

  i2s_tx #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) audio_tx (
    .clk,
    .rst,
    .sample_valid(playback_started && fifo_sample_valid),
    .sample_ready(i2s_sample_ready),
    .sample_l(fifo_sample_l),
    .sample_r(fifo_sample_r),
    .underrun_pulse(raw_underrun_pulse),
    .frame_pulse(i2s_frame_pulse),
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      playback_started <= 1'b0;
      render_sample_counter <= 32'd0;
      played_sample_counter <= 32'd0;
      minimum_fifo_level <= START_LEVEL[$clog2(OUTPUT_FIFO_DEPTH+1)-1:0];
    end else begin
      if (sample_valid && sample_ready && render_sample_counter != 32'hffff_ffff)
        render_sample_counter <= render_sample_counter + 32'd1;

      if (!playback_started &&
          (output_fifo_level >= START_LEVEL[$clog2(OUTPUT_FIFO_DEPTH+1)-1:0])) begin
        playback_started <= 1'b1;
        minimum_fifo_level <= output_fifo_level;
      end

      if (playback_started && i2s_frame_pulse) begin
        if (played_sample_counter != 32'hffff_ffff)
          played_sample_counter <= played_sample_counter + 32'd1;
        if (output_fifo_level < minimum_fifo_level)
          minimum_fifo_level <= output_fifo_level;
      end
    end
  end
endmodule
