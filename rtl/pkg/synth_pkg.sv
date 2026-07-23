package synth_pkg;
  // Shared widths keep the audio, phase, and memory-address contracts in one
  // place. Modules import this package instead of repeating magic numbers.
  localparam int PCM_WIDTH = 16;
  localparam int PHASE_FRAME_WIDTH = 24;
  localparam int PHASE_FRAC_WIDTH = 8;
  localparam int PHASE_WIDTH = PHASE_FRAME_WIDTH + PHASE_FRAC_WIDTH;
  localparam int ADDR_WIDTH = 32;
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
  localparam int STREAM_ID_WIDTH = 1;
  /* verilator lint_off UNUSEDPARAM */
  localparam int ENV_EVENT_WIDTH = 128;
  localparam int ENV_EVENT_OPCODE_WIDTH = 8;
  localparam int ENV_CB_WIDTH = 24;
  localparam int ENV_GAIN_Q23_WIDTH = 24;
  /* verilator lint_on UNUSEDPARAM */

  /* verilator lint_off UNUSEDPARAM */
  localparam logic [STREAM_ID_WIDTH-1:0] STREAM_LEFT = 1'b0;
  localparam logic [STREAM_ID_WIDTH-1:0] STREAM_RIGHT = 1'b1;
  localparam logic [1:0] LOOP_MODE_NONE = 2'd0;
  localparam logic [1:0] LOOP_MODE_CONTINUOUS = 2'd1;
  localparam logic [1:0] LOOP_MODE_UNTIL_RELEASE = 2'd2;
  /* verilator lint_on UNUSEDPARAM */

  // Signed 16-bit PCM is the external sample format used by wave memory and by
  // the produced audio stream.
  typedef logic signed [PCM_WIDTH-1:0] pcm_t;
  typedef logic signed [FILTER_SAMPLE_WIDTH-1:0] filter_sample_t;

  typedef struct packed {
    pcm_t l;
    pcm_t r;
  } stereo_pcm_t;

  typedef struct packed {
    logic                       valid;
    logic [VOICE_ID_WIDTH-1:0]  voice;
    logic [STREAM_ID_WIDTH-1:0] stream_id;
    logic [ADDR_WIDTH-1:0]      addr;
  } wave_word_req_t;

  typedef struct packed {
    logic valid;
    pcm_t data;
  } wave_word_rsp_t;

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

  typedef enum logic [ENV_EVENT_OPCODE_WIDTH-1:0] {
    EVT_ENV_SET        = 8'd1,
    EVT_VOL_ATTACK     = 8'd2,
    EVT_VOL_DECAY_CB   = 8'd3,
    EVT_VOL_RELEASE_CB = 8'd4,
    EVT_RELEASE_FLAG   = 8'd5,
    EVT_STOP_VOICE     = 8'd6
  } envelope_event_opcode_t;

  typedef struct packed {
    logic [31:0]                         timestamp;
    logic [15:0]                         payload0;
    envelope_event_opcode_t              opcode;
    logic [7:0]                          voice;
    logic [31:0]                         payload1;
    logic [31:0]                         payload2;
  } envelope_event_t;

  typedef struct packed {
    logic signed [15:0] l;
    logic signed [15:0] r;
  } stereo_gain_t;

  typedef struct packed {
    logic signed [FILTER_COEFF_WIDTH-1:0] b0;
    logic signed [FILTER_COEFF_WIDTH-1:0] b1;
    logic signed [FILTER_COEFF_WIDTH-1:0] b2;
    logic signed [FILTER_COEFF_WIDTH-1:0] a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] a2;
  } biquad_coeff_t;

  typedef struct packed {
    logic signed [FILTER_STATE_WIDTH-1:0] z1_l;
    logic signed [FILTER_STATE_WIDTH-1:0] z2_l;
    logic signed [FILTER_STATE_WIDTH-1:0] z1_r;
    logic signed [FILTER_STATE_WIDTH-1:0] z2_r;
  } stereo_biquad_state_t;

  // One committed voice configuration. These fields describe the sample region
  // and static playback mode that must become visible atomically on voice commit.
  typedef struct packed {
    logic                      enable;
    logic                      stereo;
    logic [ADDR_WIDTH-1:0]     base_addr;
    logic [ADDR_WIDTH-1:0]     base_addr_r;
    logic [PHASE_FRAME_WIDTH-1:0] length;
    logic [PHASE_FRAME_WIDTH-1:0] length_r;
    logic [PHASE_FRAME_WIDTH-1:0] loop_start;
    logic [PHASE_FRAME_WIDTH-1:0] loop_start_r;
    logic [PHASE_FRAME_WIDTH-1:0] loop_end;
    logic [PHASE_FRAME_WIDTH-1:0] loop_end_r;
    logic [PHASE_WIDTH-1:0]    phase_init;
    logic [1:0]                loop_mode;
  } voice_config_t;

  // Software-visible shadow state. Runtime-owned fields are copied from here on
  // voice commit, but the renderer reads them through voice_runtime_t.
  typedef struct packed {
    logic                      enable;
    logic                      stereo;
    logic [ADDR_WIDTH-1:0]     base_addr;
    logic [ADDR_WIDTH-1:0]     base_addr_r;
    logic [PHASE_FRAME_WIDTH-1:0] length;
    logic [PHASE_FRAME_WIDTH-1:0] length_r;
    logic [PHASE_FRAME_WIDTH-1:0] loop_start;
    logic [PHASE_FRAME_WIDTH-1:0] loop_start_r;
    logic [PHASE_FRAME_WIDTH-1:0] loop_end;
    logic [PHASE_FRAME_WIDTH-1:0] loop_end_r;
    logic [PHASE_WIDTH-1:0]    phase_init;
    logic [PHASE_WIDTH-1:0]    phase_inc;
    logic signed [15:0]        gain_l;
    logic signed [15:0]        gain_r;
    logic [1:0]                loop_mode;
    logic                      filter_enable;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b0;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b2;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
  } voice_shadow_t;

  // Runtime control state. These fields may be updated while a voice is playing
  // and do not reload phase. The renderer snapshots them at output-frame start.
  typedef struct packed {
    logic [PHASE_WIDTH-1:0]    phase_inc;
    logic signed [15:0]        gain_l;
    logic signed [15:0]        gain_r;
    logic signed [15:0]        envelope_level;
    logic                      released;
    logic                      filter_enable;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b0;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b2;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
  } voice_runtime_t;

  typedef struct packed {
    logic [VOICE_ID_WIDTH-1:0]    voice_index;
    logic                        filter_enable;
    logic signed [15:0]          gain_l;
    logic signed [15:0]          gain_r;
    logic signed [15:0]          envelope_level;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b0;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_b2;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a1;
    logic signed [FILTER_COEFF_WIDTH-1:0] filter_a2;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_l;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_l;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_r;
    logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_r;
    logic [PHASE_FRAC_WIDTH-1:0] fraction;
    pcm_t                        raw_l0;
    pcm_t                        raw_l1;
    pcm_t                        raw_r0;
    pcm_t                        raw_r1;
  } voice_dsp_context_t;

  typedef struct packed {
    logic [VOICE_ID_WIDTH-1:0]    voice_index;
    logic                        filter_enable;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z1_l;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z2_l;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z1_r;
    logic signed [FILTER_STATE_WIDTH-1:0] next_z2_r;
    pcm_t                        contribution_l;
    pcm_t                        contribution_r;
  } voice_dsp_result_t;
endpackage
