package synth_pkg;
  // Shared widths keep the audio, phase, and memory-address contracts in one
  // place. Modules import this package instead of repeating magic numbers.
  localparam int PCM_WIDTH = 16;
  localparam int PHASE_WIDTH = 32;
  localparam int ADDR_WIDTH = 32;
  localparam int NUM_VOICES = 32;

  localparam logic [1:0] LOOP_MODE_NONE = 2'd0;
  localparam logic [1:0] LOOP_MODE_CONTINUOUS = 2'd1;
  localparam logic [1:0] LOOP_MODE_UNTIL_RELEASE = 2'd2;

  // Signed 16-bit PCM is the external sample format used by wave memory and by
  // the produced audio stream.
  typedef logic signed [PCM_WIDTH-1:0] pcm_t;

  // One committed voice configuration. Position and increment are Q16.16 frame
  // units: the upper 16 bits select the sample frame, and the lower 16 bits are
  // the interpolation fraction between this frame and the next frame.
  typedef struct packed {
    logic                      enable;
    logic                      stereo;
    logic [ADDR_WIDTH-1:0]     base_addr;
    logic [15:0]               length;
    logic [15:0]               loop_start;
    logic [15:0]               loop_end;
    logic [PHASE_WIDTH-1:0]    phase_init;
    logic [PHASE_WIDTH-1:0]    phase_inc;
    logic signed [15:0]        gain_l;
    logic signed [15:0]        gain_r;
    logic signed [15:0]        envelope_level;
    logic [1:0]                loop_mode;
    logic                      released;
    logic                      filter_enable;
    logic [15:0]               filter_alpha;
  } voice_config_t;
endpackage
