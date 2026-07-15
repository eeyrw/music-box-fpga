module biquad_filter_datapath (
  input  logic clk,
  input  logic rst,
  input  logic load_x,
  input  logic capture_y,
  input  logic load_y,
  input  synth_pkg::pcm_t sample_l,
  input  synth_pkg::pcm_t sample_r,
  input  logic signed [31:0] coeff_b0,
  input  logic signed [31:0] coeff_b1,
  input  logic signed [31:0] coeff_b2,
  input  logic signed [31:0] coeff_a1,
  input  logic signed [31:0] coeff_a2,
  input  logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] z1_l,
  input  logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] z2_l,
  input  logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] z1_r,
  input  logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] z2_r,
  output synth_pkg::pcm_t filtered_l,
  output synth_pkg::pcm_t filtered_r,
  output logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] next_z1_l,
  output logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] next_z2_l,
  output logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] next_z1_r,
  output logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0] next_z2_r
);
  import synth_pkg::*;

  logic signed [63:0] b0_x_l;
  logic signed [63:0] b1_x_l;
  logic signed [63:0] b2_x_l;
  logic signed [63:0] a1_y_l;
  logic signed [63:0] a2_y_l;
  logic signed [63:0] z1_ext_l;
  logic signed [63:0] z2_ext_l;
  logic signed [63:0] b0_x_r;
  logic signed [63:0] b1_x_r;
  logic signed [63:0] b2_x_r;
  logic signed [63:0] a1_y_r;
  logic signed [63:0] a2_y_r;
  logic signed [63:0] z1_ext_r;
  logic signed [63:0] z2_ext_r;
  logic signed [63:0] y_q28_l;
  logic signed [63:0] y_q28_r;
  logic signed [31:0] y_pcm_ext_l;
  logic signed [31:0] y_pcm_ext_r;
  logic signed [95:0] next_z1_raw_l;
  logic signed [95:0] next_z2_raw_l;
  logic signed [95:0] next_z1_raw_r;
  logic signed [95:0] next_z2_raw_r;

  function automatic logic signed [FILTER_STATE_WIDTH-1:0] saturate_filter_state(input logic signed [95:0] value);
    logic signed [95:0] max_value;
    logic signed [95:0] min_value;
    begin
      max_value = (96'sd1 <<< (FILTER_STATE_WIDTH - 1)) - 96'sd1;
      min_value = -(96'sd1 <<< (FILTER_STATE_WIDTH - 1));
      if (value > max_value)
        saturate_filter_state = {1'b0, {(FILTER_STATE_WIDTH-1){1'b1}}};
      else if (value < min_value)
        saturate_filter_state = {1'b1, {(FILTER_STATE_WIDTH-1){1'b0}}};
      else
        saturate_filter_state = value[FILTER_STATE_WIDTH-1:0];
    end
  endfunction

  function automatic pcm_t saturate_pcm(input logic signed [63:0] value);
    if (value > 64'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -64'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  always_comb begin
    y_q28_l = b0_x_l + z1_ext_l;
    y_q28_r = b0_x_r + z1_ext_r;
    filtered_l = saturate_pcm(y_q28_l >>> 28);
    filtered_r = saturate_pcm(y_q28_r >>> 28);
    next_z1_raw_l = $signed({{32{b1_x_l[63]}}, b1_x_l}) -
                    $signed({{32{a1_y_l[63]}}, a1_y_l}) +
                    $signed({{32{z2_ext_l[63]}}, z2_ext_l});
    next_z2_raw_l = $signed({{32{b2_x_l[63]}}, b2_x_l}) -
                    $signed({{32{a2_y_l[63]}}, a2_y_l});
    next_z1_raw_r = $signed({{32{b1_x_r[63]}}, b1_x_r}) -
                    $signed({{32{a1_y_r[63]}}, a1_y_r}) +
                    $signed({{32{z2_ext_r[63]}}, z2_ext_r});
    next_z2_raw_r = $signed({{32{b2_x_r[63]}}, b2_x_r}) -
                    $signed({{32{a2_y_r[63]}}, a2_y_r});
    next_z1_l = saturate_filter_state(next_z1_raw_l);
    next_z2_l = saturate_filter_state(next_z2_raw_l);
    next_z1_r = saturate_filter_state(next_z1_raw_r);
    next_z2_r = saturate_filter_state(next_z2_raw_r);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      b0_x_l <= '0;
      b1_x_l <= '0;
      b2_x_l <= '0;
      a1_y_l <= '0;
      a2_y_l <= '0;
      z1_ext_l <= '0;
      z2_ext_l <= '0;
      b0_x_r <= '0;
      b1_x_r <= '0;
      b2_x_r <= '0;
      a1_y_r <= '0;
      a2_y_r <= '0;
      z1_ext_r <= '0;
      z2_ext_r <= '0;
      y_pcm_ext_l <= '0;
      y_pcm_ext_r <= '0;
    end else begin
      if (load_x) begin
        b0_x_l <= $signed({{16{sample_l[15]}}, sample_l}) * $signed(coeff_b0);
        b1_x_l <= $signed({{16{sample_l[15]}}, sample_l}) * $signed(coeff_b1);
        b2_x_l <= $signed({{16{sample_l[15]}}, sample_l}) * $signed(coeff_b2);
        z1_ext_l <= {{(64-FILTER_STATE_WIDTH){z1_l[FILTER_STATE_WIDTH-1]}}, z1_l};
        z2_ext_l <= {{(64-FILTER_STATE_WIDTH){z2_l[FILTER_STATE_WIDTH-1]}}, z2_l};
        b0_x_r <= $signed({{16{sample_r[15]}}, sample_r}) * $signed(coeff_b0);
        b1_x_r <= $signed({{16{sample_r[15]}}, sample_r}) * $signed(coeff_b1);
        b2_x_r <= $signed({{16{sample_r[15]}}, sample_r}) * $signed(coeff_b2);
        z1_ext_r <= {{(64-FILTER_STATE_WIDTH){z1_r[FILTER_STATE_WIDTH-1]}}, z1_r};
        z2_ext_r <= {{(64-FILTER_STATE_WIDTH){z2_r[FILTER_STATE_WIDTH-1]}}, z2_r};
      end

      if (capture_y) begin
        y_pcm_ext_l <= {{16{filtered_l[15]}}, filtered_l};
        y_pcm_ext_r <= {{16{filtered_r[15]}}, filtered_r};
      end

      if (load_y) begin
        a1_y_l <= $signed(y_pcm_ext_l) * $signed(coeff_a1);
        a2_y_l <= $signed(y_pcm_ext_l) * $signed(coeff_a2);
        a1_y_r <= $signed(y_pcm_ext_r) * $signed(coeff_a1);
        a2_y_r <= $signed(y_pcm_ext_r) * $signed(coeff_a2);
      end
    end
  end
endmodule
