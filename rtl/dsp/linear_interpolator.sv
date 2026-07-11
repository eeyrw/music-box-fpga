module linear_interpolator (
  input  synth_pkg::pcm_t sample_0,
  input  synth_pkg::pcm_t sample_1,
  input  logic [15:0]     fraction,
  output synth_pkg::pcm_t sample_out
);
  logic signed [16:0] difference;
  logic signed [32:0] difference_extended;
  logic signed [32:0] fraction_extended;
  logic signed [32:0] product;
  logic signed [16:0] scaled_difference;
  logic signed [17:0] interpolated;

  always_comb begin
    difference = $signed(sample_1) - $signed(sample_0);
    difference_extended = {{16{difference[16]}}, difference};
    fraction_extended = $signed({17'd0, fraction});
    product = difference_extended * fraction_extended;
    scaled_difference = $signed(product[32:16]);
    interpolated = $signed({{2{sample_0[15]}}, sample_0}) +
                   $signed({scaled_difference[16], scaled_difference});
    if (interpolated > 18'sd32767)
      sample_out = 16'sh7fff;
    else if (interpolated < -18'sd32768)
      sample_out = 16'sh8000;
    else
      sample_out = interpolated[15:0];
  end
endmodule
