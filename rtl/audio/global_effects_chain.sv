module global_effects_chain #(
  parameter int CHORUS_DELAY_CAPACITY = 2048,
  parameter int REVERB_PRE_DELAY_CAPACITY = 2048,
  parameter int REVERB_LINE_LENGTH_0 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[0]),
  parameter int REVERB_LINE_LENGTH_1 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[1]),
  parameter int REVERB_LINE_LENGTH_2 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[2]),
  parameter int REVERB_LINE_LENGTH_3 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[3]),
  parameter int REVERB_LINE_LENGTH_4 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[4]),
  parameter int REVERB_LINE_LENGTH_5 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[5]),
  parameter int REVERB_LINE_LENGTH_6 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[6]),
  parameter int REVERB_LINE_LENGTH_7 = int'(synth_dsp_lut_pkg::FDN_DELAY_LENGTH_LUT[7])
) (
  input  logic                       clk,
  input  logic                       rst,
  input  logic [1:0]                 clear_i,
  input  synth_pkg::chorus_config_t  chorus_config_i,
  input  synth_pkg::reverb_config_t  reverb_config_i,
  input  logic                       in_valid,
  output logic                       in_ready,
  input  synth_pkg::mix_t            in_l,
  input  synth_pkg::mix_t            in_r,
  output logic                       out_valid,
  input  logic                       out_ready,
  output synth_pkg::mix_t            out_l,
  output synth_pkg::mix_t            out_r,
  output synth_pkg::spatial_effect_diagnostics_t diagnostics_o
);
  import synth_pkg::*;

  typedef enum logic [2:0] {
    WAIT_INPUT, WAIT_CHORUS, WAIT_REVERB_INPUT, WAIT_REVERB, WAIT_OUTPUT
  } state_t;

  state_t state;
  chorus_config_t chorus_config_q;
  reverb_config_t reverb_config_q;
  stereo_mix_t dry_q;
  stereo_mix_t chorus_wet_q;

  logic chorus_in_valid;
  logic chorus_in_ready;
  logic chorus_out_valid;
  logic chorus_out_ready;
  mix_t chorus_out_l;
  mix_t chorus_out_r;

  logic reverb_in_valid;
  logic reverb_in_ready;
  mix_t reverb_in_l;
  mix_t reverb_in_r;
  logic reverb_out_valid;
  logic reverb_out_ready;
  mix_t reverb_out_l;
  mix_t reverb_out_r;

  logic mixer_in_valid;
  logic mixer_in_ready;
  logic mixer_out_valid;
  logic mixer_out_ready;
  mix_t mixer_out_l;
  mix_t mixer_out_r;
  mix_t mixer_chorus_wet_l;
  mix_t mixer_chorus_wet_r;
  logic [15:0] processing_cycles;
  logic chorus_config_clamped;
  logic reverb_config_clamped;
  logic mixer_config_clamped;
  logic [15:0] chorus_history_level_frames;
  logic [31:0] chorus_lfo_phase_q0_32;
  logic [7:0] reverb_valid_line_mask;
  logic [15:0] reverb_pre_delay_occupancy;
  logic [31:0] chorus_saturation_count;
  logic [31:0] reverb_saturation_count;
  logic [31:0] mixer_saturation_count;
  logic [15:0] reverb_max_processing_cycles;
  logic [31:0] input_frame_count;
  logic [31:0] output_frame_count;
  logic [15:0] max_processing_cycles;

  function automatic logic [31:0] sat_inc32(input logic [31:0] value);
    sat_inc32 = (value == 32'hffff_ffff) ? value : value + 32'd1;
  endfunction

  assign in_ready = (state == WAIT_INPUT) && chorus_in_ready;
  always_comb begin
    diagnostics_o = '0;
    diagnostics_o.chorus_enabled = chorus_config_i.enable;
    diagnostics_o.reverb_enabled = reverb_config_i.enable;
    diagnostics_o.busy = state != WAIT_INPUT;
    diagnostics_o.chorus_config_clamped = chorus_config_clamped;
    diagnostics_o.reverb_config_clamped = reverb_config_clamped;
    diagnostics_o.mixer_config_clamped = mixer_config_clamped;
    diagnostics_o.chorus_history_level_frames = chorus_history_level_frames;
    diagnostics_o.chorus_lfo_phase_q0_32 = chorus_lfo_phase_q0_32;
    diagnostics_o.reverb_valid_line_mask = reverb_valid_line_mask;
    diagnostics_o.reverb_pre_delay_occupancy = reverb_pre_delay_occupancy;
    diagnostics_o.input_frame_count = input_frame_count;
    diagnostics_o.output_frame_count = output_frame_count;
    diagnostics_o.max_processing_cycles = max_processing_cycles;
    diagnostics_o.chorus_saturation_count = chorus_saturation_count;
    diagnostics_o.reverb_saturation_count = reverb_saturation_count;
    diagnostics_o.mixer_saturation_count = mixer_saturation_count;
    diagnostics_o.reverb_max_processing_cycles = reverb_max_processing_cycles;
  end
  assign chorus_in_valid = (state == WAIT_INPUT) && in_valid;
  assign chorus_out_ready = state == WAIT_CHORUS;
  assign reverb_in_valid = state == WAIT_REVERB_INPUT;
  assign reverb_out_ready = (state == WAIT_REVERB) && mixer_in_ready;
  assign mixer_in_valid = (state == WAIT_REVERB) && reverb_out_valid;
  assign mixer_out_ready = (state == WAIT_OUTPUT) && out_ready;
  assign out_valid = (state == WAIT_OUTPUT) && mixer_out_valid;
  assign out_l = mixer_out_l;
  assign out_r = mixer_out_r;
  assign mixer_chorus_wet_l = (state == WAIT_CHORUS) ? chorus_out_l :
                                                        chorus_wet_q.l;
  assign mixer_chorus_wet_r = (state == WAIT_CHORUS) ? chorus_out_r :
                                                        chorus_wet_q.r;

  /* verilator lint_off PINCONNECTEMPTY */
  stereo_chorus #(
    .DELAY_CAPACITY(CHORUS_DELAY_CAPACITY)
  ) chorus (
    .clk,
    .rst,
    .clear_i(clear_i[0]),
    .config_i(chorus_config_i),
    .in_valid(chorus_in_valid),
    .in_ready(chorus_in_ready),
    .in_l,
    .in_r,
    .out_valid(chorus_out_valid),
    .out_ready(chorus_out_ready),
    .out_l(chorus_out_l),
    .out_r(chorus_out_r),
    .busy(),
    .config_clamped(chorus_config_clamped),
    .history_level_frames(chorus_history_level_frames),
    .lfo_phase_q0_32(chorus_lfo_phase_q0_32),
    .saturation_count(chorus_saturation_count)
  );

  fdn_reverb #(
    .PRE_DELAY_CAPACITY(REVERB_PRE_DELAY_CAPACITY),
    .LINE_LENGTH_0(REVERB_LINE_LENGTH_0),
    .LINE_LENGTH_1(REVERB_LINE_LENGTH_1),
    .LINE_LENGTH_2(REVERB_LINE_LENGTH_2),
    .LINE_LENGTH_3(REVERB_LINE_LENGTH_3),
    .LINE_LENGTH_4(REVERB_LINE_LENGTH_4),
    .LINE_LENGTH_5(REVERB_LINE_LENGTH_5),
    .LINE_LENGTH_6(REVERB_LINE_LENGTH_6),
    .LINE_LENGTH_7(REVERB_LINE_LENGTH_7)
  ) reverb (
    .clk,
    .rst,
    .clear_i(clear_i[1]),
    .config_i(reverb_config_q),
    .in_valid(reverb_in_valid),
    .in_ready(reverb_in_ready),
    .in_l(reverb_in_l),
    .in_r(reverb_in_r),
    .out_valid(reverb_out_valid),
    .out_ready(reverb_out_ready),
    .out_l(reverb_out_l),
    .out_r(reverb_out_r),
    .busy(),
    .config_clamped(reverb_config_clamped),
    .valid_line_mask(reverb_valid_line_mask),
    .pre_delay_occupancy(reverb_pre_delay_occupancy),
    .input_frame_count(),
    .output_frame_count(),
    .saturation_count(reverb_saturation_count),
    .max_processing_cycles(reverb_max_processing_cycles)
  );

  effect_return_mixer mixer (
    .clk,
    .rst,
    .clear_i(|clear_i),
    .chorus_config_i(chorus_config_q),
    .reverb_config_i(reverb_config_q),
    .dry_l_i(dry_q.l),
    .dry_r_i(dry_q.r),
    .chorus_wet_l_i(mixer_chorus_wet_l),
    .chorus_wet_r_i(mixer_chorus_wet_r),
    .reverb_input_l_o(reverb_in_l),
    .reverb_input_r_o(reverb_in_r),
    .reverb_input_saturated_l_o(),
    .reverb_input_saturated_r_o(),
    .reverb_input_commit_i(chorus_out_valid && chorus_out_ready),
    .in_valid(mixer_in_valid),
    .in_ready(mixer_in_ready),
    .reverb_wet_l_i(reverb_out_l),
    .reverb_wet_r_i(reverb_out_r),
    .out_valid(mixer_out_valid),
    .out_ready(mixer_out_ready),
    .out_l(mixer_out_l),
    .out_r(mixer_out_r),
    .config_clamped(mixer_config_clamped),
    .saturation_count(mixer_saturation_count)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  always_ff @(posedge clk) begin
    if (rst || (|clear_i)) begin
      state <= WAIT_INPUT;
      chorus_config_q <= '0;
      reverb_config_q <= '0;
      dry_q <= '0;
      chorus_wet_q <= '0;
      processing_cycles <= '0;
      input_frame_count <= '0;
      output_frame_count <= '0;
      max_processing_cycles <= '0;
    end else begin
      if (state != WAIT_INPUT &&
          !(state == WAIT_OUTPUT && mixer_out_valid) &&
          processing_cycles != 16'hffff)
        processing_cycles <= processing_cycles + 1'b1;

      unique case (state)
        WAIT_INPUT: begin
          if (in_valid && in_ready) begin
            chorus_config_q <= chorus_config_i;
            reverb_config_q <= reverb_config_i;
            dry_q <= '{l: in_l, r: in_r};
            processing_cycles <= 16'd1;
            input_frame_count <= sat_inc32(input_frame_count);
            state <= WAIT_CHORUS;
          end
        end
        WAIT_CHORUS: begin
          if (chorus_out_valid && chorus_out_ready) begin
            chorus_wet_q <= '{l: chorus_out_l, r: chorus_out_r};
            state <= WAIT_REVERB_INPUT;
          end
        end
        WAIT_REVERB_INPUT: begin
          if (reverb_in_valid && reverb_in_ready)
            state <= WAIT_REVERB;
        end
        WAIT_REVERB: begin
          if (reverb_out_valid && reverb_out_ready)
            state <= WAIT_OUTPUT;
        end
        WAIT_OUTPUT: begin
          if (mixer_out_valid && (processing_cycles > max_processing_cycles))
            max_processing_cycles <= processing_cycles;
          if (mixer_out_valid && mixer_out_ready) begin
            output_frame_count <= sat_inc32(output_frame_count);
            state <= WAIT_INPUT;
          end
        end
        default: state <= WAIT_INPUT;
      endcase
    end
  end
endmodule
