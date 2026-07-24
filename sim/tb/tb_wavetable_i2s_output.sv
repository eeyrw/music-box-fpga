module tb_wavetable_i2s_output;
  import synth_pkg::*;

  localparam int FIFO_DEPTH = 8;
  localparam int START_LEVEL = 6;

  logic clk = 1'b0;
  logic rst;
  logic sample_valid;
  logic sample_ready;
  pcm_t sample_l;
  pcm_t sample_r;
  logic i2s_sample_ready;
  logic fifo_sample_valid;
  logic underrun_pulse;
  logic sample_drop_pulse;
  logic [$clog2(FIFO_DEPTH+1)-1:0] output_fifo_level;
  logic playback_started;
  logic [31:0] render_sample_counter;
  logic [31:0] played_sample_counter;
  logic [31:0] audio_lead;
  logic [$clog2(FIFO_DEPTH+1)-1:0] minimum_fifo_level;
  logic i2s_bclk;
  logic i2s_lrclk;
  logic i2s_sdata;
  int startup_underruns = 0;
  int errors = 0;

  always #5 clk <= ~clk;

  wavetable_i2s_output #(
    .OUTPUT_FIFO_DEPTH(FIFO_DEPTH),
    .START_LEVEL(START_LEVEL),
    .SYS_CLK_HZ(128),
    .SAMPLE_RATE_HZ(1)
  ) dut (.*);

  always_ff @(posedge clk) begin
    if (!rst && !playback_started && underrun_pulse)
      startup_underruns <= startup_underruns + 1;
  end

  task automatic push_sample(input int value);
    begin
      @(negedge clk);
      while (!sample_ready) @(negedge clk);
      sample_l = pcm_t'(value);
      sample_r = pcm_t'(-value);
      sample_valid = 1'b1;
      @(negedge clk);
      sample_valid = 1'b0;
    end
  endtask

  initial begin
    rst = 1'b1;
    sample_valid = 1'b0;
    sample_l = '0;
    sample_r = '0;
    repeat (4) @(negedge clk);
    rst = 1'b0;

    for (int i = 1; i < START_LEVEL; i++)
      push_sample(i);
    repeat (160) @(negedge clk);

    if (playback_started || output_fifo_level != $bits(output_fifo_level)'(START_LEVEL-1) ||
        startup_underruns != 0) begin
      $error("startup gate opened early: started=%0b level=%0d underruns=%0d",
             playback_started, output_fifo_level, startup_underruns);
      errors++;
    end

    push_sample(START_LEVEL);
    wait (playback_started);
    @(negedge clk);
    if (render_sample_counter != 32'(START_LEVEL) ||
        minimum_fifo_level != $bits(minimum_fifo_level)'(START_LEVEL)) begin
      $error("startup counters got rendered/min=%0d/%0d expected %0d",
             render_sample_counter, minimum_fifo_level, START_LEVEL);
      errors++;
    end

    wait (played_sample_counter == 32'd1);
    @(negedge clk);
    if (output_fifo_level >= $bits(output_fifo_level)'(START_LEVEL)) begin
      $error("I2S did not consume after startup, level=%0d", output_fifo_level);
      errors++;
    end
    if (audio_lead != (render_sample_counter - played_sample_counter)) begin
      $error("audio_lead mismatch");
      errors++;
    end
    if (sample_drop_pulse || startup_underruns != 0) begin
      $error("unexpected drop/startup underrun");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: wavetable I2S output errors=%0d", errors);
    $display("PASS: wavetable I2S output");
    $finish;
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_outputs;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_outputs = i2s_sample_ready | fifo_sample_valid | underrun_pulse |
                          i2s_bclk | i2s_lrclk | i2s_sdata;
endmodule
