package synth_pkg;
  // Shared widths keep the audio, phase, and memory-address contracts in one
  // place. Modules import this package instead of repeating magic numbers.
  localparam int PCM_WIDTH = 16;
  localparam int MIX_WIDTH = 24;
  localparam int PHASE_FRAME_WIDTH = 24;
  localparam int PHASE_FRAC_WIDTH = 8;
  localparam int PHASE_WIDTH = PHASE_FRAME_WIDTH + PHASE_FRAC_WIDTH;
  localparam int ADDR_WIDTH = 32;
  localparam int TIMELINE_FRAME_WIDTH = 32;
`ifdef SYNTH_MAX_BLOCK_FRAMES
  localparam int MAX_BLOCK_FRAMES = `SYNTH_MAX_BLOCK_FRAMES;
`else
  localparam int MAX_BLOCK_FRAMES = 8;
`endif
  localparam int BLOCK_FRAME_INDEX_WIDTH = $clog2(MAX_BLOCK_FRAMES);
  localparam int BLOCK_FRAME_COUNT_WIDTH = $clog2(MAX_BLOCK_FRAMES + 1);
  localparam int BLOCK_BUFFER_ID_WIDTH = 1;
  localparam int VOICE_GENERATION_WIDTH = 16;
  localparam int BLOCK_ENDPOINT_COUNT = 2;
  localparam int BLOCK_LINE_WORDS = 8;
  localparam int BLOCK_ENDPOINT_SCRATCH_COUNT =
      MAX_BLOCK_FRAMES * BLOCK_ENDPOINT_COUNT;
  // Eight independent block contexts cover the five-cycle recursive-filter
  // feedback distance while keeping the slot ID and round-robin wrap binary.
  localparam int BLOCK_WORK_ENTRY_COUNT = 8;
  localparam int BLOCK_WORK_ID_WIDTH = $clog2(BLOCK_WORK_ENTRY_COUNT);
  /* verilator lint_off UNUSEDPARAM */
  localparam int FILTER_COEFF_WIDTH = 16;
  localparam int FILTER_COEFF_FRAC_WIDTH = 14;
  localparam int FILTER_SAMPLE_WIDTH = 20;
  localparam int FILTER_STATE_WIDTH = 34;
  localparam int FILTER_RAW_WIDTH = 38;
  /* verilator lint_on UNUSEDPARAM */
`ifdef SYNTH_NUM_VOICES
  localparam int NUM_VOICES = `SYNTH_NUM_VOICES;
