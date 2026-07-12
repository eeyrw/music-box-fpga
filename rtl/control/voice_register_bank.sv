module voice_register_bank (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       bus_valid,
  input  logic                       bus_write,
  input  logic [15:0]                bus_address,
  input  logic [31:0]                bus_wdata,
  output logic [31:0]                bus_rdata,
  output logic                       bus_ready,
  output logic                       bus_error,
  output synth_pkg::voice_config_t   active_config [synth_pkg::NUM_VOICES],
  output synth_pkg::voice_runtime_t  runtime_state [synth_pkg::NUM_VOICES],
  output logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0] commit_pulse
);
  import synth_pkg::*;

  // Byte addresses for the simple 32-bit register bus. Configuration writes
  // update shadow_config first; only OFF_COMMIT copies that state into the
  // active_config observed by the playback pipeline. Runtime registers update
  // runtime_state and never reload phase.
  localparam logic [15:0] VOICE_BASE      = 16'h0100;
  localparam logic [15:0] VOICE_STRIDE    = 16'h0080;
  localparam logic [15:0] VOICE_LIMIT     = 16'(NUM_VOICES * VOICE_STRIDE);
  localparam logic [15:0] OFF_CONTROL     = 16'h0000;
  localparam logic [15:0] OFF_BASE        = 16'h0004;
  localparam logic [15:0] OFF_LENGTH      = 16'h0008;
  localparam logic [15:0] OFF_LOOP_START  = 16'h000c;
  localparam logic [15:0] OFF_LOOP_END    = 16'h0010;
  localparam logic [15:0] OFF_PHASE_INIT  = 16'h0014;
  localparam logic [15:0] OFF_PHASE_INC   = 16'h0018;
  localparam logic [15:0] OFF_GAIN_L      = 16'h001c;
  localparam logic [15:0] OFF_GAIN_R      = 16'h0020;
  localparam logic [15:0] OFF_COMMIT      = 16'h0024;
  localparam logic [15:0] OFF_STATUS      = 16'h0028;
  localparam logic [15:0] OFF_ENVELOPE    = 16'h002c;
  localparam logic [15:0] OFF_PHASE_RT    = 16'h0030;
  localparam logic [15:0] OFF_LOOP_MODE   = 16'h0034;
  localparam logic [15:0] OFF_FILTER_CTL  = 16'h0038;
  localparam logic [15:0] OFF_FILTER_B0   = 16'h003c;
  localparam logic [15:0] OFF_FILTER_B1   = 16'h0040;
  localparam logic [15:0] OFF_FILTER_B2   = 16'h0044;
  localparam logic [15:0] OFF_FILTER_A1   = 16'h0048;
  localparam logic [15:0] OFF_FILTER_A2   = 16'h004c;
  localparam logic [15:0] OFF_GAIN_RT     = 16'h0050;
  localparam logic [15:0] OFF_RELEASE     = 16'h0054;
  localparam logic [15:0] OFF_BASE_R      = 16'h0058;
  localparam logic [15:0] ADDR_VERSION    = 16'h3000;

  localparam int VOICE_INDEX_WIDTH = $clog2(NUM_VOICES);

  voice_config_t shadow_config [NUM_VOICES];
  logic address_valid;
  logic voice_address;
  logic [VOICE_INDEX_WIDTH-1:0] selected_voice;
  logic [15:0] selected_offset;
  logic [15:0] voice_relative;
  int i;

  always_comb begin
    for (int v = 0; v < NUM_VOICES; v++) begin
      // A committed voice is playable when it has a nonzero length. Looping
      // modes additionally require a non-empty loop range inside the length.
      config_valid[v] = (active_config[v].length != 16'd0) &&
                        ((active_config[v].loop_mode == LOOP_MODE_NONE) ||
                         ((active_config[v].loop_start < active_config[v].loop_end) &&
                          (active_config[v].loop_end <= active_config[v].length)));
    end

    voice_relative = bus_address - VOICE_BASE;
    selected_voice = voice_relative[7 +: VOICE_INDEX_WIDTH];
    selected_offset = {9'd0, voice_relative[6:0]};
    voice_address = (bus_address >= VOICE_BASE) &&
                    (voice_relative < VOICE_LIMIT);

    // Reads return shadow state so software can verify pending writes before it
    // commits them. STATUS and ENVELOPE_LEVEL describe active runtime state.
    address_valid = voice_address || (bus_address == ADDR_VERSION);
    bus_rdata = 32'd0;
    if (voice_address) begin
      unique case (selected_offset)
        OFF_CONTROL:    bus_rdata = {30'd0, shadow_config[selected_voice].stereo, shadow_config[selected_voice].enable};
        OFF_BASE:       bus_rdata = shadow_config[selected_voice].base_addr;
        OFF_LENGTH:     bus_rdata = {16'd0, shadow_config[selected_voice].length};
        OFF_LOOP_START: bus_rdata = {16'd0, shadow_config[selected_voice].loop_start};
        OFF_LOOP_END:   bus_rdata = {16'd0, shadow_config[selected_voice].loop_end};
        OFF_PHASE_INIT: bus_rdata = shadow_config[selected_voice].phase_init;
        OFF_PHASE_INC:  bus_rdata = shadow_config[selected_voice].phase_inc;
        OFF_GAIN_L:     bus_rdata = {{16{shadow_config[selected_voice].gain_l[15]}}, shadow_config[selected_voice].gain_l};
        OFF_GAIN_R:     bus_rdata = {{16{shadow_config[selected_voice].gain_r[15]}}, shadow_config[selected_voice].gain_r};
        OFF_COMMIT:     bus_rdata = 32'd0;
        OFF_STATUS:     bus_rdata = {31'd0, config_valid[selected_voice]};
        OFF_ENVELOPE:   bus_rdata = {{16{runtime_state[selected_voice].envelope_level[15]}}, runtime_state[selected_voice].envelope_level};
        OFF_PHASE_RT:   bus_rdata = runtime_state[selected_voice].phase_inc;
        OFF_LOOP_MODE:  bus_rdata = {30'd0, shadow_config[selected_voice].loop_mode};
        OFF_FILTER_CTL:  bus_rdata = {31'd0, shadow_config[selected_voice].filter_enable};
        OFF_FILTER_B0:   bus_rdata = shadow_config[selected_voice].filter_b0;
        OFF_FILTER_B1:   bus_rdata = shadow_config[selected_voice].filter_b1;
        OFF_FILTER_B2:   bus_rdata = shadow_config[selected_voice].filter_b2;
        OFF_FILTER_A1:   bus_rdata = shadow_config[selected_voice].filter_a1;
        OFF_FILTER_A2:   bus_rdata = shadow_config[selected_voice].filter_a2;
        OFF_GAIN_RT:     bus_rdata = {runtime_state[selected_voice].gain_r, runtime_state[selected_voice].gain_l};
        OFF_RELEASE:     bus_rdata = {31'd0, runtime_state[selected_voice].released};
        OFF_BASE_R:      bus_rdata = shadow_config[selected_voice].base_addr_r;
        default: begin
          address_valid = 1'b0;
          bus_rdata = 32'd0;
        end
      endcase
    end else if (bus_address == ADDR_VERSION) begin
      bus_rdata = 32'h0004_0000;
    end

    // This bus is deliberately single-cycle in simulation: a valid address is
    // ready immediately, and invalid addresses report an error on the same beat.
    bus_ready = bus_valid;
    bus_error = bus_valid && !address_valid;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < NUM_VOICES; i++) begin
        shadow_config[i] <= '0;
        shadow_config[i].loop_mode <= LOOP_MODE_NONE;
        shadow_config[i].filter_b0 <= 32'sh1000_0000;
        shadow_config[i].filter_b1 <= 32'sh0000_0000;
        shadow_config[i].filter_b2 <= 32'sh0000_0000;
        shadow_config[i].filter_a1 <= 32'sh0000_0000;
        shadow_config[i].filter_a2 <= 32'sh0000_0000;
        active_config[i] <= '0;
        active_config[i].loop_mode <= LOOP_MODE_NONE;
        active_config[i].filter_b0 <= 32'sh1000_0000;
        active_config[i].filter_b1 <= 32'sh0000_0000;
        active_config[i].filter_b2 <= 32'sh0000_0000;
        active_config[i].filter_a1 <= 32'sh0000_0000;
        active_config[i].filter_a2 <= 32'sh0000_0000;
        runtime_state[i] <= '0;
        runtime_state[i].envelope_level <= 16'sh7fff;
        runtime_state[i].filter_b0 <= 32'sh1000_0000;
        runtime_state[i].filter_b1 <= 32'sh0000_0000;
        runtime_state[i].filter_b2 <= 32'sh0000_0000;
        runtime_state[i].filter_a1 <= 32'sh0000_0000;
        runtime_state[i].filter_a2 <= 32'sh0000_0000;
      end
      commit_pulse <= '0;
    end else begin
      // commit_pulse is a one-cycle event used to reload voice runtime phase.
      commit_pulse <= '0;
      if (bus_valid && bus_write && voice_address) begin
        unique case (selected_offset)
          OFF_CONTROL: begin
            shadow_config[selected_voice].enable <= bus_wdata[0];
            shadow_config[selected_voice].stereo <= bus_wdata[1];
          end
          OFF_BASE:       shadow_config[selected_voice].base_addr <= bus_wdata;
          OFF_BASE_R:     shadow_config[selected_voice].base_addr_r <= bus_wdata;
          OFF_LENGTH:     shadow_config[selected_voice].length <= bus_wdata[15:0];
          OFF_LOOP_START: shadow_config[selected_voice].loop_start <= bus_wdata[15:0];
          OFF_LOOP_END:   shadow_config[selected_voice].loop_end <= bus_wdata[15:0];
          OFF_PHASE_INIT: shadow_config[selected_voice].phase_init <= bus_wdata;
          OFF_PHASE_INC:  shadow_config[selected_voice].phase_inc <= bus_wdata;
          OFF_GAIN_L:     shadow_config[selected_voice].gain_l <= $signed(bus_wdata[15:0]);
          OFF_GAIN_R:     shadow_config[selected_voice].gain_r <= $signed(bus_wdata[15:0]);
          OFF_ENVELOPE: begin
            // Envelope is runtime state owned by the MCU/control layer. Updating
            // it must not reload phase or disturb in-flight note playback.
            runtime_state[selected_voice].envelope_level <= $signed(bus_wdata[15:0]);
          end
          OFF_COMMIT: begin
            // Commit is atomic at the voice-config granularity: partially
            // written shadow fields do not affect playback until this write.
            if (bus_wdata[0]) begin
              active_config[selected_voice] <= shadow_config[selected_voice];
              runtime_state[selected_voice].phase_inc <= shadow_config[selected_voice].phase_inc;
              runtime_state[selected_voice].gain_l <= shadow_config[selected_voice].gain_l;
              runtime_state[selected_voice].gain_r <= shadow_config[selected_voice].gain_r;
              runtime_state[selected_voice].released <= 1'b0;
              runtime_state[selected_voice].filter_enable <= shadow_config[selected_voice].filter_enable;
              runtime_state[selected_voice].filter_b0 <= shadow_config[selected_voice].filter_b0;
              runtime_state[selected_voice].filter_b1 <= shadow_config[selected_voice].filter_b1;
              runtime_state[selected_voice].filter_b2 <= shadow_config[selected_voice].filter_b2;
              runtime_state[selected_voice].filter_a1 <= shadow_config[selected_voice].filter_a1;
              runtime_state[selected_voice].filter_a2 <= shadow_config[selected_voice].filter_a2;
              commit_pulse[selected_voice] <= 1'b1;
            end
          end
          OFF_PHASE_RT: begin
            runtime_state[selected_voice].phase_inc <= bus_wdata;
          end
          OFF_LOOP_MODE: begin
            shadow_config[selected_voice].loop_mode <= bus_wdata[1:0];
          end
          OFF_FILTER_CTL: begin
            shadow_config[selected_voice].filter_enable <= bus_wdata[0];
            runtime_state[selected_voice].filter_enable <= bus_wdata[0];
          end
          OFF_FILTER_B0: begin shadow_config[selected_voice].filter_b0 <= $signed(bus_wdata); runtime_state[selected_voice].filter_b0 <= $signed(bus_wdata); end
          OFF_FILTER_B1: begin shadow_config[selected_voice].filter_b1 <= $signed(bus_wdata); runtime_state[selected_voice].filter_b1 <= $signed(bus_wdata); end
          OFF_FILTER_B2: begin shadow_config[selected_voice].filter_b2 <= $signed(bus_wdata); runtime_state[selected_voice].filter_b2 <= $signed(bus_wdata); end
          OFF_FILTER_A1: begin shadow_config[selected_voice].filter_a1 <= $signed(bus_wdata); runtime_state[selected_voice].filter_a1 <= $signed(bus_wdata); end
          OFF_FILTER_A2: begin shadow_config[selected_voice].filter_a2 <= $signed(bus_wdata); runtime_state[selected_voice].filter_a2 <= $signed(bus_wdata); end
          OFF_GAIN_RT: begin
            runtime_state[selected_voice].gain_l <= $signed(bus_wdata[15:0]);
            runtime_state[selected_voice].gain_r <= $signed(bus_wdata[31:16]);
          end
          OFF_RELEASE: begin
            runtime_state[selected_voice].released <= bus_wdata[0];
          end
          default: begin
          end
        endcase
      end
    end
  end
endmodule
