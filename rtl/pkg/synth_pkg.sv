package synth_pkg;
  localparam int PCM_WIDTH = 16;
  localparam int PHASE_WIDTH = 32;
  localparam int ADDR_WIDTH = 32;

  typedef logic signed [PCM_WIDTH-1:0] pcm_t;

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
  } voice_config_t;
endpackage
