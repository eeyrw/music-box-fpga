module voice_dsp_pipeline (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         valid_i,
  input  synth_pkg::voice_dsp_context_t context_i,
  output logic                         valid_o,
  output synth_pkg::voice_dsp_result_t  result_o
);
  import synth_pkg::*;

  typedef struct packed {
    logic [VOICE_ID_WIDTH-1:0] voice_index;
    logic                     filter_enable;
    logic signed [15:0]       gain_l;
    logic signed [15:0]       gain_r;
    logic signed [15:0]       envelope_level;
  } dsp_base_context_t;

  typedef struct packed {
    dsp_base_context_t base;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b0;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b2;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_l;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_l;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_r;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_r;
    pcm_t x_l;
    pcm_t x_r;
  } interp_stage_t;

  typedef struct packed {
    dsp_base_context_t base;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
    pcm_t x_l;
    pcm_t x_r;
    logic signed [31:0] b0_x_l;
    logic signed [31:0] b1_x_l;
    logic signed [31:0] b2_x_l;
    logic signed [FILTER_RAW_WIDTH-1:0] z1_ext_l;
    logic signed [FILTER_RAW_WIDTH-1:0] z2_ext_l;
    logic signed [31:0] b0_x_r;
    logic signed [31:0] b1_x_r;
    logic signed [31:0] b2_x_r;
    logic signed [FILTER_RAW_WIDTH-1:0] z1_ext_r;
    logic signed [FILTER_RAW_WIDTH-1:0] z2_ext_r;
  } filter_x_stage_t;

  typedef struct packed {
    dsp_base_context_t base;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
    pcm_t x_l;
    pcm_t x_r;
    filter_sample_t y_l;
    filter_sample_t y_r;
    logic signed [31:0] b1_x_l;
    logic signed [31:0] b2_x_l;
    logic signed [FILTER_RAW_WIDTH-1:0] z2_ext_l;
    logic signed [31:0] b1_x_r;
    logic signed [31:0] b2_x_r;
    logic signed [FILTER_RAW_WIDTH-1:0] z2_ext_r;
  } filter_y_stage_t;

  typedef struct packed {
    dsp_base_context_t base;
    filter_sample_t selected_l;
    filter_sample_t selected_r;
    logic signed [FILTER_RAW_WIDTH-1:0] next_z1_raw_l;
    logic signed [FILTER_RAW_WIDTH-1:0] next_z2_raw_l;
    logic signed [FILTER_RAW_WIDTH-1:0] next_z1_raw_r;
    logic signed [FILTER_RAW_WIDTH-1:0] next_z2_raw_r;
  } filter_state_stage_t;

  typedef struct packed {
    dsp_base_context_t base;
    filter_sample_t selected_l;
    filter_sample_t selected_r;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z1_l;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z2_l;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z1_r;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z2_r;
  } gain_stage_t;

  logic [6:0] valid_pipe;
  pcm_t interp_l_out, interp_r_out;
  voice_dsp_context_t s0_context;
  interp_stage_t s0_interp;
  filter_x_stage_t s1_filter_x;
  filter_y_stage_t s2_filter_y;
  filter_state_stage_t s3_filter_state;
  gain_stage_t s4_gain;
  logic signed [FILTER_RAW_WIDTH-1:0] y_q_l, y_q_r;
  logic signed [63:0] y_q_l_ext, y_q_r_ext;
  logic signed [FILTER_SAMPLE_WIDTH-1:0] y_filter_l, y_filter_r;
  logic signed [FILTER_SAMPLE_WIDTH+FILTER_COEFF_WIDTH-1:0] a1_y_l, a2_y_l, a1_y_r, a2_y_r;
  logic signed [FILTER_RAW_WIDTH-1:0] next_z1_raw_l, next_z2_raw_l, next_z1_raw_r, next_z2_raw_r;
  localparam int FILTER_FEEDBACK_PRODUCT_WIDTH = FILTER_SAMPLE_WIDTH + FILTER_COEFF_WIDTH;

  function automatic pcm_t saturate_pcm(input logic signed [63:0] value);
    if (value > 64'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -64'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  function automatic filter_sample_t saturate_filter_sample(input logic signed [63:0] value);
    if (value > 64'sd524287)
      saturate_filter_sample = 20'sh7ffff;
    else if (value < -64'sd524288)
      saturate_filter_sample = 20'sh80000;
    else
      saturate_filter_sample = value[FILTER_SAMPLE_WIDTH-1:0];
  endfunction

  function automatic logic signed [FILTER_STATE_WIDTH-1:0] saturate_filter_state(input logic signed [FILTER_RAW_WIDTH-1:0] value);
    logic signed [FILTER_RAW_WIDTH-1:0] max_value;
    logic signed [FILTER_RAW_WIDTH-1:0] min_value;
    begin
      max_value = (FILTER_RAW_WIDTH'(1) <<< (FILTER_STATE_WIDTH - 1)) - FILTER_RAW_WIDTH'(1);
      min_value = -(FILTER_RAW_WIDTH'(1) <<< (FILTER_STATE_WIDTH - 1));
      if (value > max_value)
        saturate_filter_state = {1'b0, {(FILTER_STATE_WIDTH-1){1'b1}}};
      else if (value < min_value)
        saturate_filter_state = {1'b1, {(FILTER_STATE_WIDTH-1){1'b0}}};
      else
        saturate_filter_state = value[FILTER_STATE_WIDTH-1:0];
    end
  endfunction

  function automatic pcm_t apply_output_gain(
    input filter_sample_t sample,
    input logic signed [15:0] gain,
    input logic signed [15:0] envelope_level
  );
    logic signed [63:0] sample_ext;
    logic signed [63:0] gain_ext;
    logic signed [63:0] envelope_ext;
    logic signed [63:0] product;
    logic signed [63:0] scaled;
    begin
      sample_ext = {{(64-FILTER_SAMPLE_WIDTH){sample[FILTER_SAMPLE_WIDTH-1]}}, sample};
      gain_ext = {{48{gain[15]}}, gain};
      envelope_ext = {{48{envelope_level[15]}}, envelope_level};
      if (envelope_level == 16'sh7fff) begin
        product = sample_ext * gain_ext;
        scaled = product >>> 15;
      end else begin
        product = sample_ext * gain_ext * envelope_ext;
        scaled = product >>> 30;
      end
      apply_output_gain = saturate_pcm(scaled);
    end
  endfunction

  linear_interpolator interp_l (
    .clk(clk),
    .rst(rst),
    .sample_0(s0_context.raw_l0),
    .sample_1(s0_context.raw_l1),
    .fraction(s0_context.fraction),
    .sample_out(interp_l_out)
  );

  linear_interpolator interp_r (
    .clk(clk),
    .rst(rst),
    .sample_0(s0_context.raw_r0),
    .sample_1(s0_context.raw_r1),
    .fraction(s0_context.fraction),
    .sample_out(interp_r_out)
  );

  always_comb begin
    y_q_l = $signed({{(FILTER_RAW_WIDTH-32){s1_filter_x.b0_x_l[31]}}, s1_filter_x.b0_x_l}) + s1_filter_x.z1_ext_l;
    y_q_r = $signed({{(FILTER_RAW_WIDTH-32){s1_filter_x.b0_x_r[31]}}, s1_filter_x.b0_x_r}) + s1_filter_x.z1_ext_r;
    y_q_l_ext = {{(64-FILTER_RAW_WIDTH){y_q_l[FILTER_RAW_WIDTH-1]}}, y_q_l};
    y_q_r_ext = {{(64-FILTER_RAW_WIDTH){y_q_r[FILTER_RAW_WIDTH-1]}}, y_q_r};
    y_filter_l = s2_filter_y.y_l;
    y_filter_r = s2_filter_y.y_r;
    a1_y_l = $signed(y_filter_l) * $signed(s2_filter_y.filter_a1);
    a2_y_l = $signed(y_filter_l) * $signed(s2_filter_y.filter_a2);
    a1_y_r = $signed(y_filter_r) * $signed(s2_filter_y.filter_a1);
    a2_y_r = $signed(y_filter_r) * $signed(s2_filter_y.filter_a2);
    next_z1_raw_l = $signed({{(FILTER_RAW_WIDTH-32){s2_filter_y.b1_x_l[31]}}, s2_filter_y.b1_x_l}) -
                    $signed({{(FILTER_RAW_WIDTH-FILTER_FEEDBACK_PRODUCT_WIDTH){a1_y_l[FILTER_FEEDBACK_PRODUCT_WIDTH-1]}}, a1_y_l}) +
                    s2_filter_y.z2_ext_l;
    next_z2_raw_l = $signed({{(FILTER_RAW_WIDTH-32){s2_filter_y.b2_x_l[31]}}, s2_filter_y.b2_x_l}) -
                    $signed({{(FILTER_RAW_WIDTH-FILTER_FEEDBACK_PRODUCT_WIDTH){a2_y_l[FILTER_FEEDBACK_PRODUCT_WIDTH-1]}}, a2_y_l});
    next_z1_raw_r = $signed({{(FILTER_RAW_WIDTH-32){s2_filter_y.b1_x_r[31]}}, s2_filter_y.b1_x_r}) -
                    $signed({{(FILTER_RAW_WIDTH-FILTER_FEEDBACK_PRODUCT_WIDTH){a1_y_r[FILTER_FEEDBACK_PRODUCT_WIDTH-1]}}, a1_y_r}) +
                    s2_filter_y.z2_ext_r;
    next_z2_raw_r = $signed({{(FILTER_RAW_WIDTH-32){s2_filter_y.b2_x_r[31]}}, s2_filter_y.b2_x_r}) -
                    $signed({{(FILTER_RAW_WIDTH-FILTER_FEEDBACK_PRODUCT_WIDTH){a2_y_r[FILTER_FEEDBACK_PRODUCT_WIDTH-1]}}, a2_y_r});
  end

  assign valid_o = valid_pipe[6];
  assign result_o.voice_index = s4_gain.base.voice_index;
  assign result_o.filter_enable = s4_gain.base.filter_enable;
  assign result_o.next_z1_l = s4_gain.next_z1_l;
  assign result_o.next_z2_l = s4_gain.next_z2_l;
  assign result_o.next_z1_r = s4_gain.next_z1_r;
  assign result_o.next_z2_r = s4_gain.next_z2_r;
  assign result_o.contribution_l = apply_output_gain(s4_gain.selected_l, s4_gain.base.gain_l,
                                                     s4_gain.base.envelope_level);
  assign result_o.contribution_r = apply_output_gain(s4_gain.selected_r, s4_gain.base.gain_r,
                                                     s4_gain.base.envelope_level);

  always_ff @(posedge clk) begin
    if (rst) begin
      valid_pipe <= '0;
      s0_context <= '0;
      s0_interp <= '0;
      s1_filter_x <= '0;
      s2_filter_y <= '0;
      s3_filter_state <= '0;
      s4_gain <= '0;
    end else begin
      valid_pipe <= {valid_pipe[5:0], valid_i};

      if (valid_i) begin
        s0_context <= context_i;
      end

      if (valid_pipe[1]) begin
        s0_interp.base.voice_index <= s0_context.voice_index;
        s0_interp.base.filter_enable <= s0_context.filter_enable;
        s0_interp.base.gain_l <= s0_context.gain_l;
        s0_interp.base.gain_r <= s0_context.gain_r;
        s0_interp.base.envelope_level <= s0_context.envelope_level;
        s0_interp.filter_b0 <= s0_context.filter_b0;
        s0_interp.filter_b1 <= s0_context.filter_b1;
        s0_interp.filter_b2 <= s0_context.filter_b2;
        s0_interp.filter_a1 <= s0_context.filter_a1;
        s0_interp.filter_a2 <= s0_context.filter_a2;
        s0_interp.filter_z1_l <= s0_context.filter_z1_l;
        s0_interp.filter_z2_l <= s0_context.filter_z2_l;
        s0_interp.filter_z1_r <= s0_context.filter_z1_r;
        s0_interp.filter_z2_r <= s0_context.filter_z2_r;
        s0_interp.x_l <= interp_l_out;
        s0_interp.x_r <= interp_r_out;
      end

      if (valid_pipe[2]) begin
        s1_filter_x.base <= s0_interp.base;
        s1_filter_x.filter_a1 <= s0_interp.filter_a1;
        s1_filter_x.filter_a2 <= s0_interp.filter_a2;
        s1_filter_x.x_l <= s0_interp.x_l;
        s1_filter_x.x_r <= s0_interp.x_r;
        s1_filter_x.b0_x_l <= $signed(s0_interp.x_l) * $signed(s0_interp.filter_b0);
        s1_filter_x.b1_x_l <= $signed(s0_interp.x_l) * $signed(s0_interp.filter_b1);
        s1_filter_x.b2_x_l <= $signed(s0_interp.x_l) * $signed(s0_interp.filter_b2);
        s1_filter_x.z1_ext_l <= {{(FILTER_RAW_WIDTH-FILTER_STATE_WIDTH){s0_interp.filter_z1_l[FILTER_STATE_WIDTH-1]}}, s0_interp.filter_z1_l};
        s1_filter_x.z2_ext_l <= {{(FILTER_RAW_WIDTH-FILTER_STATE_WIDTH){s0_interp.filter_z2_l[FILTER_STATE_WIDTH-1]}}, s0_interp.filter_z2_l};
        s1_filter_x.b0_x_r <= $signed(s0_interp.x_r) * $signed(s0_interp.filter_b0);
        s1_filter_x.b1_x_r <= $signed(s0_interp.x_r) * $signed(s0_interp.filter_b1);
        s1_filter_x.b2_x_r <= $signed(s0_interp.x_r) * $signed(s0_interp.filter_b2);
        s1_filter_x.z1_ext_r <= {{(FILTER_RAW_WIDTH-FILTER_STATE_WIDTH){s0_interp.filter_z1_r[FILTER_STATE_WIDTH-1]}}, s0_interp.filter_z1_r};
        s1_filter_x.z2_ext_r <= {{(FILTER_RAW_WIDTH-FILTER_STATE_WIDTH){s0_interp.filter_z2_r[FILTER_STATE_WIDTH-1]}}, s0_interp.filter_z2_r};
      end

      if (valid_pipe[3]) begin
        s2_filter_y.base <= s1_filter_x.base;
        s2_filter_y.filter_a1 <= s1_filter_x.filter_a1;
        s2_filter_y.filter_a2 <= s1_filter_x.filter_a2;
        s2_filter_y.x_l <= s1_filter_x.x_l;
        s2_filter_y.x_r <= s1_filter_x.x_r;
        s2_filter_y.y_l <= saturate_filter_sample(y_q_l_ext >>> FILTER_COEFF_FRAC_WIDTH);
        s2_filter_y.y_r <= saturate_filter_sample(y_q_r_ext >>> FILTER_COEFF_FRAC_WIDTH);
        s2_filter_y.b1_x_l <= s1_filter_x.b1_x_l;
        s2_filter_y.b2_x_l <= s1_filter_x.b2_x_l;
        s2_filter_y.z2_ext_l <= s1_filter_x.z2_ext_l;
        s2_filter_y.b1_x_r <= s1_filter_x.b1_x_r;
        s2_filter_y.b2_x_r <= s1_filter_x.b2_x_r;
        s2_filter_y.z2_ext_r <= s1_filter_x.z2_ext_r;
      end

      if (valid_pipe[4]) begin
        s3_filter_state.base <= s2_filter_y.base;
        s3_filter_state.selected_l <= s2_filter_y.base.filter_enable ? s2_filter_y.y_l :
                                      {{(FILTER_SAMPLE_WIDTH-PCM_WIDTH){s2_filter_y.x_l[PCM_WIDTH-1]}}, s2_filter_y.x_l};
        s3_filter_state.selected_r <= s2_filter_y.base.filter_enable ? s2_filter_y.y_r :
                                      {{(FILTER_SAMPLE_WIDTH-PCM_WIDTH){s2_filter_y.x_r[PCM_WIDTH-1]}}, s2_filter_y.x_r};
        s3_filter_state.next_z1_raw_l <= next_z1_raw_l;
        s3_filter_state.next_z2_raw_l <= next_z2_raw_l;
        s3_filter_state.next_z1_raw_r <= next_z1_raw_r;
        s3_filter_state.next_z2_raw_r <= next_z2_raw_r;
      end

      if (valid_pipe[5]) begin
        s4_gain.base <= s3_filter_state.base;
        s4_gain.selected_l <= s3_filter_state.selected_l;
        s4_gain.selected_r <= s3_filter_state.selected_r;
        s4_gain.next_z1_l <= saturate_filter_state(s3_filter_state.next_z1_raw_l);
        s4_gain.next_z2_l <= saturate_filter_state(s3_filter_state.next_z2_raw_l);
        s4_gain.next_z1_r <= saturate_filter_state(s3_filter_state.next_z1_raw_r);
        s4_gain.next_z2_r <= saturate_filter_state(s3_filter_state.next_z2_raw_r);
      end
    end
  end
endmodule
