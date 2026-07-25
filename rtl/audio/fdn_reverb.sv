module fdn_reverb #(
  parameter int PRE_DELAY_CAPACITY = 2048,
  parameter int LINE_LENGTH_0 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[0]),
  parameter int LINE_LENGTH_1 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[1]),
  parameter int LINE_LENGTH_2 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[2]),
  parameter int LINE_LENGTH_3 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[3]),
  parameter int LINE_LENGTH_4 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[4]),
  parameter int LINE_LENGTH_5 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[5]),
  parameter int LINE_LENGTH_6 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[6]),
  parameter int LINE_LENGTH_7 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[7])
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       clear_i,
  input  synth_pkg::reverb_config_t  config_i,
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
  output logic [7:0]                 valid_line_mask,
  output logic [15:0]                pre_delay_occupancy,
  output logic [31:0]                input_frame_count,
  output logic [31:0]                output_frame_count,
  output logic [31:0]                saturation_count,
  output logic [15:0]                max_processing_cycles
);
  import synth_pkg::*;

  localparam int LINE_COUNT = 8;
  localparam int BASE_0 = 0;
  localparam int BASE_1 = BASE_0 + LINE_LENGTH_0;
  localparam int BASE_2 = BASE_1 + LINE_LENGTH_1;
  localparam int BASE_3 = BASE_2 + LINE_LENGTH_2;
  localparam int BASE_4 = BASE_3 + LINE_LENGTH_3;
  localparam int BASE_5 = BASE_4 + LINE_LENGTH_4;
  localparam int BASE_6 = BASE_5 + LINE_LENGTH_5;
  localparam int BASE_7 = BASE_6 + LINE_LENGTH_6;
  localparam int TOTAL_SAMPLES = BASE_7 + LINE_LENGTH_7;
  localparam int FDN_ADDR_WIDTH = $clog2(TOTAL_SAMPLES);
  localparam int PRE_PTR_WIDTH = (PRE_DELAY_CAPACITY <= 1) ? 1 :
                                 $clog2(PRE_DELAY_CAPACITY);
  localparam int PRE_AGE_WIDTH = $clog2(PRE_DELAY_CAPACITY + 1);
  localparam logic [15:0] FEEDBACK_MAX_Q1_15 = 16'h2d41;

  typedef enum logic [2:0] {
    IDLE, PRE_DELAY, READ_LINES, DAMP_LINES, WRITE_LINES, EMIT, HOLD
  } state_t;

  state_t state;
  (* ram_style = "block" *) mix_t fdn_memory [0:TOTAL_SAMPLES-1];
  (* ram_style = "block" *) stereo_mix_t pre_delay_memory [0:PRE_DELAY_CAPACITY-1];
  logic [15:0] line_pointer [0:LINE_COUNT-1];
  logic [15:0] line_age [0:LINE_COUNT-1];
  mix_t line_read [0:LINE_COUNT-1];
  mix_t damping_state [0:LINE_COUNT-1];
  mix_t damped [0:LINE_COUNT-1];
  logic [2:0] line_index;
  logic [PRE_PTR_WIDTH-1:0] pre_delay_pointer;
  logic [PRE_AGE_WIDTH-1:0] pre_delay_age;
  stereo_mix_t input_q;
  stereo_mix_t delayed_input_q;
  logic config_enable_q;
  logic [15:0] config_damping_q;
  logic [7:0][15:0] config_feedback_gain_q;
  logic [10:0] config_pre_delay_q;
  logic [15:0] processing_cycles;

  // Return and chorus-route gains are consumed by the separate return mixer.
  /* verilator lint_off UNUSEDSIGNAL */
  reverb_config_t effective_config;
  /* verilator lint_on UNUSEDSIGNAL */
  logic effective_config_clamped;
  logic signed [24:0] damping_delta;
  logic signed [41:0] damping_product;
  mix_t damped_value;
  logic signed [24:0] hadamard_a [0:7];
  logic signed [25:0] hadamard_b [0:7];
  logic signed [26:0] hadamard_value [0:7];
  logic signed [41:0] scaled_input_l;
  logic signed [41:0] scaled_input_r;
  logic signed [42:0] injection;
  logic signed [44:0] feedback_product;
  logic signed [45:0] line_write_wide;
  mix_t line_write_value;
  logic line_write_saturated;
  logic signed [26:0] wet_sum_l;
  logic signed [26:0] wet_sum_r;

  initial begin
    if (PRE_DELAY_CAPACITY < 1 ||
        (PRE_DELAY_CAPACITY & (PRE_DELAY_CAPACITY - 1)) != 0)
      $error("PRE_DELAY_CAPACITY must be a positive power of two");
    if (LINE_LENGTH_0 < 1 || LINE_LENGTH_1 < 1 || LINE_LENGTH_2 < 1 ||
        LINE_LENGTH_3 < 1 || LINE_LENGTH_4 < 1 || LINE_LENGTH_5 < 1 ||
        LINE_LENGTH_6 < 1 || LINE_LENGTH_7 < 1)
      $error("all FDN line lengths must be positive");
  end

  function automatic int unsigned line_length(input logic [2:0] index);
    case (index)
      3'd0: line_length = LINE_LENGTH_0;
      3'd1: line_length = LINE_LENGTH_1;
      3'd2: line_length = LINE_LENGTH_2;
      3'd3: line_length = LINE_LENGTH_3;
      3'd4: line_length = LINE_LENGTH_4;
      3'd5: line_length = LINE_LENGTH_5;
      3'd6: line_length = LINE_LENGTH_6;
      default: line_length = LINE_LENGTH_7;
    endcase
  endfunction

  function automatic logic [FDN_ADDR_WIDTH-1:0] line_base(input logic [2:0] index);
    case (index)
      3'd0: line_base = FDN_ADDR_WIDTH'(BASE_0);
      3'd1: line_base = FDN_ADDR_WIDTH'(BASE_1);
      3'd2: line_base = FDN_ADDR_WIDTH'(BASE_2);
      3'd3: line_base = FDN_ADDR_WIDTH'(BASE_3);
      3'd4: line_base = FDN_ADDR_WIDTH'(BASE_4);
      3'd5: line_base = FDN_ADDR_WIDTH'(BASE_5);
      3'd6: line_base = FDN_ADDR_WIDTH'(BASE_6);
      default: line_base = FDN_ADDR_WIDTH'(BASE_7);
    endcase
  endfunction

  function automatic mix_t saturate_mix(input logic signed [45:0] value);
    if (value > 46'sd8388607)
      saturate_mix = 24'sh7fffff;
    else if (value < -46'sd8388608)
      saturate_mix = 24'sh800000;
    else
      saturate_mix = mix_t'(value);
  endfunction

  function automatic logic [31:0] sat_inc(input logic [31:0] value);
    sat_inc = (value == 32'hffff_ffff) ? value : value + 32'd1;
  endfunction

  assign in_ready = (state == IDLE) && !out_valid;
  assign busy = state != IDLE;
  assign pre_delay_occupancy = 16'(pre_delay_age);

  always_comb begin
    effective_config = config_i;
    effective_config_clamped = 1'b0;
    if (effective_config.damping_q1_15 > 16'h7fff) begin
      effective_config.damping_q1_15 = 16'h7fff;
      effective_config_clamped = 1'b1;
    end
    /* verilator lint_off CMPCONST */
    if (effective_config.pre_delay_frames > 11'(PRE_DELAY_CAPACITY - 1)) begin
      effective_config.pre_delay_frames = 11'(PRE_DELAY_CAPACITY - 1);
      effective_config_clamped = 1'b1;
    end
    /* verilator lint_on CMPCONST */
    for (int line = 0; line < LINE_COUNT; line++) begin
      if (effective_config.feedback_gain_q1_15[line] > FEEDBACK_MAX_Q1_15) begin
        effective_config.feedback_gain_q1_15[line] = FEEDBACK_MAX_Q1_15;
        effective_config_clamped = 1'b1;
      end
    end

    damping_delta = $signed(damping_state[line_index]) -
                    $signed(line_read[line_index]);
    damping_product = damping_delta * $signed({1'b0, config_damping_q});
    damped_value = mix_t'(
        $signed({{18{line_read[line_index][23]}}, line_read[line_index]}) +
        (damping_product >>> 15));

    for (int pair = 0; pair < 8; pair += 2) begin
      hadamard_a[pair] = $signed({damped[pair][23], damped[pair]}) +
                         $signed({damped[pair + 1][23], damped[pair + 1]});
      hadamard_a[pair + 1] = $signed({damped[pair][23], damped[pair]}) -
                             $signed({damped[pair + 1][23], damped[pair + 1]});
    end
    for (int block = 0; block < 8; block += 4) begin
      hadamard_b[block] = $signed(hadamard_a[block]) +
                          $signed(hadamard_a[block + 2]);
      hadamard_b[block + 1] = $signed(hadamard_a[block + 1]) +
                              $signed(hadamard_a[block + 3]);
      hadamard_b[block + 2] = $signed(hadamard_a[block]) -
                              $signed(hadamard_a[block + 2]);
      hadamard_b[block + 3] = $signed(hadamard_a[block + 1]) -
                              $signed(hadamard_a[block + 3]);
    end
    for (int item = 0; item < 4; item++) begin
      hadamard_value[item] = $signed(hadamard_b[item]) +
                             $signed(hadamard_b[item + 4]);
      hadamard_value[item + 4] = $signed(hadamard_b[item]) -
                                 $signed(hadamard_b[item + 4]);
    end

    scaled_input_l = {{18{delayed_input_q.l[23]}}, delayed_input_q.l};
    scaled_input_r = {{18{delayed_input_q.r[23]}}, delayed_input_q.r};
    injection = line_index[0]
        ? ($signed({scaled_input_l[41], scaled_input_l}) -
           $signed({scaled_input_r[41], scaled_input_r})) >>> 1
        : ($signed({scaled_input_l[41], scaled_input_l}) +
           $signed({scaled_input_r[41], scaled_input_r})) >>> 1;
    feedback_product = hadamard_value[line_index] *
                       $signed({1'b0, config_feedback_gain_q[line_index]});
    line_write_wide = $signed({{3{injection[42]}}, injection}) +
                      ($signed({feedback_product[44], feedback_product}) >>> 15);
    line_write_value = saturate_mix(line_write_wide);
    line_write_saturated = (line_write_wide > 46'sd8388607) ||
                           (line_write_wide < -46'sd8388608);

    wet_sum_l = '0;
    wet_sum_r = '0;
    for (int line = 0; line < LINE_COUNT; line++) begin
      wet_sum_l = line[1]
          ? wet_sum_l - $signed({{3{damped[line][23]}}, damped[line]})
          : wet_sum_l + $signed({{3{damped[line][23]}}, damped[line]});
      wet_sum_r = ^line[1:0]
          ? wet_sum_r - $signed({{3{damped[line][23]}}, damped[line]})
          : wet_sum_r + $signed({{3{damped[line][23]}}, damped[line]});
    end
  end

  always_ff @(posedge clk) begin
    if (rst || clear_i) begin
      state <= IDLE;
      line_index <= '0;
      pre_delay_pointer <= '0;
      pre_delay_age <= '0;
      input_q <= '0;
      delayed_input_q <= '0;
      config_enable_q <= 1'b0;
      config_damping_q <= '0;
      config_feedback_gain_q <= '0;
      config_pre_delay_q <= '0;
      processing_cycles <= '0;
      out_valid <= 1'b0;
      out_l <= '0;
      out_r <= '0;
      config_clamped <= 1'b0;
      valid_line_mask <= '0;
      input_frame_count <= '0;
      output_frame_count <= '0;
      saturation_count <= '0;
      max_processing_cycles <= '0;
      for (int line = 0; line < LINE_COUNT; line++) begin
        line_pointer[line] <= '0;
        line_age[line] <= '0;
        line_read[line] <= '0;
        damping_state[line] <= '0;
        damped[line] <= '0;
      end
    end else begin
      if (state != IDLE && state != HOLD)
        processing_cycles <= processing_cycles + 16'd1;

      unique case (state)
        IDLE: begin
          if (in_valid && in_ready) begin
            input_q <= '{l: in_l, r: in_r};
            config_enable_q <= effective_config.enable;
            config_damping_q <= effective_config.damping_q1_15;
            config_feedback_gain_q <= effective_config.feedback_gain_q1_15;
            config_pre_delay_q <= effective_config.pre_delay_frames;
            processing_cycles <= 16'd1;
            input_frame_count <= sat_inc(input_frame_count);
            if (effective_config_clamped)
              config_clamped <= 1'b1;
            state <= PRE_DELAY;
          end
        end
        PRE_DELAY: begin
          if (config_pre_delay_q == 0) begin
            delayed_input_q <= input_q;
          end else if (config_pre_delay_q <= 11'(pre_delay_age)) begin
            delayed_input_q <= pre_delay_memory[
                pre_delay_pointer - PRE_PTR_WIDTH'(config_pre_delay_q)];
          end else begin
            delayed_input_q <= '0;
          end
          pre_delay_memory[pre_delay_pointer] <= input_q;
          if (pre_delay_pointer == PRE_PTR_WIDTH'(PRE_DELAY_CAPACITY - 1))
            pre_delay_pointer <= '0;
          else
            pre_delay_pointer <= pre_delay_pointer + PRE_PTR_WIDTH'(1);
          if (pre_delay_age < PRE_AGE_WIDTH'(PRE_DELAY_CAPACITY))
            pre_delay_age <= pre_delay_age + PRE_AGE_WIDTH'(1);
          line_index <= '0;
          state <= READ_LINES;
        end
        READ_LINES: begin
          if (line_age[line_index] < 16'(line_length(line_index)))
            line_read[line_index] <= '0;
          else
            line_read[line_index] <= fdn_memory[
                line_base(line_index) + FDN_ADDR_WIDTH'(line_pointer[line_index])];
          if (line_index == 3'd7) begin
            line_index <= '0;
            state <= DAMP_LINES;
          end else begin
            line_index <= line_index + 3'd1;
          end
        end
        DAMP_LINES: begin
          damped[line_index] <= damped_value;
          damping_state[line_index] <= damped_value;
          if (line_index == 3'd7) begin
            line_index <= '0;
            state <= WRITE_LINES;
          end else begin
            line_index <= line_index + 3'd1;
          end
        end
        WRITE_LINES: begin
          fdn_memory[line_base(line_index) +
                     FDN_ADDR_WIDTH'(line_pointer[line_index])] <= line_write_value;
          if (line_pointer[line_index] == 16'(line_length(line_index) - 1))
            line_pointer[line_index] <= '0;
          else
            line_pointer[line_index] <= line_pointer[line_index] + 16'd1;
          if (line_age[line_index] < 16'(line_length(line_index))) begin
            line_age[line_index] <= line_age[line_index] + 16'd1;
            if ((line_age[line_index] + 16'd1) == 16'(line_length(line_index)))
              valid_line_mask[line_index] <= 1'b1;
          end
          if (line_write_saturated)
            saturation_count <= sat_inc(saturation_count);
          if (line_index == 3'd7) begin
            line_index <= '0;
            state <= EMIT;
          end else begin
            line_index <= line_index + 3'd1;
          end
        end
        EMIT: begin
          out_l <= config_enable_q ? mix_t'(wet_sum_l >>> 3) : '0;
          out_r <= config_enable_q ? mix_t'(wet_sum_r >>> 3) : '0;
          out_valid <= 1'b1;
          if (processing_cycles > max_processing_cycles)
            max_processing_cycles <= processing_cycles;
          state <= HOLD;
        end
        HOLD: begin
          if (out_valid && out_ready) begin
            out_valid <= 1'b0;
            output_frame_count <= sat_inc(output_frame_count);
            state <= IDLE;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
