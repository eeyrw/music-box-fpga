module voice_register_bank (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       bus_valid,
  input  logic                       bus_write,
  input  logic [15:0]                bus_address,
  input  logic [31:0]                bus_wdata,
  input  logic                       frame_boundary,
  output logic [31:0]                bus_rdata,
  output logic                       bus_ready,
  output logic                       bus_error,
  input  logic [$clog2(synth_pkg::NUM_VOICES)-1:0] render_voice_index,
  output synth_pkg::voice_config_t   render_config,
  output synth_pkg::voice_runtime_t  render_runtime,
  output logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0] commit_pulse
);
  import synth_pkg::*;

  // Byte addresses for the simple 32-bit register bus. Configuration writes
  // update shadow_config first; only OFF_COMMIT stages that state for the next
  // frame boundary. Runtime registers update the live runtime state directly.
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
  localparam int ACTIVE_CONFIG_WORD_WIDTH = $bits(voice_config_t);

  localparam int FILTER_COEFF_WORD_WIDTH = 160;
  localparam int FILTER_B0_LSB = 128;
  localparam int FILTER_B1_LSB = 96;
  localparam int FILTER_B2_LSB = 64;
  localparam int FILTER_A1_LSB = 32;
  localparam int FILTER_A2_LSB = 0;
  localparam logic [FILTER_COEFF_WORD_WIDTH-1:0] DEFAULT_FILTER_COEFF = {
    32'sh1000_0000,
    32'sh0000_0000,
    32'sh0000_0000,
    32'sh0000_0000,
    32'sh0000_0000
  };

  function automatic logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] pack_active_config(
    input logic enable,
    input logic stereo,
    input logic [ADDR_WIDTH-1:0] base_addr,
    input logic [ADDR_WIDTH-1:0] base_addr_r,
    input logic [PHASE_FRAME_WIDTH-1:0] length,
    input logic [PHASE_FRAME_WIDTH-1:0] loop_start,
    input logic [PHASE_FRAME_WIDTH-1:0] loop_end,
    input logic [PHASE_WIDTH-1:0] phase_init,
    input logic [1:0] loop_mode
  );
    pack_active_config = {
      enable,
      stereo,
      base_addr,
      base_addr_r,
      length,
      loop_start,
      loop_end,
      phase_init,
      loop_mode
    };
  endfunction

  function automatic voice_config_t unpack_active_config(
    input logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] word
  );
    voice_config_t cfg;
    begin
      cfg = word;
      unpack_active_config = cfg;
    end
  endfunction

  (* ram_style = "distributed" *) logic                      shadow_enable [NUM_VOICES];
  (* ram_style = "distributed" *) logic                      shadow_stereo [NUM_VOICES];
  (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0]     shadow_base_addr [NUM_VOICES];
  (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0]     shadow_base_addr_r [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_FRAME_WIDTH-1:0] shadow_length [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_FRAME_WIDTH-1:0] shadow_loop_start [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_FRAME_WIDTH-1:0] shadow_loop_end [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_WIDTH-1:0]    shadow_phase_init [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_WIDTH-1:0]    shadow_phase_inc [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [15:0]        shadow_gain_l [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [15:0]        shadow_gain_r [NUM_VOICES];
  (* ram_style = "distributed" *) logic [1:0]                shadow_loop_mode [NUM_VOICES];
  (* ram_style = "distributed" *) logic                      shadow_filter_enable [NUM_VOICES];
  logic [FILTER_COEFF_WORD_WIDTH-1:0] shadow_filter_coeff [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_WIDTH-1:0]    runtime_phase_inc [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [15:0]        runtime_gain_l [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [15:0]        runtime_gain_r [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [15:0]        runtime_envelope_level [NUM_VOICES];
  (* ram_style = "distributed" *) logic                      runtime_released [NUM_VOICES];
  (* ram_style = "distributed" *) logic                      runtime_filter_enable [NUM_VOICES];
  logic [NUM_VOICES-1:0] active_config_valid;
  logic [NUM_VOICES-1:0] shadow_config_valid;
  logic [NUM_VOICES-1:0] pending_commit;
  logic address_valid;
  logic voice_address;
  logic [VOICE_INDEX_WIDTH-1:0] selected_voice;
  logic [15:0] selected_offset;
  logic [15:0] voice_relative;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] shadow_filter_wdata;
  logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] active_config_bus_word;
  logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] active_config_ram_word;
  logic active_config_write;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] runtime_filter_render_word;
  logic runtime_filter_write;
  int i;

  initial begin
    for (int v = 0; v < NUM_VOICES; v++) begin
      shadow_filter_coeff[v] = DEFAULT_FILTER_COEFF;
    end
  end

  assign runtime_filter_write = bus_valid && bus_write && voice_address &&
                                ((selected_offset == OFF_FILTER_B0) ||
                                 (selected_offset == OFF_FILTER_B1) ||
                                 (selected_offset == OFF_FILTER_B2) ||
                                 (selected_offset == OFF_FILTER_A1) ||
                                 (selected_offset == OFF_FILTER_A2));

  assign active_config_bus_word = pack_active_config(
    shadow_enable[selected_voice],
    shadow_stereo[selected_voice],
    shadow_base_addr[selected_voice],
    shadow_base_addr_r[selected_voice],
    shadow_length[selected_voice],
    shadow_loop_start[selected_voice],
    shadow_loop_end[selected_voice],
    shadow_phase_init[selected_voice],
    shadow_loop_mode[selected_voice]
  );

  assign active_config_write = bus_valid && bus_write && voice_address &&
                               (selected_offset == OFF_COMMIT) && bus_wdata[0];

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_INDEX_WIDTH),
    .DATA_WIDTH(ACTIVE_CONFIG_WORD_WIDTH),
    .DEFAULT_WORD('0)
  ) active_config_ram (
    .clk(clk),
    .write_en(active_config_write),
    .write_addr(selected_voice),
    .write_data(active_config_bus_word),
    .read_addr(render_voice_index),
    .read_data(active_config_ram_word)
  );

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_INDEX_WIDTH),
    .DATA_WIDTH(FILTER_COEFF_WORD_WIDTH),
    .DEFAULT_WORD(DEFAULT_FILTER_COEFF)
  ) runtime_filter_ram (
    .clk(clk),
    .write_en(runtime_filter_write),
    .write_addr(selected_voice),
    .write_data(shadow_filter_wdata),
    .read_addr(render_voice_index),
    .read_data(runtime_filter_render_word)
  );

  always_comb begin
    for (int v = 0; v < NUM_VOICES; v++) begin
      // A committed voice is playable when it has a nonzero length. Looping
      // modes additionally require a non-empty loop range inside the length.
      shadow_config_valid[v] = (shadow_length[v] != '0) &&
                               ((shadow_loop_mode[v] == LOOP_MODE_NONE) ||
                                ((shadow_loop_start[v] < shadow_loop_end[v]) &&
                                 (shadow_loop_end[v] <= shadow_length[v])));
    end

    config_valid = active_config_valid;

    voice_relative = bus_address - VOICE_BASE;
    selected_voice = voice_relative[7 +: VOICE_INDEX_WIDTH];
    selected_offset = {9'd0, voice_relative[6:0]};
    voice_address = (bus_address >= VOICE_BASE) &&
                    (voice_relative < VOICE_LIMIT);

    shadow_filter_wdata = shadow_filter_coeff[selected_voice];
    unique case (selected_offset)
      OFF_FILTER_B0: begin
        shadow_filter_wdata[FILTER_B0_LSB +: 32] = bus_wdata;
      end
      OFF_FILTER_B1: begin
        shadow_filter_wdata[FILTER_B1_LSB +: 32] = bus_wdata;
      end
      OFF_FILTER_B2: begin
        shadow_filter_wdata[FILTER_B2_LSB +: 32] = bus_wdata;
      end
      OFF_FILTER_A1: begin
        shadow_filter_wdata[FILTER_A1_LSB +: 32] = bus_wdata;
      end
      OFF_FILTER_A2: begin
        shadow_filter_wdata[FILTER_A2_LSB +: 32] = bus_wdata;
      end
      default: begin
      end
    endcase

    address_valid = voice_address || (bus_address == ADDR_VERSION);
    bus_rdata = 32'd0;
    if (voice_address) begin
      unique case (selected_offset)
        OFF_CONTROL, OFF_BASE, OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
        OFF_PHASE_INIT, OFF_PHASE_INC, OFF_GAIN_L, OFF_GAIN_R, OFF_COMMIT,
        OFF_ENVELOPE, OFF_PHASE_RT, OFF_LOOP_MODE, OFF_FILTER_CTL,
        OFF_FILTER_B0, OFF_FILTER_B1, OFF_FILTER_B2, OFF_FILTER_A1,
        OFF_FILTER_A2, OFF_GAIN_RT, OFF_RELEASE, OFF_BASE_R: begin
          bus_rdata = 32'd0;
        end
        OFF_STATUS:     bus_rdata = {31'd0, config_valid[selected_voice]};
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
        shadow_enable[i] <= 1'b0;
        shadow_stereo[i] <= 1'b0;
        shadow_base_addr[i] <= '0;
        shadow_base_addr_r[i] <= '0;
        shadow_length[i] <= '0;
        shadow_loop_start[i] <= '0;
        shadow_loop_end[i] <= '0;
        shadow_phase_init[i] <= '0;
        shadow_phase_inc[i] <= '0;
        shadow_gain_l[i] <= '0;
        shadow_gain_r[i] <= '0;
        shadow_loop_mode[i] <= LOOP_MODE_NONE;
        shadow_filter_enable[i] <= 1'b0;
        runtime_phase_inc[i] <= '0;
        runtime_gain_l[i] <= '0;
        runtime_gain_r[i] <= '0;
        runtime_envelope_level[i] <= 16'sh7fff;
        runtime_released[i] <= 1'b0;
        runtime_filter_enable[i] <= 1'b0;
      end
      render_config <= '0;
      render_config.loop_mode <= LOOP_MODE_NONE;
      render_runtime <= '0;
      render_runtime.envelope_level <= 16'sh7fff;
      render_runtime.filter_b0 <= 32'sh1000_0000;
      commit_pulse <= '0;
      pending_commit <= '0;
      active_config_valid <= '0;
    end else begin
      render_config <= unpack_active_config(active_config_ram_word);

      render_runtime.phase_inc <= runtime_phase_inc[render_voice_index];
      render_runtime.gain_l <= runtime_gain_l[render_voice_index];
      render_runtime.gain_r <= runtime_gain_r[render_voice_index];
      render_runtime.envelope_level <= runtime_envelope_level[render_voice_index];
      render_runtime.released <= runtime_released[render_voice_index];
      render_runtime.filter_enable <= runtime_filter_enable[render_voice_index];
      render_runtime.filter_b0 <= runtime_filter_render_word[FILTER_B0_LSB +: 32];
      render_runtime.filter_b1 <= runtime_filter_render_word[FILTER_B1_LSB +: 32];
      render_runtime.filter_b2 <= runtime_filter_render_word[FILTER_B2_LSB +: 32];
      render_runtime.filter_a1 <= runtime_filter_render_word[FILTER_A1_LSB +: 32];
      render_runtime.filter_a2 <= runtime_filter_render_word[FILTER_A2_LSB +: 32];

      commit_pulse <= pending_commit;

      if (frame_boundary) begin
        pending_commit <= '0;
      end

      if (bus_valid && bus_write && voice_address) begin
        unique case (selected_offset)
          OFF_CONTROL: begin
            shadow_enable[selected_voice] <= bus_wdata[0];
            shadow_stereo[selected_voice] <= bus_wdata[1];
          end
          OFF_BASE:       shadow_base_addr[selected_voice] <= bus_wdata;
          OFF_BASE_R:     shadow_base_addr_r[selected_voice] <= bus_wdata;
          OFF_LENGTH:     shadow_length[selected_voice] <= bus_wdata[PHASE_FRAME_WIDTH-1:0];
          OFF_LOOP_START: shadow_loop_start[selected_voice] <= bus_wdata[PHASE_FRAME_WIDTH-1:0];
          OFF_LOOP_END:   shadow_loop_end[selected_voice] <= bus_wdata[PHASE_FRAME_WIDTH-1:0];
          OFF_PHASE_INIT: shadow_phase_init[selected_voice] <= bus_wdata;
          OFF_PHASE_INC:  shadow_phase_inc[selected_voice] <= bus_wdata;
          OFF_GAIN_L:     shadow_gain_l[selected_voice] <= $signed(bus_wdata[15:0]);
          OFF_GAIN_R:     shadow_gain_r[selected_voice] <= $signed(bus_wdata[15:0]);
          OFF_ENVELOPE: begin
            // Envelope is runtime state owned by the MCU/control layer. Updating
            // it must not reload phase or disturb in-flight note playback.
            runtime_envelope_level[selected_voice] <= $signed(bus_wdata[15:0]);
          end
          OFF_COMMIT: begin
            // Resource-first commit: write the selected active BRAM entry now;
            // frame_boundary only times phase/filter-state reload in the renderer.
            if (bus_wdata[0]) begin
              pending_commit[selected_voice] <= 1'b1;
              active_config_valid[selected_voice] <= shadow_config_valid[selected_voice];
              runtime_phase_inc[selected_voice] <= shadow_phase_inc[selected_voice];
              runtime_gain_l[selected_voice] <= shadow_gain_l[selected_voice];
              runtime_gain_r[selected_voice] <= shadow_gain_r[selected_voice];
              runtime_released[selected_voice] <= 1'b0;
              runtime_filter_enable[selected_voice] <= shadow_filter_enable[selected_voice];
            end
          end
          OFF_PHASE_RT: begin
            runtime_phase_inc[selected_voice] <= bus_wdata;
          end
          OFF_LOOP_MODE: begin
            shadow_loop_mode[selected_voice] <= bus_wdata[1:0];
          end
          OFF_FILTER_CTL: begin
            shadow_filter_enable[selected_voice] <= bus_wdata[0];
            runtime_filter_enable[selected_voice] <= bus_wdata[0];
          end
          OFF_FILTER_B0, OFF_FILTER_B1, OFF_FILTER_B2, OFF_FILTER_A1, OFF_FILTER_A2: begin
            shadow_filter_coeff[selected_voice] <= shadow_filter_wdata;
          end
          OFF_GAIN_RT: begin
            runtime_gain_l[selected_voice] <= $signed(bus_wdata[15:0]);
            runtime_gain_r[selected_voice] <= $signed(bus_wdata[31:16]);
          end
          OFF_RELEASE: begin
            runtime_released[selected_voice] <= bus_wdata[0];
          end
          default: begin
          end
        endcase
      end
    end
  end
endmodule
