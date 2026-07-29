module stereo_chorus #(
  parameter int DELAY_CAPACITY = 2048
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       clear_i,
  input  synth_pkg::chorus_config_t  config_i,
  input  logic                       in_valid,
  output logic                       in_ready,
  input  synth_pkg::mix_t            in_l,
  input  synth_pkg::mix_t            in_r,
  output logic                       out_valid,
  input  logic                       out_ready,
  output synth_pkg::mix_t            out_l,
  output synth_pkg::mix_t            out_r,
  output logic                       busy,
  output logic                       config_clamped,
  output logic [15:0]                history_level_frames,
  output logic [31:0]                lfo_phase_q0_32,
  output logic [31:0]                saturation_count
);
  import synth_pkg::*;
  import synth_dsp_lut_pkg::*;

  localparam int PTR_WIDTH = $clog2(DELAY_CAPACITY);
  localparam int AGE_WIDTH = $clog2(DELAY_CAPACITY + 1);
  localparam logic signed [15:0] FEEDBACK_MAX_Q1_15 = 16'sh6000;
  localparam logic signed [15:0] FEEDBACK_MIN_Q1_15 = -16'sh6000;
  localparam logic [23:0] MIN_DELAY_Q16_8 = 24'd256;
  localparam logic [23:0] MAX_DELAY_Q16_8 = 24'((DELAY_CAPACITY - 2) << 8);

  typedef enum logic [3:0] {
    IDLE, PREP_BASE, PREP_CONFIG, CALC_LFO, CALC_DELAY, PREPARE_READ, READ_L0,
    READ_L1, READ_R0, READ_R1, INTERPOLATE, INTERPOLATE_SUM, CALCULATE, COMMIT,
    HOLD
  } state_t;

  state_t state;
  (* ram_style = "block" *) mix_t history_l [0:DELAY_CAPACITY-1];
  (* ram_style = "block" *) mix_t history_r [0:DELAY_CAPACITY-1];
  logic [PTR_WIDTH-1:0] write_ptr;
  logic [AGE_WIDTH-1:0] history_age;
  logic [31:0] lfo_phase;
  logic config_enable_q;
  // return_gain_q1_15 belongs to the downstream effect-return mixer.
  /* verilator lint_off UNUSEDSIGNAL */
  chorus_config_t pending_config_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [23:0] config_base_delay_q;
  logic [23:0] config_depth_q;
  logic [31:0] config_stereo_phase_offset_q;
  logic [31:0] config_lfo_phase_inc_q;
  logic [15:0] config_input_send_q;
  logic signed [15:0] config_feedback_q;
  stereo_mix_t input_q;
  mix_t sample_l0;
  mix_t sample_l1;
  mix_t sample_r0;
  mix_t sample_r1;
  mix_t wet_l_q;
  mix_t wet_r_q;
  mix_t write_l_q;
  mix_t write_r_q;
  logic write_saturated_l_q;
  logic write_saturated_r_q;
  logic [7:0] fraction_l_q;
  logic [7:0] fraction_r_q;
  logic [23:0] delay_l_q;
  logic [23:0] delay_r_q;
  logic [PTR_WIDTH-1:0] address_l0_q;
  logic [PTR_WIDTH-1:0] address_l1_q;
  logic [PTR_WIDTH-1:0] address_r0_q;
  logic [PTR_WIDTH-1:0] address_r1_q;
  logic valid_l0_q;
  logic valid_l1_q;
  logic valid_r0_q;
  logic valid_r1_q;

  logic [23:0] clamped_base_delay;
  logic base_delay_clamped;
  logic [23:0] depth_limit;
  logic [23:0] clamped_depth;
  logic depth_clamped;
  logic signed [15:0] clamped_feedback;
  logic feedback_clamped;
  logic [15:0] clamped_input_send;
  logic input_send_clamped;
  logic signed [15:0] sine_l;
  logic signed [15:0] sine_r;
  logic signed [15:0] sine_l_q;
  logic signed [15:0] sine_r_q;
  logic signed [40:0] modulation_product_l;
  logic signed [40:0] modulation_product_r;
  logic [23:0] delay_l;
  logic [23:0] delay_r;
  logic [15:0] integer_delay_l;
  logic [15:0] integer_delay_r;
  mix_t tap_l0;
  mix_t tap_l1;
  mix_t tap_r0;
  mix_t tap_r1;
  logic signed [25:0] delta_l;
  logic signed [25:0] delta_r;
  logic signed [34:0] interpolation_product_l;
  logic signed [34:0] interpolation_product_r;
  logic signed [34:0] interpolation_product_l_q;
  logic signed [34:0] interpolation_product_r_q;
  mix_t wet_l;
  mix_t wet_r;
  logic signed [41:0] input_product_l;
  logic signed [41:0] input_product_r;
  logic signed [40:0] feedback_product_l;
  logic signed [40:0] feedback_product_r;
  logic signed [42:0] write_wide_l;
  logic signed [42:0] write_wide_r;
  mix_t write_l;
  mix_t write_r;
  logic write_saturated_l;
  logic write_saturated_r;

  initial begin
    if (DELAY_CAPACITY < 4 || (DELAY_CAPACITY & (DELAY_CAPACITY - 1)) != 0)
      $error("DELAY_CAPACITY must be a power of two and at least four");
  end

  // The 1024-entry reconstructed table intentionally ignores sub-index phase bits.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic signed [15:0] sine_q1_15(input logic [31:0] phase);
    logic [9:0] position;
    logic [1:0] quadrant;
    logic [7:0] offset;
    logic [8:0] index;
    logic signed [15:0] magnitude;
    begin
      position = phase[31:22];
      quadrant = position[9:8];
      offset = position[7:0];
      index = quadrant[0] ? 9'd256 - {1'b0, offset} : {1'b0, offset};
      magnitude = $signed(CHORUS_SINE_QUARTER_Q1_15_LUT[index]);
      sine_q1_15 = quadrant[1] ? -magnitude : magnitude;
    end
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic mix_t saturate_mix(input logic signed [42:0] value);
    if (value > 43'sd16777215)
      saturate_mix = 25'sh0ffffff;
    else if (value < -43'sd16777216)
      saturate_mix = 25'sh1000000;
    else
      saturate_mix = mix_t'(value);
  endfunction

  function automatic logic [31:0] sat_add(
    input logic [31:0] value,
    input logic [1:0] amount
  );
    if ((amount == 2'd2 && value >= 32'hffff_fffe) ||
        (amount == 2'd1 && value == 32'hffff_ffff))
      sat_add = 32'hffff_ffff;
    else
      sat_add = value + 32'(amount);
  endfunction

  assign in_ready = (state == IDLE) && !out_valid;
  assign busy = state != IDLE;
  assign history_level_frames = 16'(history_age);
  assign lfo_phase_q0_32 = lfo_phase;

  always_comb begin
    clamped_base_delay = pending_config_q.base_delay_q16_8;
    base_delay_clamped = 1'b0;
    if (pending_config_q.base_delay_q16_8 < MIN_DELAY_Q16_8) begin
      clamped_base_delay = MIN_DELAY_Q16_8;
      base_delay_clamped = 1'b1;
    end else if (pending_config_q.base_delay_q16_8 > MAX_DELAY_Q16_8) begin
      clamped_base_delay = MAX_DELAY_Q16_8;
      base_delay_clamped = 1'b1;
    end

    depth_limit = config_base_delay_q - MIN_DELAY_Q16_8;
    if ((MAX_DELAY_Q16_8 - config_base_delay_q) < depth_limit)
      depth_limit = MAX_DELAY_Q16_8 - config_base_delay_q;
    clamped_depth = pending_config_q.depth_q16_8;
    depth_clamped = 1'b0;
    if (pending_config_q.depth_q16_8 > depth_limit) begin
      clamped_depth = depth_limit;
      depth_clamped = 1'b1;
    end

    clamped_feedback = $signed(pending_config_q.feedback_q1_15);
    feedback_clamped = 1'b0;
    if ($signed(pending_config_q.feedback_q1_15) > FEEDBACK_MAX_Q1_15) begin
      clamped_feedback = FEEDBACK_MAX_Q1_15;
      feedback_clamped = 1'b1;
    end else if ($signed(pending_config_q.feedback_q1_15) < FEEDBACK_MIN_Q1_15) begin
      clamped_feedback = FEEDBACK_MIN_Q1_15;
      feedback_clamped = 1'b1;
    end

    clamped_input_send = pending_config_q.input_send_q1_15;
    input_send_clamped = 1'b0;
    if (pending_config_q.input_send_q1_15 > 16'h7fff) begin
      clamped_input_send = 16'h7fff;
      input_send_clamped = 1'b1;
    end

    sine_l = sine_q1_15(lfo_phase);
    sine_r = sine_q1_15(lfo_phase + config_stereo_phase_offset_q);
    modulation_product_l = $signed({1'b0, config_depth_q}) * sine_l_q;
    modulation_product_r = $signed({1'b0, config_depth_q}) * sine_r_q;
    delay_l = 24'($signed({17'd0, config_base_delay_q}) +
                  (modulation_product_l >>> 15));
    delay_r = 24'($signed({17'd0, config_base_delay_q}) +
                  (modulation_product_r >>> 15));
    integer_delay_l = delay_l_q[23:8];
    integer_delay_r = delay_r_q[23:8];

    tap_l0 = valid_l0_q ? sample_l0 : '0;
    tap_l1 = valid_l1_q ? sample_l1 : '0;
    tap_r0 = valid_r0_q ? sample_r0 : '0;
    tap_r1 = valid_r1_q ? sample_r1 : '0;
    delta_l = $signed(tap_l1) - $signed(tap_l0);
    delta_r = $signed(tap_r1) - $signed(tap_r0);
    interpolation_product_l = delta_l * $signed({1'b0, fraction_l_q});
    interpolation_product_r = delta_r * $signed({1'b0, fraction_r_q});
    wet_l = mix_t'($signed({{10{tap_l0[MIX_WIDTH-1]}}, tap_l0}) +
                     ($signed(interpolation_product_l_q) >>> 8));
    wet_r = mix_t'($signed({{10{tap_r0[MIX_WIDTH-1]}}, tap_r0}) +
                     ($signed(interpolation_product_r_q) >>> 8));

    input_product_l = input_q.l * $signed({1'b0, config_input_send_q});
    input_product_r = input_q.r * $signed({1'b0, config_input_send_q});
    feedback_product_l = wet_l_q * config_feedback_q;
    feedback_product_r = wet_r_q * config_feedback_q;
    if (config_input_send_q == 16'h7fff) begin
      write_wide_l = $signed({{18{input_q.l[MIX_WIDTH-1]}}, input_q.l}) +
                     ($signed({{2{feedback_product_l[40]}}, feedback_product_l}) >>> 15);
      write_wide_r = $signed({{18{input_q.r[MIX_WIDTH-1]}}, input_q.r}) +
                     ($signed({{2{feedback_product_r[40]}}, feedback_product_r}) >>> 15);
    end else begin
      write_wide_l = ($signed({input_product_l[41], input_product_l}) >>> 15) +
                     ($signed({{2{feedback_product_l[40]}}, feedback_product_l}) >>> 15);
      write_wide_r = ($signed({input_product_r[41], input_product_r}) >>> 15) +
                     ($signed({{2{feedback_product_r[40]}}, feedback_product_r}) >>> 15);
    end
    write_l = saturate_mix(write_wide_l);
    write_r = saturate_mix(write_wide_r);
    write_saturated_l = (write_wide_l > 43'sd16777215) ||
                        (write_wide_l < -43'sd16777216);
    write_saturated_r = (write_wide_r > 43'sd16777215) ||
                        (write_wide_r < -43'sd16777216);
  end

  always_ff @(posedge clk) begin
    if (rst || clear_i) begin
      state <= IDLE;
      write_ptr <= '0;
      history_age <= '0;
      pending_config_q <= '0;
      config_enable_q <= 1'b0;
      config_base_delay_q <= '0;
      config_depth_q <= '0;
      config_stereo_phase_offset_q <= '0;
      config_lfo_phase_inc_q <= '0;
      config_input_send_q <= '0;
      config_feedback_q <= '0;
      input_q <= '0;
      sample_l0 <= '0;
      sample_l1 <= '0;
      sample_r0 <= '0;
      sample_r1 <= '0;
      wet_l_q <= '0;
      wet_r_q <= '0;
      interpolation_product_l_q <= '0;
      interpolation_product_r_q <= '0;
      write_l_q <= '0;
      write_r_q <= '0;
      write_saturated_l_q <= 1'b0;
      write_saturated_r_q <= 1'b0;
      fraction_l_q <= '0;
      fraction_r_q <= '0;
      delay_l_q <= '0;
      delay_r_q <= '0;
      sine_l_q <= '0;
      sine_r_q <= '0;
      address_l0_q <= '0;
      address_l1_q <= '0;
      address_r0_q <= '0;
      address_r1_q <= '0;
      valid_l0_q <= 1'b0;
      valid_l1_q <= 1'b0;
      valid_r0_q <= 1'b0;
      valid_r1_q <= 1'b0;
      out_valid <= 1'b0;
      out_l <= '0;
      out_r <= '0;
      config_clamped <= 1'b0;
      lfo_phase <= '0;
      saturation_count <= '0;
    end else begin
      unique case (state)
        IDLE: begin
          if (in_valid && in_ready) begin
            pending_config_q <= config_i;
            input_q <= '{l: in_l, r: in_r};
            state <= PREP_BASE;
          end
        end
        PREP_BASE: begin
          config_base_delay_q <= clamped_base_delay;
          config_stereo_phase_offset_q <= pending_config_q.stereo_phase_offset_q0_32;
          config_enable_q <= pending_config_q.enable;
          config_lfo_phase_inc_q <= pending_config_q.lfo_phase_inc_q0_32;
          config_input_send_q <= clamped_input_send;
          config_feedback_q <= clamped_feedback;
          if (pending_config_q.enable &&
              (base_delay_clamped || feedback_clamped || input_send_clamped))
            config_clamped <= 1'b1;
          state <= PREP_CONFIG;
        end
        PREP_CONFIG: begin
          config_depth_q <= clamped_depth;
          if (pending_config_q.enable && depth_clamped)
            config_clamped <= 1'b1;
          state <= CALC_LFO;
        end
        CALC_LFO: begin
          sine_l_q <= sine_l;
          sine_r_q <= sine_r;
          state <= CALC_DELAY;
        end
        CALC_DELAY: begin
          delay_l_q <= delay_l;
          delay_r_q <= delay_r;
          state <= PREPARE_READ;
        end
        PREPARE_READ: begin
          fraction_l_q <= delay_l_q[7:0];
          fraction_r_q <= delay_r_q[7:0];
          address_l0_q <= write_ptr - PTR_WIDTH'(integer_delay_l);
          address_l1_q <= write_ptr - PTR_WIDTH'(integer_delay_l + 16'd1);
          address_r0_q <= write_ptr - PTR_WIDTH'(integer_delay_r);
          address_r1_q <= write_ptr - PTR_WIDTH'(integer_delay_r + 16'd1);
          valid_l0_q <= integer_delay_l <= 16'(history_age);
          valid_l1_q <= (integer_delay_l + 16'd1) <= 16'(history_age);
          valid_r0_q <= integer_delay_r <= 16'(history_age);
          valid_r1_q <= (integer_delay_r + 16'd1) <= 16'(history_age);
          state <= READ_L0;
        end
        READ_L0: begin
          sample_l0 <= history_l[address_l0_q];
          state <= READ_L1;
        end
        READ_L1: begin
          sample_l1 <= history_l[address_l1_q];
          state <= READ_R0;
        end
        READ_R0: begin
          sample_r0 <= history_r[address_r0_q];
          state <= READ_R1;
        end
        READ_R1: begin
          sample_r1 <= history_r[address_r1_q];
          state <= INTERPOLATE;
        end
        INTERPOLATE: begin
          interpolation_product_l_q <= interpolation_product_l;
          interpolation_product_r_q <= interpolation_product_r;
          state <= INTERPOLATE_SUM;
        end
        INTERPOLATE_SUM: begin
          wet_l_q <= wet_l;
          wet_r_q <= wet_r;
          state <= CALCULATE;
        end
        CALCULATE: begin
          write_l_q <= write_l;
          write_r_q <= write_r;
          write_saturated_l_q <= write_saturated_l;
          write_saturated_r_q <= write_saturated_r;
          state <= COMMIT;
        end
        COMMIT: begin
          history_l[write_ptr] <= write_l_q;
          history_r[write_ptr] <= write_r_q;
          write_ptr <= write_ptr + PTR_WIDTH'(1);
          if (history_age < AGE_WIDTH'(DELAY_CAPACITY))
            history_age <= history_age + AGE_WIDTH'(1);
          lfo_phase <= lfo_phase + config_lfo_phase_inc_q;
          out_l <= config_enable_q ? wet_l_q : '0;
          out_r <= config_enable_q ? wet_r_q : '0;
          out_valid <= 1'b1;
          saturation_count <= sat_add(
              saturation_count, {1'b0, write_saturated_l_q} +
                                {1'b0, write_saturated_r_q});
          state <= HOLD;
        end
        HOLD: begin
          if (out_valid && out_ready) begin
            out_valid <= 1'b0;
            state <= IDLE;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
