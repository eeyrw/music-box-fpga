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

  typedef enum logic [2:0] {
    IDLE, READ_L0, READ_L1, READ_R0, READ_R1, CALCULATE, HOLD
  } state_t;

  state_t state;
  (* ram_style = "block" *) stereo_mix_t history [0:DELAY_CAPACITY-1];
  logic [PTR_WIDTH-1:0] write_ptr;
  logic [AGE_WIDTH-1:0] history_age;
  logic [31:0] lfo_phase;
  logic config_enable_q;
  logic [31:0] config_lfo_phase_inc_q;
  logic [15:0] config_input_send_q;
  logic signed [15:0] config_feedback_q;
  stereo_mix_t input_q;
  mix_t sample_l0;
  mix_t sample_l1;
  mix_t sample_r0;
  mix_t sample_r1;
  logic [7:0] fraction_l_q;
  logic [7:0] fraction_r_q;
  logic [PTR_WIDTH-1:0] address_l0_q;
  logic [PTR_WIDTH-1:0] address_l1_q;
  logic [PTR_WIDTH-1:0] address_r0_q;
  logic [PTR_WIDTH-1:0] address_r1_q;
  logic valid_l0_q;
  logic valid_l1_q;
  logic valid_r0_q;
  logic valid_r1_q;

  // return_gain_q1_15 is carried in the shared configuration for the separate
  // effect-return mixer and is intentionally not consumed by this wet engine.
  /* verilator lint_off UNUSEDSIGNAL */
  chorus_config_t effective_config;
  /* verilator lint_on UNUSEDSIGNAL */
  logic effective_config_clamped;
  logic [23:0] depth_limit;
  logic signed [15:0] sine_l;
  logic signed [15:0] sine_r;
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
  logic signed [24:0] delta_l;
  logic signed [24:0] delta_r;
  logic signed [32:0] interpolation_product_l;
  logic signed [32:0] interpolation_product_r;
  mix_t wet_l;
  mix_t wet_r;
  logic signed [39:0] input_product_l;
  logic signed [39:0] input_product_r;
  logic signed [39:0] feedback_product_l;
  logic signed [39:0] feedback_product_r;
  logic signed [41:0] write_wide_l;
  logic signed [41:0] write_wide_r;
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

  function automatic mix_t saturate_mix(input logic signed [41:0] value);
    if (value > 42'sd8388607)
      saturate_mix = 24'sh7fffff;
    else if (value < -42'sd8388608)
      saturate_mix = 24'sh800000;
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
    effective_config = config_i;
    effective_config_clamped = 1'b0;
    if (effective_config.base_delay_q16_8 < MIN_DELAY_Q16_8) begin
      effective_config.base_delay_q16_8 = MIN_DELAY_Q16_8;
      effective_config_clamped = 1'b1;
    end else if (effective_config.base_delay_q16_8 > MAX_DELAY_Q16_8) begin
      effective_config.base_delay_q16_8 = MAX_DELAY_Q16_8;
      effective_config_clamped = 1'b1;
    end
    depth_limit = effective_config.base_delay_q16_8 - MIN_DELAY_Q16_8;
    if ((MAX_DELAY_Q16_8 - effective_config.base_delay_q16_8) < depth_limit)
      depth_limit = MAX_DELAY_Q16_8 - effective_config.base_delay_q16_8;
    if (effective_config.depth_q16_8 > depth_limit) begin
      effective_config.depth_q16_8 = depth_limit;
      effective_config_clamped = 1'b1;
    end
    if ($signed(effective_config.feedback_q1_15) > FEEDBACK_MAX_Q1_15) begin
      effective_config.feedback_q1_15 = FEEDBACK_MAX_Q1_15;
      effective_config_clamped = 1'b1;
    end else if ($signed(effective_config.feedback_q1_15) < FEEDBACK_MIN_Q1_15) begin
      effective_config.feedback_q1_15 = FEEDBACK_MIN_Q1_15;
      effective_config_clamped = 1'b1;
    end
    if (effective_config.input_send_q1_15 > 16'h7fff) begin
      effective_config.input_send_q1_15 = 16'h7fff;
      effective_config_clamped = 1'b1;
    end

    sine_l = sine_q1_15(lfo_phase);
    sine_r = sine_q1_15(lfo_phase +
                        effective_config.stereo_phase_offset_q0_32);
    modulation_product_l = $signed({1'b0, effective_config.depth_q16_8}) * sine_l;
    modulation_product_r = $signed({1'b0, effective_config.depth_q16_8}) * sine_r;
    delay_l = 24'($signed({17'd0, effective_config.base_delay_q16_8}) +
                  (modulation_product_l >>> 15));
    delay_r = 24'($signed({17'd0, effective_config.base_delay_q16_8}) +
                  (modulation_product_r >>> 15));
    integer_delay_l = delay_l[23:8];
    integer_delay_r = delay_r[23:8];

    tap_l0 = valid_l0_q ? sample_l0 : '0;
    tap_l1 = valid_l1_q ? sample_l1 : '0;
    tap_r0 = valid_r0_q ? sample_r0 : '0;
    tap_r1 = valid_r1_q ? sample_r1 : '0;
    delta_l = $signed(tap_l1) - $signed(tap_l0);
    delta_r = $signed(tap_r1) - $signed(tap_r0);
    interpolation_product_l = delta_l * $signed({1'b0, fraction_l_q});
    interpolation_product_r = delta_r * $signed({1'b0, fraction_r_q});
    wet_l = mix_t'($signed({{10{tap_l0[23]}}, tap_l0}) +
                     ($signed({interpolation_product_l[32], interpolation_product_l}) >>> 8));
    wet_r = mix_t'($signed({{10{tap_r0[23]}}, tap_r0}) +
                     ($signed({interpolation_product_r[32], interpolation_product_r}) >>> 8));

    input_product_l = input_q.l * $signed({1'b0, config_input_send_q});
    input_product_r = input_q.r * $signed({1'b0, config_input_send_q});
    feedback_product_l = wet_l * config_feedback_q;
    feedback_product_r = wet_r * config_feedback_q;
    if (config_input_send_q == 16'h7fff) begin
      write_wide_l = $signed({{18{input_q.l[23]}}, input_q.l}) +
                     ($signed({{2{feedback_product_l[39]}}, feedback_product_l}) >>> 15);
      write_wide_r = $signed({{18{input_q.r[23]}}, input_q.r}) +
                     ($signed({{2{feedback_product_r[39]}}, feedback_product_r}) >>> 15);
    end else begin
      write_wide_l = ($signed({{2{input_product_l[39]}}, input_product_l}) >>> 15) +
                     ($signed({{2{feedback_product_l[39]}}, feedback_product_l}) >>> 15);
      write_wide_r = ($signed({{2{input_product_r[39]}}, input_product_r}) >>> 15) +
                     ($signed({{2{feedback_product_r[39]}}, feedback_product_r}) >>> 15);
    end
    write_l = saturate_mix(write_wide_l);
    write_r = saturate_mix(write_wide_r);
    write_saturated_l = (write_wide_l > 42'sd8388607) ||
                        (write_wide_l < -42'sd8388608);
    write_saturated_r = (write_wide_r > 42'sd8388607) ||
                        (write_wide_r < -42'sd8388608);
  end

  always_ff @(posedge clk) begin
    if (rst || clear_i) begin
      state <= IDLE;
      write_ptr <= '0;
      history_age <= '0;
      config_enable_q <= 1'b0;
      config_lfo_phase_inc_q <= '0;
      config_input_send_q <= '0;
      config_feedback_q <= '0;
      input_q <= '0;
      sample_l0 <= '0;
      sample_l1 <= '0;
      sample_r0 <= '0;
      sample_r1 <= '0;
      fraction_l_q <= '0;
      fraction_r_q <= '0;
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
            config_enable_q <= effective_config.enable;
            config_lfo_phase_inc_q <= effective_config.lfo_phase_inc_q0_32;
            config_input_send_q <= effective_config.input_send_q1_15;
            config_feedback_q <= effective_config.feedback_q1_15;
            input_q <= '{l: in_l, r: in_r};
            fraction_l_q <= delay_l[7:0];
            fraction_r_q <= delay_r[7:0];
            address_l0_q <= write_ptr - PTR_WIDTH'(integer_delay_l);
            address_l1_q <= write_ptr - PTR_WIDTH'(integer_delay_l + 16'd1);
            address_r0_q <= write_ptr - PTR_WIDTH'(integer_delay_r);
            address_r1_q <= write_ptr - PTR_WIDTH'(integer_delay_r + 16'd1);
            valid_l0_q <= integer_delay_l <= 16'(history_age);
            valid_l1_q <= (integer_delay_l + 16'd1) <= 16'(history_age);
            valid_r0_q <= integer_delay_r <= 16'(history_age);
            valid_r1_q <= (integer_delay_r + 16'd1) <= 16'(history_age);
            if (effective_config.enable && effective_config_clamped)
              config_clamped <= 1'b1;
            state <= READ_L0;
          end
        end
        READ_L0: begin
          sample_l0 <= history[address_l0_q].l;
          state <= READ_L1;
        end
        READ_L1: begin
          sample_l1 <= history[address_l1_q].l;
          state <= READ_R0;
        end
        READ_R0: begin
          sample_r0 <= history[address_r0_q].r;
          state <= READ_R1;
        end
        READ_R1: begin
          sample_r1 <= history[address_r1_q].r;
          state <= CALCULATE;
        end
        CALCULATE: begin
          history[write_ptr] <= '{l: write_l, r: write_r};
          write_ptr <= write_ptr + PTR_WIDTH'(1);
          if (history_age < AGE_WIDTH'(DELAY_CAPACITY))
            history_age <= history_age + AGE_WIDTH'(1);
          lfo_phase <= lfo_phase + config_lfo_phase_inc_q;
          out_l <= config_enable_q ? wet_l : '0;
          out_r <= config_enable_q ? wet_r : '0;
          out_valid <= 1'b1;
          saturation_count <= sat_add(
              saturation_count, {1'b0, write_saturated_l} +
                                {1'b0, write_saturated_r});
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
