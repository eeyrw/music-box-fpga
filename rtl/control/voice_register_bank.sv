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
  // update shadow state first; commit strobes copy coherent groups into the
  // renderer-facing active/runtime state.
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
  localparam logic [15:0] OFF_FILTER_COMMIT = 16'h005c;
  localparam logic [15:0] ADDR_VERSION    = 16'h3000;
  localparam logic [15:0] ADDR_READBACK_ADDR = 16'h3004;
  localparam logic [15:0] ADDR_READBACK_DATA = 16'h3008;

  localparam int VOICE_INDEX_WIDTH = $clog2(NUM_VOICES);
  localparam int ACTIVE_CONFIG_WORD_WIDTH = $bits(voice_config_t);
  localparam int SHADOW_WORDS = NUM_VOICES * 32;
  localparam int SHADOW_WORD_INDEX_WIDTH = $clog2(SHADOW_WORDS);

  localparam int FILTER_COEFF_WORD_WIDTH = 160;
  localparam int FILTER_B0_LSB = 128;
  localparam int FILTER_B1_LSB = 96;
  localparam int FILTER_B2_LSB = 64;
  localparam int FILTER_A1_LSB = 32;
  localparam int FILTER_A2_LSB = 0;
  localparam int VOICE_COMMIT_LAST_SEQ = 17;
  localparam int FILTER_COMMIT_LAST_SEQ = 5;
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

  function automatic logic known_voice_offset(input logic [15:0] offset);
    unique case (offset)
      OFF_CONTROL, OFF_BASE, OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
      OFF_PHASE_INIT, OFF_PHASE_INC, OFF_GAIN_L, OFF_GAIN_R, OFF_COMMIT,
      OFF_STATUS, OFF_ENVELOPE, OFF_PHASE_RT, OFF_LOOP_MODE, OFF_FILTER_CTL,
      OFF_FILTER_B0, OFF_FILTER_B1, OFF_FILTER_B2, OFF_FILTER_A1,
      OFF_FILTER_A2, OFF_GAIN_RT, OFF_RELEASE, OFF_BASE_R,
      OFF_FILTER_COMMIT: known_voice_offset = 1'b1;
      default: known_voice_offset = 1'b0;
    endcase
  endfunction

  function automatic logic shadow_offset(input logic [15:0] offset);
    unique case (offset)
      OFF_CONTROL, OFF_BASE, OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
      OFF_PHASE_INIT, OFF_PHASE_INC, OFF_GAIN_L, OFF_GAIN_R, OFF_ENVELOPE,
      OFF_PHASE_RT, OFF_LOOP_MODE, OFF_FILTER_CTL, OFF_FILTER_B0,
      OFF_FILTER_B1, OFF_FILTER_B2, OFF_FILTER_A1, OFF_FILTER_A2,
      OFF_GAIN_RT, OFF_BASE_R: shadow_offset = 1'b1;
      default: shadow_offset = 1'b0;
    endcase
  endfunction

  function automatic logic [15:0] voice_commit_offset(input logic [4:0] seq);
    unique case (seq)
      5'd0: voice_commit_offset = OFF_CONTROL;
      5'd1: voice_commit_offset = OFF_BASE;
      5'd2: voice_commit_offset = OFF_LENGTH;
      5'd3: voice_commit_offset = OFF_LOOP_START;
      5'd4: voice_commit_offset = OFF_LOOP_END;
      5'd5: voice_commit_offset = OFF_PHASE_INIT;
      5'd6: voice_commit_offset = OFF_PHASE_INC;
      5'd7: voice_commit_offset = OFF_GAIN_L;
      5'd8: voice_commit_offset = OFF_GAIN_R;
      5'd9: voice_commit_offset = OFF_ENVELOPE;
      5'd10: voice_commit_offset = OFF_LOOP_MODE;
      5'd11: voice_commit_offset = OFF_FILTER_CTL;
      5'd12: voice_commit_offset = OFF_FILTER_B0;
      5'd13: voice_commit_offset = OFF_FILTER_B1;
      5'd14: voice_commit_offset = OFF_FILTER_B2;
      5'd15: voice_commit_offset = OFF_FILTER_A1;
      5'd16: voice_commit_offset = OFF_FILTER_A2;
      5'd17: voice_commit_offset = OFF_BASE_R;
      default: voice_commit_offset = OFF_CONTROL;
    endcase
  endfunction

  function automatic logic [15:0] filter_commit_offset(input logic [4:0] seq);
    unique case (seq)
      5'd0: filter_commit_offset = OFF_FILTER_CTL;
      5'd1: filter_commit_offset = OFF_FILTER_B0;
      5'd2: filter_commit_offset = OFF_FILTER_B1;
      5'd3: filter_commit_offset = OFF_FILTER_B2;
      5'd4: filter_commit_offset = OFF_FILTER_A1;
      5'd5: filter_commit_offset = OFF_FILTER_A2;
      default: filter_commit_offset = OFF_FILTER_CTL;
    endcase
  endfunction

  typedef enum logic [2:0] {
    BUS_IDLE,
    BUS_COMMIT_READ,
    BUS_COMMIT_CAPTURE,
    BUS_COMMIT_APPLY,
    BUS_DONE
  } bus_state_t;

  typedef enum logic {
    COMMIT_VOICE,
    COMMIT_FILTER
  } commit_mode_t;

  (* ram_style = "distributed" *) logic                      runtime_released [NUM_VOICES];
  (* ram_style = "distributed" *) logic                      runtime_filter_enable [NUM_VOICES];
  logic [NUM_VOICES-1:0] shadow_envelope_written;
  logic [NUM_VOICES-1:0] active_config_valid;
  logic [NUM_VOICES-1:0] pending_commit;
  logic address_valid;
  logic voice_address;
  logic global_address;
  logic [VOICE_INDEX_WIDTH-1:0] selected_voice;
  logic [15:0] selected_offset;
  logic [15:0] voice_relative;
  logic [15:0] readback_address;
  logic [15:0] readback_relative;
  logic readback_voice_address;
  logic [VOICE_INDEX_WIDTH-1:0] readback_voice;
  logic [15:0] readback_offset;
  logic [31:0] readback_data;
  logic shadow_write;
  logic [SHADOW_WORD_INDEX_WIDTH-1:0] shadow_write_addr;
  logic [31:0] shadow_write_data;
  logic [SHADOW_WORD_INDEX_WIDTH-1:0] shadow_read_addr;
  logic [31:0] shadow_read_data;
  logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] active_config_bus_word;
  logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] active_config_ram_word;
  logic active_config_write;
  logic runtime_phase_write;
  logic runtime_gain_write;
  logic runtime_envelope_write;
  logic [VOICE_INDEX_WIDTH-1:0] runtime_write_voice;
  logic [31:0] runtime_phase_write_data;
  logic [31:0] runtime_gain_write_data;
  logic [15:0] runtime_envelope_write_data;
  logic [31:0] runtime_phase_render_data;
  logic [31:0] runtime_gain_render_data;
  logic [15:0] runtime_envelope_render_data;
  logic [31:0] runtime_phase_readback_data;
  logic [31:0] runtime_gain_readback_data;
  logic [15:0] runtime_envelope_readback_data;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] runtime_filter_render_word;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] runtime_filter_write_word;
  logic runtime_filter_write;
  bus_state_t bus_state;
  commit_mode_t commit_mode;
  logic [VOICE_INDEX_WIDTH-1:0] commit_voice;
  logic [4:0] commit_seq;
  logic [15:0] commit_offset;
  logic commit_start_voice;
  logic commit_start_filter;
  logic commit_last_seq;
  logic staged_enable;
  logic staged_stereo;
  logic [ADDR_WIDTH-1:0] staged_base_addr;
  logic [ADDR_WIDTH-1:0] staged_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] staged_length;
  logic [PHASE_FRAME_WIDTH-1:0] staged_loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] staged_loop_end;
  logic [PHASE_WIDTH-1:0] staged_phase_init;
  logic [PHASE_WIDTH-1:0] staged_phase_inc;
  logic signed [15:0] staged_gain_l;
  logic signed [15:0] staged_gain_r;
  logic signed [15:0] staged_envelope_level;
  logic [1:0] staged_loop_mode;
  logic staged_filter_enable;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] staged_filter_coeff;
  int i;

  assign active_config_bus_word = pack_active_config(
    staged_enable,
    staged_stereo,
    staged_base_addr,
    staged_base_addr_r,
    staged_length,
    staged_loop_start,
    staged_loop_end,
    staged_phase_init,
    staged_loop_mode
  );

  assign active_config_write = (bus_state == BUS_COMMIT_APPLY) && (commit_mode == COMMIT_VOICE);
  assign runtime_filter_write = (bus_state == BUS_COMMIT_APPLY);
  assign runtime_filter_write_word = staged_filter_coeff;
  assign commit_offset = (commit_mode == COMMIT_VOICE) ?
                         voice_commit_offset(commit_seq) :
                         filter_commit_offset(commit_seq);
  assign commit_last_seq = (commit_mode == COMMIT_VOICE) ?
                           (commit_seq == VOICE_COMMIT_LAST_SEQ[4:0]) :
                           (commit_seq == FILTER_COMMIT_LAST_SEQ[4:0]);
  assign runtime_write_voice = (bus_state == BUS_COMMIT_APPLY) ? commit_voice : selected_voice;
  assign runtime_phase_write = ((bus_state == BUS_COMMIT_APPLY) && (commit_mode == COMMIT_VOICE)) ||
                               (bus_valid && bus_write && voice_address &&
                                (selected_offset == OFF_PHASE_RT) && (bus_state == BUS_IDLE));
  assign runtime_gain_write = ((bus_state == BUS_COMMIT_APPLY) && (commit_mode == COMMIT_VOICE)) ||
                              (bus_valid && bus_write && voice_address &&
                               (selected_offset == OFF_GAIN_RT) && (bus_state == BUS_IDLE));
  assign runtime_envelope_write = ((bus_state == BUS_COMMIT_APPLY) && (commit_mode == COMMIT_VOICE)) ||
                                  (bus_valid && bus_write && voice_address &&
                                   (selected_offset == OFF_ENVELOPE) && (bus_state == BUS_IDLE));
  assign runtime_phase_write_data = (bus_state == BUS_COMMIT_APPLY) ? staged_phase_inc : bus_wdata;
  assign runtime_gain_write_data = (bus_state == BUS_COMMIT_APPLY) ? {staged_gain_r, staged_gain_l} : bus_wdata;
  assign runtime_envelope_write_data = (bus_state == BUS_COMMIT_APPLY) ? staged_envelope_level : bus_wdata[15:0];

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_INDEX_WIDTH),
    .DATA_WIDTH(ACTIVE_CONFIG_WORD_WIDTH),
    .DEFAULT_WORD('0)
  ) active_config_ram (
    .clk(clk),
    .write_en(active_config_write),
    .write_addr(commit_voice),
    .write_data(active_config_bus_word),
    .read_addr(render_voice_index),
    .read_data(active_config_ram_word)
  );

  voice_bram_1w2r #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_INDEX_WIDTH),
    .DATA_WIDTH(32),
    .DEFAULT_WORD(32'd0)
  ) runtime_phase_ram (
    .clk(clk),
    .write_en(runtime_phase_write),
    .write_addr(runtime_write_voice),
    .write_data(runtime_phase_write_data),
    .read_addr_a(render_voice_index),
    .read_data_a(runtime_phase_render_data),
    .read_addr_b(readback_voice),
    .read_data_b(runtime_phase_readback_data)
  );

  voice_bram_1w2r #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_INDEX_WIDTH),
    .DATA_WIDTH(32),
    .DEFAULT_WORD(32'd0)
  ) runtime_gain_ram (
    .clk(clk),
    .write_en(runtime_gain_write),
    .write_addr(runtime_write_voice),
    .write_data(runtime_gain_write_data),
    .read_addr_a(render_voice_index),
    .read_data_a(runtime_gain_render_data),
    .read_addr_b(readback_voice),
    .read_data_b(runtime_gain_readback_data)
  );

  voice_bram_1w2r #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_INDEX_WIDTH),
    .DATA_WIDTH(16),
    .DEFAULT_WORD(16'h7fff)
  ) runtime_envelope_ram (
    .clk(clk),
    .write_en(runtime_envelope_write),
    .write_addr(runtime_write_voice),
    .write_data(runtime_envelope_write_data),
    .read_addr_a(render_voice_index),
    .read_data_a(runtime_envelope_render_data),
    .read_addr_b(readback_voice),
    .read_data_b(runtime_envelope_readback_data)
  );

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_INDEX_WIDTH),
    .DATA_WIDTH(FILTER_COEFF_WORD_WIDTH),
    .DEFAULT_WORD(DEFAULT_FILTER_COEFF)
  ) runtime_filter_ram (
    .clk(clk),
    .write_en(runtime_filter_write),
    .write_addr(commit_voice),
    .write_data(runtime_filter_write_word),
    .read_addr(render_voice_index),
    .read_data(runtime_filter_render_word)
  );

  voice_bram_1r1w #(
    .NUM_WORDS(SHADOW_WORDS),
    .ADDR_WIDTH(SHADOW_WORD_INDEX_WIDTH),
    .DATA_WIDTH(32),
    .DEFAULT_WORD(32'd0)
  ) shadow_reg_ram (
    .clk(clk),
    .write_en(shadow_write),
    .write_addr(shadow_write_addr),
    .write_data(shadow_write_data),
    .read_addr(shadow_read_addr),
    .read_data(shadow_read_data)
  );

  always_comb begin
    config_valid = active_config_valid;

    voice_relative = bus_address - VOICE_BASE;
    selected_voice = voice_relative[7 +: VOICE_INDEX_WIDTH];
    selected_offset = {9'd0, voice_relative[6:0]};
    voice_address = (bus_address >= VOICE_BASE) &&
                    (voice_relative < VOICE_LIMIT);
    global_address = (bus_address == ADDR_VERSION) ||
                     (bus_address == ADDR_READBACK_ADDR) ||
                     (bus_address == ADDR_READBACK_DATA);

    readback_relative = readback_address - VOICE_BASE;
    readback_voice = readback_relative[7 +: VOICE_INDEX_WIDTH];
    readback_offset = {9'd0, readback_relative[6:0]};
    readback_voice_address = (readback_address >= VOICE_BASE) &&
                             (readback_relative < VOICE_LIMIT);

    commit_start_voice = bus_valid && bus_write && voice_address &&
                         (selected_offset == OFF_COMMIT) && bus_wdata[0] &&
                         (bus_state == BUS_IDLE);
    commit_start_filter = bus_valid && bus_write && voice_address &&
                          (selected_offset == OFF_FILTER_COMMIT) && bus_wdata[0] &&
                          (bus_state == BUS_IDLE);

    shadow_write = bus_valid && bus_write && voice_address &&
                   shadow_offset(selected_offset) && (bus_state == BUS_IDLE);
    shadow_write_addr = {selected_voice, selected_offset[6:2]};
    shadow_write_data = bus_wdata;
    unique case (selected_offset)
      OFF_CONTROL: begin
        shadow_write_data = {30'd0, bus_wdata[1:0]};
      end
      OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END: begin
        shadow_write_data = {8'd0, bus_wdata[PHASE_FRAME_WIDTH-1:0]};
      end
      OFF_GAIN_L, OFF_GAIN_R: begin
        shadow_write_data = {{16{bus_wdata[15]}}, bus_wdata[15:0]};
      end
      OFF_ENVELOPE: begin
        shadow_write_data = {{16{bus_wdata[15]}}, bus_wdata[15:0]};
      end
      OFF_GAIN_RT: begin
        shadow_write_data = bus_wdata;
      end
      OFF_LOOP_MODE: begin
        shadow_write_data = {30'd0, bus_wdata[1:0]};
      end
        OFF_FILTER_CTL: begin
          shadow_write_data = {31'd0, bus_wdata[0]};
      end
      default: begin
      end
    endcase

    shadow_read_addr = '0;
    if ((bus_state == BUS_COMMIT_READ) || (bus_state == BUS_COMMIT_CAPTURE)) begin
      shadow_read_addr = {commit_voice, commit_offset[6:2]};
    end else if (readback_voice_address) begin
      shadow_read_addr = {readback_voice, readback_offset[6:2]};
    end

    readback_data = 32'd0;
    if (readback_voice_address) begin
      unique case (readback_offset)
        OFF_STATUS:   readback_data = {31'd0, config_valid[readback_voice]};
        OFF_ENVELOPE: readback_data = {{16{runtime_envelope_readback_data[15]}}, runtime_envelope_readback_data};
        OFF_PHASE_RT: readback_data = runtime_phase_readback_data;
        OFF_GAIN_RT:  readback_data = runtime_gain_readback_data;
        OFF_RELEASE:  readback_data = {31'd0, runtime_released[readback_voice]};
        default:      readback_data = shadow_read_data;
      endcase
    end else if (readback_address == ADDR_VERSION) begin
      readback_data = 32'h0004_0000;
    end

    address_valid = (voice_address && known_voice_offset(selected_offset)) || global_address;
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
        OFF_FILTER_COMMIT: begin
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
    end else if (bus_address == ADDR_READBACK_ADDR) begin
      bus_rdata = {16'd0, readback_address};
    end else if (bus_address == ADDR_READBACK_DATA) begin
      bus_rdata = readback_data;
    end

    bus_ready = 1'b0;
    if (bus_valid) begin
      if (bus_state == BUS_IDLE) begin
        bus_ready = !commit_start_voice && !commit_start_filter;
      end else if (bus_state == BUS_DONE) begin
        bus_ready = 1'b1;
      end
    end
    bus_error = bus_valid && !address_valid && (bus_state == BUS_IDLE);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < NUM_VOICES; i++) begin
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
      shadow_envelope_written <= '0;
      readback_address <= 16'd0;
      bus_state <= BUS_IDLE;
      commit_mode <= COMMIT_VOICE;
      commit_voice <= '0;
      commit_seq <= '0;
      staged_enable <= 1'b0;
      staged_stereo <= 1'b0;
      staged_base_addr <= '0;
      staged_base_addr_r <= '0;
      staged_length <= '0;
      staged_loop_start <= '0;
      staged_loop_end <= '0;
      staged_phase_init <= '0;
      staged_phase_inc <= '0;
      staged_gain_l <= '0;
      staged_gain_r <= '0;
      staged_envelope_level <= 16'sh7fff;
      staged_loop_mode <= LOOP_MODE_NONE;
      staged_filter_enable <= 1'b0;
      staged_filter_coeff <= DEFAULT_FILTER_COEFF;
    end else begin
      render_config <= unpack_active_config(active_config_ram_word);

      render_runtime.phase_inc <= runtime_phase_render_data;
      render_runtime.gain_l <= $signed(runtime_gain_render_data[15:0]);
      render_runtime.gain_r <= $signed(runtime_gain_render_data[31:16]);
      render_runtime.envelope_level <= $signed(runtime_envelope_render_data);
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

      unique case (bus_state)
        BUS_IDLE: begin
          if (commit_start_voice || commit_start_filter) begin
            commit_voice <= selected_voice;
            commit_mode <= commit_start_voice ? COMMIT_VOICE : COMMIT_FILTER;
            commit_seq <= '0;
            staged_enable <= 1'b0;
            staged_stereo <= 1'b0;
            staged_base_addr <= '0;
            staged_base_addr_r <= '0;
            staged_length <= '0;
            staged_loop_start <= '0;
            staged_loop_end <= '0;
            staged_phase_init <= '0;
            staged_phase_inc <= '0;
            staged_gain_l <= '0;
            staged_gain_r <= '0;
            staged_envelope_level <= 16'sh7fff;
            staged_loop_mode <= LOOP_MODE_NONE;
            staged_filter_enable <= 1'b0;
            staged_filter_coeff <= DEFAULT_FILTER_COEFF;
            bus_state <= BUS_COMMIT_READ;
          end else if (bus_valid && bus_write && voice_address) begin
            if (selected_offset == OFF_ENVELOPE) begin
              shadow_envelope_written[selected_voice] <= 1'b1;
            end
            unique case (selected_offset)
          OFF_RELEASE: begin
            runtime_released[selected_voice] <= bus_wdata[0];
          end
          default: begin
          end
            endcase
          end else if (bus_valid && bus_write && (bus_address == ADDR_READBACK_ADDR)) begin
            readback_address <= bus_wdata[15:0];
          end
        end
        BUS_COMMIT_READ: begin
          bus_state <= BUS_COMMIT_CAPTURE;
        end
        BUS_COMMIT_CAPTURE: begin
          unique case (commit_offset)
            OFF_CONTROL: begin
              staged_enable <= shadow_read_data[0];
              staged_stereo <= shadow_read_data[1];
            end
            OFF_BASE:       staged_base_addr <= shadow_read_data;
            OFF_BASE_R:     staged_base_addr_r <= shadow_read_data;
            OFF_LENGTH:     staged_length <= shadow_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_LOOP_START: staged_loop_start <= shadow_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_LOOP_END:   staged_loop_end <= shadow_read_data[PHASE_FRAME_WIDTH-1:0];
            OFF_PHASE_INIT: staged_phase_init <= shadow_read_data;
            OFF_PHASE_INC:  staged_phase_inc <= shadow_read_data;
            OFF_GAIN_L:     staged_gain_l <= $signed(shadow_read_data[15:0]);
            OFF_GAIN_R:     staged_gain_r <= $signed(shadow_read_data[15:0]);
            OFF_ENVELOPE:   staged_envelope_level <= shadow_envelope_written[commit_voice] ?
                                                    $signed(shadow_read_data[15:0]) : 16'sh7fff;
            OFF_LOOP_MODE:  staged_loop_mode <= shadow_read_data[1:0];
            OFF_FILTER_CTL: staged_filter_enable <= shadow_read_data[0];
            OFF_FILTER_B0:  staged_filter_coeff[FILTER_B0_LSB +: 32] <= shadow_read_data;
            OFF_FILTER_B1:  staged_filter_coeff[FILTER_B1_LSB +: 32] <= shadow_read_data;
            OFF_FILTER_B2:  staged_filter_coeff[FILTER_B2_LSB +: 32] <= shadow_read_data;
            OFF_FILTER_A1:  staged_filter_coeff[FILTER_A1_LSB +: 32] <= shadow_read_data;
            OFF_FILTER_A2:  staged_filter_coeff[FILTER_A2_LSB +: 32] <= shadow_read_data;
            default: begin
            end
          endcase

          if (commit_last_seq) begin
            bus_state <= BUS_COMMIT_APPLY;
          end else begin
            commit_seq <= commit_seq + 1'b1;
            bus_state <= BUS_COMMIT_READ;
          end
        end
        BUS_COMMIT_APPLY: begin
          if (commit_mode == COMMIT_VOICE) begin
            pending_commit[commit_voice] <= 1'b1;
            active_config_valid[commit_voice] <= (staged_length != '0) &&
                                                 ((staged_loop_mode == LOOP_MODE_NONE) ||
                                                  ((staged_loop_start < staged_loop_end) &&
                                                   (staged_loop_end <= staged_length)));
            runtime_released[commit_voice] <= 1'b0;
          end
          runtime_filter_enable[commit_voice] <= staged_filter_enable;
          bus_state <= BUS_DONE;
        end
        BUS_DONE: begin
          if (!bus_valid) begin
            bus_state <= BUS_IDLE;
          end
        end
        default: begin
          bus_state <= BUS_IDLE;
        end
      endcase
    end
  end
endmodule
