module gain_saturate (
  input  synth_pkg::pcm_t      sample_in,
  input  logic signed [15:0]   gain,
  output synth_pkg::pcm_t      sample_out
);
  logic signed [31:0] product;
  logic signed [31:0] scaled;

  always_comb begin
    product = $signed(sample_in) * $signed(gain);
    scaled = product >>> 15;
    if (scaled > 32'sd32767)
      sample_out = 16'sh7fff;
    else if (scaled < -32'sd32768)
      sample_out = 16'sh8000;
    else
      sample_out = scaled[15:0];
  end
endmodule
