module voice_commit_engine (
  input  logic                                  clk,
  input  logic                                  rst,
  input  logic                                  start,
  input  logic                                  start_filter,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] start_voice,
  input  logic                                  envelope_written,
  input  logic                                  shadow_filter_enable,
  input  logic [(5*synth_pkg::FILTER_COEFF_WIDTH)-1:0] shadow_filter_coeff,
  output logic                                  busy,
  output logic                                  done,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0] descriptor_read_voice,
  output logic [15:0]                           descriptor_read_offset,
  input  logic [31:0]                           descriptor_read_data,
  output logic                                  active_config_write,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0] active_config_write_voice,
  output synth_pkg::voice_config_t              active_config_write_data,
  output logic                                  active_config_valid_write,
  output logic                                  active_config_valid_data,
  output logic                                  runtime_phase_write,
  output logic                                  runtime_gain_write,
  output logic                                  runtime_envelope_write,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0] runtime_write_voice,
  output logic [31:0]                           runtime_phase_write_data,
  output logic [31:0]                           runtime_gain_write_data,
  output logic [15:0]                           runtime_envelope_write_data,
  output logic                                  runtime_release_clear,
  output logic                                  runtime_filter_write,
  output logic [(5*synth_pkg::FILTER_COEFF_WIDTH)-1:0] runtime_filter_write_data,
  output logic                                  runtime_filter_enable_write,
  output logic                                  runtime_filter_enable_data
);
  import synth_pkg::*;
  import synth_register_pkg::*;

  localparam logic [15:0] OFF_BASE        = REG_OFF_BASE_ADDR;
  localparam logic [15:0] OFF_BASE_R      = REG_OFF_BASE_ADDR_R;
  localparam logic [15:0] OFF_LENGTH      = REG_OFF_LENGTH;
  localparam logic [15:0] OFF_LENGTH_R    = REG_OFF_LENGTH_R;
  localparam logic [15:0] OFF_LOOP_START  = REG_OFF_LOOP_START;
  localparam logic [15:0] OFF_LOOP_START_R = REG_OFF_LOOP_START_R;
  localparam logic [15:0] OFF_LOOP_END    = REG_OFF_LOOP_END;
  localparam logic [15:0] OFF_LOOP_END_R  = REG_OFF_LOOP_END_R;
  localparam logic [15:0] OFF_VOICE_CTL   = REG_OFF_VOICE_CONTROL;
  localparam logic [15:0] OFF_PHASE_INIT  = REG_OFF_PHASE_INIT;
  localparam logic [15:0] OFF_PHASE_INC   = REG_OFF_PHASE_INC;
  localparam logic [15:0] OFF_GAIN_L      = REG_OFF_GAIN_L;
  localparam logic [15:0] OFF_GAIN_R      = REG_OFF_GAIN_R;
  localparam logic [15:0] OFF_ENVELOPE    = REG_OFF_ENVELOPE_LEVEL;

  localparam int FILTER_COEFF_WORD_WIDTH = 5 * FILTER_COEFF_WIDTH;
  localparam int VOICE_COMMIT_LAST_SEQ = 13;
  localparam int FILTER_UPDATE_LAST_SEQ = 0;
  localparam logic [FILTER_COEFF_WORD_WIDTH-1:0] DEFAULT_FILTER_COEFF = {
    16'sh4000,
    16'sh0000,
    16'sh0000,
    16'sh0000,
    16'sh0000
  };

  typedef enum logic [2:0] {
    COMMIT_IDLE,
    COMMIT_READ,
    COMMIT_CAPTURE,
    COMMIT_APPLY,
    COMMIT_DONE
  } state_t;

  typedef enum logic {
    MODE_VOICE,
    MODE_FILTER
  } mode_t;

  state_t state;
  mode_t mode;
  logic [VOICE_ID_WIDTH-1:0] commit_voice;
  logic [4:0] commit_seq;
  logic commit_envelope_written;
  logic [15:0] commit_offset;
  logic commit_last_seq;
  voice_config_t staged_config;
  logic [PHASE_WIDTH-1:0] staged_phase_inc;
  logic signed [15:0] staged_gain_l;
  logic signed [15:0] staged_gain_r;
  logic signed [15:0] staged_envelope_level;
  logic staged_filter_enable;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] staged_filter_coeff;

  function automatic logic [15:0] voice_commit_offset(input logic [4:0] seq);
    unique case (seq)
      5'd0: voice_commit_offset = OFF_VOICE_CTL;
      5'd1: voice_commit_offset = OFF_BASE;
      5'd2: voice_commit_offset = OFF_BASE_R;
      5'd3: voice_commit_offset = OFF_LENGTH;
      5'd4: voice_commit_offset = OFF_LENGTH_R;
      5'd5: voice_commit_offset = OFF_LOOP_START;
      5'd6: voice_commit_offset = OFF_LOOP_START_R;
      5'd7: voice_commit_offset = OFF_LOOP_END;
      5'd8: voice_commit_offset = OFF_LOOP_END_R;
      5'd9: voice_commit_offset = OFF_PHASE_INIT;
      5'd10: voice_commit_offset = OFF_PHASE_INC;
      5'd11: voice_commit_offset = OFF_GAIN_L;
      5'd12: voice_commit_offset = OFF_GAIN_R;
      5'd13: voice_commit_offset = OFF_ENVELOPE;
      default: voice_commit_offset = OFF_VOICE_CTL;
    endcase
  endfunction

  always_comb begin
    commit_offset = (mode == MODE_VOICE) ?
                    voice_commit_offset(commit_seq) :
                    OFF_VOICE_CTL;
    commit_last_seq = (mode == MODE_VOICE) ?
                      (commit_seq == VOICE_COMMIT_LAST_SEQ[4:0]) :
                      (commit_seq == FILTER_UPDATE_LAST_SEQ[4:0]);

    busy = (state != COMMIT_IDLE) && (state != COMMIT_DONE);
    done = (state == COMMIT_DONE);
    descriptor_read_voice = commit_voice;
    descriptor_read_offset = commit_offset;

    active_config_write = (state == COMMIT_APPLY) && (mode == MODE_VOICE);
    active_config_write_voice = commit_voice;
    active_config_write_data = staged_config;
    active_config_valid_write = active_config_write;
    active_config_valid_data = (staged_config.length != '0) &&
                               (!staged_config.stereo || (staged_config.length_r != '0)) &&
                               ((staged_config.loop_mode == LOOP_MODE_NONE) ||
                                (((staged_config.loop_start < staged_config.loop_end) &&
                                  (staged_config.loop_end <= staged_config.length)) &&
                                 (!staged_config.stereo ||
                                  ((staged_config.loop_start_r < staged_config.loop_end_r) &&
                                   (staged_config.loop_end_r <= staged_config.length_r)))));

    runtime_write_voice = commit_voice;
    runtime_phase_write = (state == COMMIT_APPLY) && (mode == MODE_VOICE);
    runtime_gain_write = (state == COMMIT_APPLY) && (mode == MODE_VOICE);
    runtime_envelope_write = (state == COMMIT_APPLY) && (mode == MODE_VOICE);
    runtime_phase_write_data = staged_phase_inc;
    runtime_gain_write_data = {staged_gain_r, staged_gain_l};
    runtime_envelope_write_data = staged_envelope_level;
    runtime_release_clear = (state == COMMIT_APPLY) && (mode == MODE_VOICE);
    runtime_filter_write = (state == COMMIT_APPLY);
    runtime_filter_write_data = staged_filter_coeff;
    runtime_filter_enable_write = (state == COMMIT_APPLY);
    runtime_filter_enable_data = staged_filter_enable;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= COMMIT_IDLE;
      mode <= MODE_VOICE;
      commit_voice <= '0;
      commit_seq <= '0;
      commit_envelope_written <= 1'b0;
      staged_config <= '0;
      staged_config.loop_mode <= LOOP_MODE_NONE;
      staged_phase_inc <= '0;
      staged_gain_l <= '0;
      staged_gain_r <= '0;
      staged_envelope_level <= 16'sh7fff;
      staged_filter_enable <= 1'b0;
      staged_filter_coeff <= DEFAULT_FILTER_COEFF;
    end else begin
      unique case (state)
        COMMIT_IDLE: begin
          if (start) begin
            state <= COMMIT_READ;
            mode <= start_filter ? MODE_FILTER : MODE_VOICE;
            commit_voice <= start_voice;
            commit_seq <= '0;
            commit_envelope_written <= envelope_written;
            staged_config <= '0;
            staged_config.loop_mode <= LOOP_MODE_NONE;
            staged_phase_inc <= '0;
            staged_gain_l <= '0;
            staged_gain_r <= '0;
            staged_envelope_level <= 16'sh7fff;
            staged_filter_enable <= 1'b0;
            staged_filter_coeff <= DEFAULT_FILTER_COEFF;
          end
        end
        COMMIT_READ: begin
          state <= COMMIT_CAPTURE;
        end
        COMMIT_CAPTURE: begin
          unique case (commit_offset)
            OFF_VOICE_CTL: begin
              staged_config.stereo <= descriptor_read_data[REG_VOICE_CONTROL_STEREO_BIT];
              staged_config.loop_mode <= descriptor_read_data[
                REG_VOICE_CONTROL_LOOP_MODE_LSB +: REG_VOICE_CONTROL_LOOP_MODE_WIDTH
              ];
              staged_config.enable <= |(descriptor_read_data & REG_VOICE_CONTROL_ENABLE_MASK);
            end
            OFF_BASE:       staged_config.base_addr <= descriptor_read_data;
            OFF_BASE_R:     staged_config.base_addr_r <= descriptor_read_data;
            OFF_LENGTH:     staged_config.length <= descriptor_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_LENGTH_R:   staged_config.length_r <= descriptor_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_LOOP_START: staged_config.loop_start <= descriptor_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_LOOP_START_R: staged_config.loop_start_r <= descriptor_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_LOOP_END:   staged_config.loop_end <= descriptor_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_LOOP_END_R: staged_config.loop_end_r <= descriptor_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_PHASE_INIT: staged_config.phase_init <= descriptor_read_data;
            OFF_PHASE_INC:  staged_phase_inc <= descriptor_read_data;
            OFF_GAIN_L:     staged_gain_l <= $signed(descriptor_read_data[15:0]);
            OFF_GAIN_R:     staged_gain_r <= $signed(descriptor_read_data[15:0]);
            OFF_ENVELOPE:   staged_envelope_level <= commit_envelope_written ?
                                                   $signed(descriptor_read_data[15:0]) : 16'sh7fff;
            default: begin
            end
          endcase
          staged_filter_enable <= shadow_filter_enable;
          staged_filter_coeff <= shadow_filter_coeff;

          if (commit_last_seq) begin
            state <= COMMIT_APPLY;
          end else begin
            commit_seq <= commit_seq + 1'b1;
            state <= COMMIT_READ;
          end
        end
        COMMIT_APPLY: begin
          state <= COMMIT_DONE;
        end
        COMMIT_DONE: begin
          state <= COMMIT_IDLE;
        end
        default: begin
          state <= COMMIT_IDLE;
        end
      endcase
    end
  end
endmodule