`else
  localparam int NUM_VOICES = 32;
`endif
  localparam int VOICE_ID_WIDTH = $clog2(NUM_VOICES);
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [1:0] LOOP_MODE_NONE = 2'd0;
  localparam logic [1:0] LOOP_MODE_CONTINUOUS = 2'd1;
  localparam logic [1:0] LOOP_MODE_UNTIL_RELEASE = 2'd2;
  /* verilator lint_on UNUSEDPARAM */

  // Signed 16-bit PCM is the external sample format used by wave memory and by
  // the produced audio stream.
  typedef logic signed [PCM_WIDTH-1:0] pcm_t;
  typedef logic signed [MIX_WIDTH-1:0] mix_t;
  typedef logic signed [31:0] accum_t;
  typedef logic signed [FILTER_SAMPLE_WIDTH-1:0] filter_sample_t;

  typedef struct packed {
    pcm_t l;
    pcm_t r;
  } stereo_pcm_t;

  typedef struct packed {
    mix_t l;
    mix_t r;
  } stereo_mix_t;

  typedef struct packed {
    accum_t l;
    accum_t r;
  } stereo_accum_t;

  // The block-renderer payload types exclude ready/valid so ownership and
  // backpressure remain explicit at module boundaries. frame_count is
  // 1..MAX_BLOCK_FRAMES.
  typedef struct packed {
    logic [TIMELINE_FRAME_WIDTH-1:0] start_frame;
    logic [BLOCK_FRAME_COUNT_WIDTH-1:0] frame_count;
  } render_block_req_t;

  typedef struct packed {
    logic [BLOCK_BUFFER_ID_WIDTH-1:0] buffer_id;
    logic [TIMELINE_FRAME_WIDTH-1:0] start_frame;
    logic [BLOCK_FRAME_COUNT_WIDTH-1:0] frame_count;
  } render_block_complete_t;

  typedef struct packed {
    logic [BLOCK_BUFFER_ID_WIDTH-1:0] buffer_id;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] frame_index;
  } render_block_read_req_t;

  typedef struct packed {
    stereo_mix_t sample;
  } render_block_read_rsp_t;

  typedef struct packed {
    logic [VOICE_GENERATION_WIDTH-1:0] generation;
    logic [VOICE_ID_WIDTH-1:0] voice_index;
    logic signed [15:0] gain_l;
    logic signed [15:0] gain_r;
    logic filter_enable;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b0;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b2;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
  } block_voice_context_t;

  // Endpoint bits are {sample_1, sample_0}. Every renderer voice owns exactly
  // one mono sample lane; stereo pairs are represented by two host-owned voices.
  typedef struct packed {
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] block_frame_index;
    logic [PHASE_FRAC_WIDTH-1:0] fraction;
    logic [BLOCK_ENDPOINT_COUNT-1:0] endpoint_mask;
    logic [BLOCK_ENDPOINT_COUNT-1:0][ADDR_WIDTH-1:0] endpoint_addr;
    logic signed [15:0] envelope_level;
  } block_endpoint_job_t;

  typedef struct packed {
    logic [ADDR_WIDTH-1:0] base_word_addr;
    logic [BLOCK_ENDPOINT_SCRATCH_COUNT-1:0] endpoint_mask;
  } block_fetch_segment_t;

  typedef struct packed {
    block_endpoint_job_t job;
    pcm_t sample_0;
    pcm_t sample_1;
  } block_sample_job_t;

  typedef struct packed {
    logic [VOICE_GENERATION_WIDTH-1:0] generation;
    logic [VOICE_ID_WIDTH-1:0] voice_index;
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] block_frame_index;
    pcm_t contribution_l;
    pcm_t contribution_r;
  } block_voice_contribution_t;

  // The board-facing response is ordered and therefore carries no transaction
  // ID. The burst reader's issued-segment FIFO owns response association.
  typedef struct packed {
    logic [ADDR_WIDTH-1:0] aligned_line_addr;
  } ordered_line_req_t;

  typedef struct packed {
    logic [BLOCK_LINE_WORDS-1:0][PCM_WIDTH-1:0] words;
  } ordered_line_rsp_t;

  typedef struct packed {
    logic [VOICE_GENERATION_WIDTH-1:0] generation;
    logic active;
    logic [PHASE_WIDTH-1:0] phase;
    logic [BLOCK_FRAME_COUNT_WIDTH-1:0] frames_walked;
  } block_phase_result_t;

  typedef struct packed {
    block_phase_result_t phase_result;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } block_voice_dsp_result_t;

  typedef struct packed {
    logic [BLOCK_WORK_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_context_t voice_context;
    block_sample_job_t sample;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } block_dsp_sample_token_t;

  typedef struct packed {
    logic [BLOCK_WORK_ID_WIDTH-1:0] work_id;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } block_dsp_state_update_t;

  typedef struct packed {
    logic [BLOCK_WORK_ID_WIDTH-1:0] work_id;
    logic last;
    block_voice_contribution_t contribution;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } block_dsp_retire_t;

  typedef struct packed {
    logic        valid;
    logic        write;
    logic [15:0] address;
    logic [31:0] wdata;
  } reg_bus_req_t;

  typedef struct packed {
    logic [31:0] rdata;
    logic        ready;
    logic        error;
  } reg_bus_rsp_t;

  typedef struct packed {
    logic        enable;
    logic [31:0] threshold_cb_q12_20;
    logic [15:0] ratio_slope_q0_16;
    logic [31:0] attack_step_cb_q12_20;
    logic [31:0] release_step_cb_q12_20;
  } compressor_config_t;

  typedef struct packed {
    logic               enable;
    logic [23:0]        base_delay_q16_8;
    logic [23:0]        depth_q16_8;
    logic [31:0]        lfo_phase_inc_q0_32;
    logic [15:0]        input_send_q1_15;
    logic [15:0]        return_gain_q1_15;
    logic signed [15:0] feedback_q1_15;
    logic [31:0]        stereo_phase_offset_q0_32;
  } chorus_config_t;

  typedef struct packed {
    logic             enable;
    logic [15:0]      input_send_q1_15;
    logic [15:0]      return_gain_q1_15;
    logic [15:0]      damping_q1_15;
    logic [15:0]      chorus_to_reverb_q1_15;
    logic [10:0]      pre_delay_frames;
    logic [7:0][15:0] feedback_gain_q1_15;
  } reverb_config_t;

  typedef struct packed {
    compressor_config_t compressor;
    logic signed [15:0] master_volume;
    chorus_config_t     chorus;
    reverb_config_t     reverb;
  } global_audio_config_t;

  typedef struct packed {
    logic        chorus_enabled;
    logic        reverb_enabled;
    logic        busy;
    logic        chorus_config_clamped;
    logic        reverb_config_clamped;
    logic        mixer_config_clamped;
    logic [15:0] chorus_history_level_frames;
    logic [31:0] chorus_lfo_phase_q0_32;
    logic [7:0]  reverb_valid_line_mask;
    logic [15:0] reverb_pre_delay_occupancy;
    logic [31:0] input_frame_count;
    logic [31:0] output_frame_count;
    logic [15:0] max_processing_cycles;
    logic [31:0] chorus_saturation_count;
    logic [31:0] reverb_saturation_count;
    logic [31:0] mixer_saturation_count;
    logic [15:0] reverb_max_processing_cycles;
  } spatial_effect_diagnostics_t;

  typedef struct packed {
    logic                 enabled;
    logic                 primed;
    logic [15:0]          delay_level_frames;
    logic [31:0]          gain_reduction_cb_q12_20;
    logic [31:0]          target_gain_reduction_cb_q12_20;
    logic [MIX_WIDTH-1:0] detector_peak;
    logic [31:0]          max_gain_reduction_cb_q12_20;
    logic [MIX_WIDTH-1:0] max_detector_peak;
    logic [31:0]          input_frame_count;
    logic [31:0]          output_frame_count;
    logic [31:0]          compressed_frame_count;
    logic [31:0]          saturation_count;
  } compressor_diagnostics_t;

  typedef struct packed {
    spatial_effect_diagnostics_t effects;
    compressor_diagnostics_t     compressor;
  } audio_diagnostics_t;

  typedef enum logic [2:0] {
    ENV_DELAY,
    ENV_ATTACK,
    ENV_HOLD,
    ENV_DECAY,
    ENV_SUSTAIN,
    ENV_RELEASE
  } volume_env_stage_t;

  typedef struct packed {
    logic [23:0] delay_samples;
    logic [31:0] attack_step_q0_32;
    logic [23:0] hold_samples;
    logic [31:0] decay_step_cb_q12_20;
    logic [31:0] sustain_cb_q12_20;
    logic [31:0] release_step_cb_q12_20;
  } volume_env_params_t;

  typedef struct packed {
    volume_env_stage_t stage;
    logic [23:0] elapsed;
    logic [31:0] attack_level_q0_32;
    logic [31:0] attenuation_cb_q12_20;
  } volume_env_state_t;

  typedef struct packed {
    logic active;
    volume_env_state_t env_state;
    logic [MAX_BLOCK_FRAMES-1:0] phase_advance_mask;
    logic [MAX_BLOCK_FRAMES-1:0] render_mask;
    logic signed [MAX_BLOCK_FRAMES-1:0][15:0] envelope_levels;
  } block_envelope_result_t;

  // Block-renderer state is split by ownership and update frequency.
  typedef struct packed {
    logic [ADDR_WIDTH-1:0] base_addr;
    logic [PHASE_FRAME_WIDTH-1:0] length;
    logic [PHASE_FRAME_WIDTH-1:0] loop_start;
    logic [PHASE_FRAME_WIDTH-1:0] loop_end;
    logic [1:0] loop_mode;
  } voice_playback_region_t;

  typedef struct packed {
    voice_playback_region_t region;
    logic [PHASE_WIDTH-1:0] phase_init;
  } voice_descriptor_state_t;

  typedef struct packed {
    logic [PHASE_WIDTH-1:0] phase_inc;
    logic signed [15:0] gain_l;
    logic signed [15:0] gain_r;
    logic released;
    logic filter_enable;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b0;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b2;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
  } voice_event_params_t;

  typedef struct packed {
    logic active;
    logic [VOICE_GENERATION_WIDTH-1:0] generation;
    logic [PHASE_WIDTH-1:0] phase;
    volume_env_state_t env_state;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2;
  } voice_dynamic_state_t;

  typedef struct packed {
    voice_playback_region_t region;
    voice_event_params_t event_params;
    volume_env_params_t env_params;
    voice_dynamic_state_t dynamic;
  } block_voice_state_snapshot_t;

  // Control events are decoded, timestamped transactions.
  typedef enum logic [2:0] {
    BLOCK_VOICE_START,
    BLOCK_VOICE_STOP,
    BLOCK_VOICE_RELEASE,
    BLOCK_VOICE_GAIN,
    BLOCK_VOICE_PITCH,
    BLOCK_VOICE_FILTER,
    BLOCK_VOICE_ENV
  } block_voice_event_kind_t;

  typedef struct packed {
    logic [TIMELINE_FRAME_WIDTH-1:0] target_frame;
    logic [15:0] host_voice_id;
    logic [VOICE_GENERATION_WIDTH-1:0] generation;
    block_voice_event_kind_t kind;
    voice_descriptor_state_t descriptor;
    voice_event_params_t event_params;
    volume_env_params_t env_params;
    volume_env_state_t start_env_state;
  } block_voice_event_t;

  typedef enum logic [1:0] {
    BLOCK_EVENT_APPLIED,
    BLOCK_EVENT_STALE,
    BLOCK_EVENT_BAD_VOICE,
    BLOCK_EVENT_BAD_TIME
  } block_voice_event_status_t;

  typedef struct packed {
    logic [TIMELINE_FRAME_WIDTH-1:0] target_frame;
    logic [15:0] host_voice_id;
    logic [VOICE_GENERATION_WIDTH-1:0] generation;
    block_voice_event_kind_t kind;
    block_voice_event_status_t status;
  } block_voice_event_result_t;

endpackage
