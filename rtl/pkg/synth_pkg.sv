package synth_pkg;
  // Shared widths keep the audio, phase, and memory-address contracts in one
  // place. Modules import this package instead of repeating magic numbers.
  localparam int PCM_WIDTH = 16;
  localparam int PHASE_WIDTH = 32;
  localparam int ADDR_WIDTH = 32;
`ifdef SYNTH_NUM_VOICES
  localparam int NUM_VOICES = `SYNTH_NUM_VOICES;
`else
  localparam int NUM_VOICES = 32;
`endif

  localparam logic [1:0] LOOP_MODE_NONE = 2'd0;
  localparam logic [1:0] LOOP_MODE_CONTINUOUS = 2'd1;
  localparam logic [1:0] LOOP_MODE_UNTIL_RELEASE = 2'd2;

  // Signed 16-bit PCM is the external sample format used by wave memory and by
  // the produced audio stream.
  typedef logic signed [PCM_WIDTH-1:0] pcm_t;

  // One committed voice configuration. These fields describe the sample region
  // and initial playback state that must become visible atomically on COMMIT.
  typedef struct packed {
    logic                      enable;
    logic                      stereo;
    logic [ADDR_WIDTH-1:0]     base_addr;
    logic [ADDR_WIDTH-1:0]     base_addr_r;
    logic [15:0]               length;
    logic [15:0]               loop_start;
    logic [15:0]               loop_end;
    logic [PHASE_WIDTH-1:0]    phase_init;
    logic [PHASE_WIDTH-1:0]    phase_inc;
    logic signed [15:0]        gain_l;
    logic signed [15:0]        gain_r;
    logic [1:0]                loop_mode;
    logic                      filter_enable;
    logic signed [31:0]        filter_b0;
    logic signed [31:0]        filter_b1;
    logic signed [31:0]        filter_b2;
    logic signed [31:0]        filter_a1;
    logic signed [31:0]        filter_a2;
  } voice_config_t;

  // Runtime control state. These fields may be updated while a voice is playing
  // and do not reload phase. The renderer snapshots them at output-frame start.
  typedef struct packed {
    logic [PHASE_WIDTH-1:0]    phase_inc;
    logic signed [15:0]        gain_l;
    logic signed [15:0]        gain_r;
    logic signed [15:0]        envelope_level;
    logic                      released;
    logic                      filter_enable;
    logic signed [31:0]        filter_b0;
    logic signed [31:0]        filter_b1;
    logic signed [31:0]        filter_b2;
    logic signed [31:0]        filter_a1;
    logic signed [31:0]        filter_a2;
  } voice_runtime_t;
endpackage
