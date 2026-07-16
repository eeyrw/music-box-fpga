module linear_interpolator (
  input  logic            clk,
  input  logic            rst,
  input  synth_pkg::pcm_t sample_0,
  input  synth_pkg::pcm_t sample_1,
  input  logic [synth_pkg::PHASE_FRAC_WIDTH-1:0] fraction,
  output synth_pkg::pcm_t sample_out
);
  import synth_pkg::*;

  localparam int PRODUCT_WIDTH = 17 + PHASE_FRAC_WIDTH;

  // Implements: sample_0 + ((sample_1 - sample_0) * fraction >> PHASE_FRAC_WIDTH).
  // The fraction is unsigned Q0.PHASE_FRAC_WIDTH, so 0 selects sample_0 and
  // all-ones approaches sample_1 without stepping beyond it.
  logic signed [16:0] difference;
  logic signed [PHASE_FRAC_WIDTH:0] fraction_extended;
  logic signed [PRODUCT_WIDTH-1:0] product;
  logic signed [16:0] scaled_difference;
  synth_pkg::pcm_t sample_0_reg;
  logic signed [17:0] interpolated;

  always_comb begin
    // One extra sign bit is kept for the difference because subtracting two
    // signed 16-bit endpoints can require 17 bits.
    difference = $signed(sample_1) - $signed(sample_0);
    fraction_extended = $signed({1'b0, fraction});
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      product <= '0;
      sample_0_reg <= '0;
    end else begin
      product <= PRODUCT_WIDTH'($signed(difference) * $signed(fraction_extended));
      sample_0_reg <= sample_0;
    end
  end

  always_comb begin
    scaled_difference = product[PHASE_FRAC_WIDTH +: 17];
    interpolated = $signed({{2{sample_0_reg[15]}}, sample_0_reg}) +
                   $signed({scaled_difference[16], scaled_difference});

    // The mathematical interpolation should remain in range for valid PCM
    // endpoints, but saturation keeps the primitive robust at the boundary.
    if (interpolated > 18'sd32767)
      sample_out = 16'sh7fff;
    else if (interpolated < -18'sd32768)
      sample_out = 16'sh8000;
    else
      sample_out = interpolated[15:0];
  end
endmodule
