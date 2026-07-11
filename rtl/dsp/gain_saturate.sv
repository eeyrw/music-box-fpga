module gain_saturate (
  input  synth_pkg::pcm_t      sample_in,
  input  logic signed [15:0]   gain,
  output synth_pkg::pcm_t      sample_out
);
  // Gain is signed Q1.15. Multiplying a signed 16-bit sample by Q1.15 produces
  // a Q16.15 product, so shifting right by 15 returns signed PCM units.
  logic signed [31:0] product;
  logic signed [31:0] scaled;

  always_comb begin
    product = $signed(sample_in) * $signed(gain);
    scaled = product >>> 15;

    // Clamp rather than wrap so full-scale gain or negative samples cannot
    // overflow the 16-bit audio output.
    if (scaled > 32'sd32767)
      sample_out = 16'sh7fff;
    else if (scaled < -32'sd32768)
      sample_out = 16'sh8000;
    else
      sample_out = scaled[15:0];
  end
endmodule
