module block_interleaved_voice_dsp (
  input  logic                                clk,
  input  logic                                rst,

  input  logic                                token_valid,
  output logic                                token_ready,
  input  synth_pkg::block_dsp_sample_token_t token,

  output logic                                state_update_valid,
  output synth_pkg::block_dsp_state_update_t state_update,

  output logic                                retire_valid,
  input  logic                                retire_ready,
  output synth_pkg::block_dsp_retire_t        retire
);
  import synth_pkg::*;

  localparam int INTERP_PRODUCT_WIDTH = 17 + PHASE_FRAC_WIDTH;
  localparam int FILTER_FEEDBACK_PRODUCT_WIDTH =
      FILTER_SAMPLE_WIDTH + FILTER_COEFF_WIDTH;

  typedef struct packed {
    logic [BLOCK_JOB_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_context_t voice_context;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic signed [15:0] envelope_level;
    pcm_t sample_0;
    logic signed [INTERP_PRODUCT_WIDTH-1:0] interp_product;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } stage0_t;

  typedef struct packed {
    logic [BLOCK_JOB_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_context_t voice_context;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic signed [15:0] envelope_level;
    pcm_t x;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } stage1_t;

  typedef struct packed {
    logic [BLOCK_JOB_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_context_t voice_context;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic signed [15:0] envelope_level;
    pcm_t x;
    logic signed [31:0] b0_x;
    logic signed [31:0] b1_x;
    logic signed [31:0] b2_x;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } stage2_t;

  typedef struct packed {
    logic [BLOCK_JOB_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_context_t voice_context;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic signed [15:0] envelope_level;
    pcm_t x;
    logic signed [31:0] b1_x;
    logic signed [31:0] b2_x;
    filter_sample_t y;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } stage3_t;

  typedef struct packed {
    logic [BLOCK_JOB_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_context_t voice_context;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic signed [15:0] envelope_level;
    pcm_t x;
    logic signed [31:0] b1_x;
    logic signed [31:0] b2_x;
    filter_sample_t y;
    logic signed [FILTER_FEEDBACK_PRODUCT_WIDTH-1:0] a1_y;
    logic signed [FILTER_FEEDBACK_PRODUCT_WIDTH-1:0] a2_y;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } stage4_t;

  typedef struct packed {
    logic [BLOCK_JOB_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_context_t voice_context;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic signed [15:0] envelope_level;
    filter_sample_t selected_sample;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } stage5_t;

  typedef struct packed {
    logic [BLOCK_JOB_ID_WIDTH-1:0] work_id;
    logic last;
    logic [VOICE_GENERATION_WIDTH-1:0] generation;
    logic [VOICE_ID_WIDTH-1:0] voice_index;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
    logic signed [15:0] envelope_level;
    logic signed [FILTER_SAMPLE_WIDTH+15:0] gain_product_l;
    logic signed [FILTER_SAMPLE_WIDTH+15:0] gain_product_r;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } stage6_t;

  logic [6:0] valid_q;
  stage0_t s0_q;
  stage1_t s1_q;
  stage2_t s2_q;
  stage3_t s3_q;
  stage4_t s4_q;
  stage5_t s5_q;
  stage6_t s6_q;
  block_dsp_retire_t retire_fifo_q [0:1];
  block_dsp_retire_t retire_next;
  logic [1:0] retire_count_q;
  logic retire_push;
  logic retire_pop;
  logic advance;

  logic signed [16:0] input_difference;
  logic signed [PHASE_FRAC_WIDTH:0] input_fraction;
  logic signed [16:0] interp_scaled_difference;
  logic signed [17:0] interpolated;
  logic signed [FILTER_RAW_WIDTH-1:0] filter_y_raw;
  logic signed [63:0] filter_y_ext;
  logic signed [FILTER_RAW_WIDTH-1:0] next_z1_raw;
  logic signed [FILTER_RAW_WIDTH-1:0] next_z2_raw;
  filter_sample_t next_y;
  logic signed [FILTER_STATE_WIDTH-1:0] next_z1;
  logic signed [FILTER_STATE_WIDTH-1:0] next_z2;

  function automatic pcm_t saturate_pcm(input logic signed [63:0] value);
    if (value > 64'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -64'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  function automatic filter_sample_t saturate_filter_sample(
      input logic signed [63:0] value);
    if (value > 64'sd524287)
      saturate_filter_sample = 20'sh7ffff;
    else if (value < -64'sd524288)
      saturate_filter_sample = 20'sh80000;
    else
      saturate_filter_sample = value[FILTER_SAMPLE_WIDTH-1:0];
  endfunction

  function automatic logic signed [FILTER_STATE_WIDTH-1:0]
      saturate_filter_state(input logic signed [FILTER_RAW_WIDTH-1:0] value);
    logic signed [FILTER_RAW_WIDTH-1:0] max_value;
    logic signed [FILTER_RAW_WIDTH-1:0] min_value;
    begin
      max_value = (FILTER_RAW_WIDTH'(1) <<< (FILTER_STATE_WIDTH - 1)) -
                  FILTER_RAW_WIDTH'(1);
      min_value = -(FILTER_RAW_WIDTH'(1) <<< (FILTER_STATE_WIDTH - 1));
      if (value > max_value)
        saturate_filter_state = {1'b0, {(FILTER_STATE_WIDTH-1){1'b1}}};
      else if (value < min_value)
        saturate_filter_state = {1'b1, {(FILTER_STATE_WIDTH-1){1'b0}}};
      else
        saturate_filter_state = value[FILTER_STATE_WIDTH-1:0];
    end
  endfunction

  function automatic pcm_t finish_output_gain(
      input logic signed [FILTER_SAMPLE_WIDTH+15:0] gain_product,
      input logic signed [15:0] envelope_level);
    logic signed [FILTER_SAMPLE_WIDTH+31:0] envelope_product;
    logic signed [63:0] product;
    logic signed [63:0] scaled;
    begin
      envelope_product = gain_product * envelope_level;
      if (envelope_level == 16'sh7fff) begin
        product = {{(64-(FILTER_SAMPLE_WIDTH+16)){
                   gain_product[FILTER_SAMPLE_WIDTH+15]}}, gain_product};
        scaled = product >>> 15;
      end else begin
        product = {{(64-(FILTER_SAMPLE_WIDTH+32)){
                   envelope_product[FILTER_SAMPLE_WIDTH+31]}},
                   envelope_product};
        scaled = product >>> 30;
      end
      finish_output_gain = saturate_pcm(scaled);
    end
  endfunction

  assign retire_valid = retire_count_q != 0;
  assign retire = retire_fifo_q[0];
  assign retire_pop = retire_valid && retire_ready;

  always_comb begin
    input_difference = $signed(token.sample.sample_1) -
                       $signed(token.sample.sample_0);
    input_fraction = $signed({1'b0, token.sample.job.fraction});
    interp_scaled_difference =
        s0_q.interp_product[PHASE_FRAC_WIDTH +: 17];
    interpolated =
        $signed({{2{s0_q.sample_0[PCM_WIDTH-1]}}, s0_q.sample_0}) +
        $signed({interp_scaled_difference[16], interp_scaled_difference});

    filter_y_raw =
        $signed({{(FILTER_RAW_WIDTH-32){s2_q.b0_x[31]}}, s2_q.b0_x}) +
        $signed({{(FILTER_RAW_WIDTH-FILTER_STATE_WIDTH){
                  s2_q.filter_z1[FILTER_STATE_WIDTH-1]}}, s2_q.filter_z1});
    filter_y_ext = {{(64-FILTER_RAW_WIDTH){
                    filter_y_raw[FILTER_RAW_WIDTH-1]}}, filter_y_raw};
    next_y = saturate_filter_sample(
        filter_y_ext >>> FILTER_COEFF_FRAC_WIDTH);

    next_z1_raw =
        $signed({{(FILTER_RAW_WIDTH-32){s4_q.b1_x[31]}}, s4_q.b1_x}) -
        $signed({{(FILTER_RAW_WIDTH-FILTER_FEEDBACK_PRODUCT_WIDTH){
                  s4_q.a1_y[FILTER_FEEDBACK_PRODUCT_WIDTH-1]}}, s4_q.a1_y}) +
        $signed({{(FILTER_RAW_WIDTH-FILTER_STATE_WIDTH){
                  s4_q.filter_z2[FILTER_STATE_WIDTH-1]}}, s4_q.filter_z2});
    next_z2_raw =
        $signed({{(FILTER_RAW_WIDTH-32){s4_q.b2_x[31]}}, s4_q.b2_x}) -
        $signed({{(FILTER_RAW_WIDTH-FILTER_FEEDBACK_PRODUCT_WIDTH){
                  s4_q.a2_y[FILTER_FEEDBACK_PRODUCT_WIDTH-1]}}, s4_q.a2_y});
    next_z1 = s4_q.voice_context.filter_enable ?
        saturate_filter_state(next_z1_raw) : s4_q.filter_z1;
    next_z2 = s4_q.voice_context.filter_enable ?
        saturate_filter_state(next_z2_raw) : s4_q.filter_z2;

    retire_next = '0;
    retire_next.work_id = s6_q.work_id;
    retire_next.last = s6_q.last;
    retire_next.contribution.generation = s6_q.generation;
    retire_next.contribution.voice_index = s6_q.voice_index;
    retire_next.contribution.block_frame_index = s6_q.frame_index;
    retire_next.contribution.contribution_l = finish_output_gain(
        s6_q.gain_product_l, s6_q.envelope_level);
    retire_next.contribution.contribution_r = finish_output_gain(
        s6_q.gain_product_r, s6_q.envelope_level);
    retire_next.filter_z1 = s6_q.filter_z1;
    retire_next.filter_z2 = s6_q.filter_z2;

    advance = retire_count_q != 2;
    token_ready = advance;
    state_update_valid = advance && valid_q[4];
    state_update.work_id = s4_q.work_id;
    state_update.filter_z1 = next_z1;
    state_update.filter_z2 = next_z2;
    retire_push = advance && valid_q[6];
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      valid_q <= '0;
      retire_count_q <= '0;
    end else begin
      unique case ({retire_push, retire_pop})
        2'b10: begin
          if (retire_count_q == 0)
            retire_fifo_q[0] <= retire_next;
          else
            retire_fifo_q[1] <= retire_next;
          retire_count_q <= retire_count_q + 1'b1;
        end
        2'b01: begin
          if (retire_count_q == 2)
            retire_fifo_q[0] <= retire_fifo_q[1];
          retire_count_q <= retire_count_q - 1'b1;
        end
        2'b11: begin
          retire_fifo_q[0] <= retire_next;
          retire_count_q <= retire_count_q;
        end
        default: retire_count_q <= retire_count_q;
      endcase

      if (advance) begin
        valid_q[6:1] <= valid_q[5:0];
        valid_q[0] <= token_valid && token_ready;

      if (valid_q[5]) begin
        s6_q.work_id <= s5_q.work_id;
        s6_q.last <= s5_q.last;
        s6_q.generation <= s5_q.voice_context.generation;
        s6_q.voice_index <= s5_q.voice_context.voice_index;
        s6_q.frame_index <= s5_q.frame_index;
        s6_q.envelope_level <= s5_q.envelope_level;
        s6_q.gain_product_l <=
            $signed(s5_q.selected_sample) * $signed(s5_q.voice_context.gain_l);
        s6_q.gain_product_r <=
            $signed(s5_q.selected_sample) * $signed(s5_q.voice_context.gain_r);
        s6_q.filter_z1 <= s5_q.filter_z1;
        s6_q.filter_z2 <= s5_q.filter_z2;
      end

      if (valid_q[4]) begin
        s5_q.work_id <= s4_q.work_id;
        s5_q.last <= s4_q.last;
        s5_q.voice_context <= s4_q.voice_context;
        s5_q.frame_index <= s4_q.frame_index;
        s5_q.envelope_level <= s4_q.envelope_level;
        s5_q.selected_sample <= s4_q.voice_context.filter_enable ?
            s4_q.y : {{(FILTER_SAMPLE_WIDTH-PCM_WIDTH){s4_q.x[PCM_WIDTH-1]}},
                       s4_q.x};
        s5_q.filter_z1 <= next_z1;
        s5_q.filter_z2 <= next_z2;
      end

      if (valid_q[3]) begin
        s4_q.work_id <= s3_q.work_id;
        s4_q.last <= s3_q.last;
        s4_q.voice_context <= s3_q.voice_context;
        s4_q.frame_index <= s3_q.frame_index;
        s4_q.envelope_level <= s3_q.envelope_level;
        s4_q.x <= s3_q.x;
        s4_q.b1_x <= s3_q.b1_x;
        s4_q.b2_x <= s3_q.b2_x;
        s4_q.y <= s3_q.y;
        s4_q.a1_y <= $signed(s3_q.y) *
                     $signed(s3_q.voice_context.filter_a1);
        s4_q.a2_y <= $signed(s3_q.y) *
                     $signed(s3_q.voice_context.filter_a2);
        s4_q.filter_z1 <= s3_q.filter_z1;
        s4_q.filter_z2 <= s3_q.filter_z2;
      end

      if (valid_q[2]) begin
        s3_q.work_id <= s2_q.work_id;
        s3_q.last <= s2_q.last;
        s3_q.voice_context <= s2_q.voice_context;
        s3_q.frame_index <= s2_q.frame_index;
        s3_q.envelope_level <= s2_q.envelope_level;
        s3_q.x <= s2_q.x;
        s3_q.b1_x <= s2_q.b1_x;
        s3_q.b2_x <= s2_q.b2_x;
        s3_q.y <= next_y;
        s3_q.filter_z1 <= s2_q.filter_z1;
        s3_q.filter_z2 <= s2_q.filter_z2;
      end

      if (valid_q[1]) begin
        s2_q.work_id <= s1_q.work_id;
        s2_q.last <= s1_q.last;
        s2_q.voice_context <= s1_q.voice_context;
        s2_q.frame_index <= s1_q.frame_index;
        s2_q.envelope_level <= s1_q.envelope_level;
        s2_q.x <= s1_q.x;
        s2_q.b0_x <= $signed(s1_q.x) *
                     $signed(s1_q.voice_context.filter_b0);
        s2_q.b1_x <= $signed(s1_q.x) *
                     $signed(s1_q.voice_context.filter_b1);
        s2_q.b2_x <= $signed(s1_q.x) *
                     $signed(s1_q.voice_context.filter_b2);
        s2_q.filter_z1 <= s1_q.filter_z1;
        s2_q.filter_z2 <= s1_q.filter_z2;
      end

      if (valid_q[0]) begin
        s1_q.work_id <= s0_q.work_id;
        s1_q.last <= s0_q.last;
        s1_q.voice_context <= s0_q.voice_context;
        s1_q.frame_index <= s0_q.frame_index;
        s1_q.envelope_level <= s0_q.envelope_level;
        s1_q.x <= interpolated[PCM_WIDTH-1:0];
        s1_q.filter_z1 <= s0_q.filter_z1;
        s1_q.filter_z2 <= s0_q.filter_z2;
      end

      if (token_valid && token_ready) begin
        s0_q.work_id <= token.work_id;
        s0_q.last <= token.last;
        s0_q.voice_context <= token.voice_context;
        s0_q.frame_index <= token.sample.job.block_frame_index;
        s0_q.envelope_level <= token.sample.job.envelope_level;
        s0_q.sample_0 <= token.sample.sample_0;
        s0_q.interp_product <= INTERP_PRODUCT_WIDTH'(
            $signed(input_difference) * $signed(input_fraction));
        s0_q.filter_z1 <= token.filter_z1;
        s0_q.filter_z2 <= token.filter_z2;
      end
      end
    end
  end
endmodule
