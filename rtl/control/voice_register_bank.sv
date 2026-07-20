module voice_register_bank (
  input  logic                       clk,
  input  logic                       rst,
  input  synth_pkg::reg_bus_req_t    bus_req,
  input  logic                       frame_boundary,
  output synth_pkg::reg_bus_rsp_t    bus_rsp,
  input  logic [$clog2(synth_pkg::NUM_VOICES)-1:0] render_voice_index,
  output synth_pkg::voice_config_t   render_config,
  output synth_pkg::voice_runtime_t  render_runtime,
  output logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0] commit_pulse
);
  import synth_pkg::*;
  import synth_register_pkg::*;

  // Byte addresses for the simple 32-bit register bus. Address values come
  // from the generated register-map package.
  localparam logic [15:0] VOICE_BASE      = REG_VOICE_BASE;
  localparam logic [15:0] VOICE_STRIDE    = REG_VOICE_STRIDE;
  localparam logic [15:0] VOICE_LIMIT     = 16'(NUM_VOICES * VOICE_STRIDE);
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
  localparam logic [15:0] OFF_PHASE_RT    = REG_OFF_PHASE_INC_RUNTIME;
  localparam logic [15:0] OFF_GAIN        = REG_OFF_GAIN;
  localparam logic [15:0] OFF_GAIN_RT     = REG_OFF_GAIN_RUNTIME;
  localparam logic [15:0] OFF_ENVELOPE    = REG_OFF_ENVELOPE;
  localparam logic [15:0] OFF_ENVELOPE_RT = REG_OFF_ENVELOPE_RUNTIME;
  localparam logic [15:0] OFF_FILTER_CTL  = REG_OFF_FILTER_CONTROL;
  localparam logic [15:0] OFF_FILTER_B0_B1 = REG_OFF_FILTER_B0_B1;
  localparam logic [15:0] OFF_FILTER_B2_A1 = REG_OFF_FILTER_B2_A1;
  localparam logic [15:0] OFF_FILTER_A2   = REG_OFF_FILTER_A2;
  localparam logic [15:0] OFF_RELEASE     = REG_OFF_RELEASE_CONTROL;
  localparam logic [15:0] OFF_STATUS      = REG_OFF_STATUS;
  localparam logic [15:0] ADDR_VERSION    = REG_VERSION;

  localparam int VOICE_INDEX_WIDTH = $clog2(NUM_VOICES);
  localparam int FILTER_COEFF_WORD_WIDTH = 5 * FILTER_COEFF_WIDTH;
  localparam int FILTER_B0_LSB = 4 * FILTER_COEFF_WIDTH;
  localparam int FILTER_B1_LSB = 3 * FILTER_COEFF_WIDTH;
  localparam int FILTER_B2_LSB = 2 * FILTER_COEFF_WIDTH;
  localparam int FILTER_A1_LSB = 1 * FILTER_COEFF_WIDTH;
  localparam int FILTER_A2_LSB = 0;
  localparam logic [FILTER_COEFF_WORD_WIDTH-1:0] DEFAULT_FILTER_COEFF = {
    16'sh4000,
    16'sh0000,
    16'sh0000,
    16'sh0000,
    16'sh0000
  };

  function automatic logic known_voice_offset(input logic [15:0] offset);
    unique case (offset)
      OFF_VOICE_CTL, OFF_BASE, OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
      OFF_PHASE_INIT, OFF_PHASE_INC, OFF_GAIN,
      OFF_STATUS, OFF_ENVELOPE, OFF_ENVELOPE_RT, OFF_PHASE_RT, OFF_FILTER_CTL,
      OFF_FILTER_B0_B1, OFF_FILTER_B2_A1, OFF_FILTER_A2, OFF_GAIN_RT, OFF_RELEASE, OFF_BASE_R,
      OFF_LENGTH_R, OFF_LOOP_START_R, OFF_LOOP_END_R: known_voice_offset = 1'b1;
      default: known_voice_offset = 1'b0;
    endcase
  endfunction

  function automatic logic shadow_offset(input logic [15:0] offset);
    unique case (offset)
      OFF_VOICE_CTL, OFF_BASE, OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
      OFF_PHASE_INIT, OFF_PHASE_INC, OFF_GAIN, OFF_ENVELOPE,
      OFF_BASE_R, OFF_LENGTH_R,
      OFF_LOOP_START_R, OFF_LOOP_END_R: shadow_offset = 1'b1;
      default: shadow_offset = 1'b0;
    endcase
  endfunction

  typedef enum logic [2:0] {
    BUS_IDLE,
    BUS_READ_WAIT,
    BUS_READ_DONE,
    BUS_COMMIT_WAIT,
    BUS_DONE
  } bus_state_t;

  logic address_valid;
  logic voice_address;
  logic global_address;
  logic [VOICE_INDEX_WIDTH-1:0] selected_voice;
  logic [15:0] selected_offset;
  logic [15:0] voice_relative;
  logic [31:0] inspect_data;
  logic [15:0] inspect_address;
  logic [15:0] inspect_relative;
  logic inspect_voice_address;
  logic [VOICE_INDEX_WIDTH-1:0] inspect_voice;
  logic [15:0] inspect_offset;
  logic [15:0] bus_read_address;
  logic bus_read_start;
  logic descriptor_write;
  logic [VOICE_INDEX_WIDTH-1:0] descriptor_read_voice;
  logic [15:0] descriptor_read_offset;
  logic [31:0] descriptor_read_data;
  voice_config_t active_config_write_data;
  logic active_config_write;
  logic [VOICE_INDEX_WIDTH-1:0] active_config_write_voice;
  logic active_config_valid_write;
  logic active_config_valid_data;
  logic [31:0] runtime_phase_inspect_data;
  logic [31:0] runtime_gain_inspect_data;
  logic [31:0] runtime_envelope_inspect_data;
  logic [31:0] runtime_release_inspect_data;
  logic runtime_filter_write;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] runtime_filter_write_word;
  logic runtime_release_clear;
  logic runtime_filter_enable_write;
  logic runtime_filter_enable_data;
  (* ram_style = "distributed" *) logic [FILTER_COEFF_WORD_WIDTH-1:0] shadow_filter_coeff [NUM_VOICES];
  (* ram_style = "distributed" *) logic shadow_filter_enable [NUM_VOICES];
  logic [FILTER_COEFF_WORD_WIDTH-1:0] shadow_filter_read_data;
  logic shadow_filter_enable_read_data;
  logic [31:0] shadow_filter_inspect_data;
  logic shadow_filter_write;
  logic shadow_filter_enable_write;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] shadow_filter_write_data;
  bus_state_t bus_state;
  logic commit_start_voice;
  logic commit_start_filter;
  logic commit_engine_start;
  logic commit_engine_busy;
  logic commit_engine_done;
  logic [VOICE_INDEX_WIDTH-1:0] commit_descriptor_read_voice;
  logic [15:0] commit_descriptor_read_offset;
  logic commit_runtime_phase_write;
  logic commit_runtime_gain_write;
  logic commit_runtime_envelope_write;
  logic [VOICE_INDEX_WIDTH-1:0] commit_runtime_write_voice;
  logic [31:0] commit_runtime_phase_write_data;
  logic [31:0] commit_runtime_gain_write_data;
  logic [15:0] commit_runtime_envelope_write_data;

  assign commit_engine_start = commit_start_voice || commit_start_filter;

  voice_active_store active_store (
    .clk(clk),
    .rst(rst),
    .frame_boundary(frame_boundary),
    .render_voice_index(render_voice_index),
    .render_config(render_config),
    .config_valid(config_valid),
    .commit_pulse(commit_pulse),
    .config_write(active_config_write),
    .config_write_voice(active_config_write_voice),
    .config_write_data(active_config_write_data),
    .valid_write(active_config_valid_write),
    .valid_write_data(active_config_valid_data)
  );

  voice_runtime_store runtime_store (
    .clk(clk),
    .rst(rst),
    .render_voice_index(render_voice_index),
    .render_runtime(render_runtime),
    .inspect_voice(inspect_voice),
    .inspect_phase_inc(runtime_phase_inspect_data),
    .inspect_gain(runtime_gain_inspect_data),
    .inspect_envelope(runtime_envelope_inspect_data),
    .inspect_release(runtime_release_inspect_data),
    .bus_phase_write(bus_req.valid && bus_req.write && voice_address &&
                     (selected_offset == OFF_PHASE_RT) && (bus_state == BUS_IDLE)),
    .bus_gain_write(bus_req.valid && bus_req.write && voice_address &&
                    (selected_offset == OFF_GAIN_RT) && (bus_state == BUS_IDLE)),
    .bus_envelope_write(bus_req.valid && bus_req.write && voice_address &&
                        (selected_offset == OFF_ENVELOPE_RT) && (bus_state == BUS_IDLE)),
    .bus_release_write(bus_req.valid && bus_req.write && voice_address &&
                       (selected_offset == OFF_RELEASE) && (bus_state == BUS_IDLE)),
    .bus_write_voice(selected_voice),
    .bus_wdata(bus_req.wdata),
    .commit_phase_write(commit_runtime_phase_write),
    .commit_gain_write(commit_runtime_gain_write),
    .commit_envelope_write(commit_runtime_envelope_write),
    .commit_release_clear(runtime_release_clear),
    .commit_filter_write(runtime_filter_write),
    .commit_filter_enable_write(runtime_filter_enable_write),
    .commit_write_voice(commit_runtime_write_voice),
    .commit_phase_data(commit_runtime_phase_write_data),
    .commit_gain_data(commit_runtime_gain_write_data),
    .commit_envelope_data(commit_runtime_envelope_write_data),
    .commit_filter_data(runtime_filter_write_word),
    .commit_filter_enable_data(runtime_filter_enable_data)
  );

  voice_commit_engine commit_engine (
    .clk(clk),
    .rst(rst),
    .start(commit_engine_start),
    .start_filter(commit_start_filter),
    .start_voice(selected_voice),
    .shadow_filter_enable(shadow_filter_enable_read_data),
    .shadow_filter_coeff(shadow_filter_read_data),
    .busy(commit_engine_busy),
    .done(commit_engine_done),
    .descriptor_read_voice(commit_descriptor_read_voice),
    .descriptor_read_offset(commit_descriptor_read_offset),
    .descriptor_read_data(descriptor_read_data),
    .active_config_write(active_config_write),
    .active_config_write_voice(active_config_write_voice),
    .active_config_write_data(active_config_write_data),
    .active_config_valid_write(active_config_valid_write),
    .active_config_valid_data(active_config_valid_data),
    .runtime_phase_write(commit_runtime_phase_write),
    .runtime_gain_write(commit_runtime_gain_write),
    .runtime_envelope_write(commit_runtime_envelope_write),
    .runtime_write_voice(commit_runtime_write_voice),
    .runtime_phase_write_data(commit_runtime_phase_write_data),
    .runtime_gain_write_data(commit_runtime_gain_write_data),
    .runtime_envelope_write_data(commit_runtime_envelope_write_data),
    .runtime_release_clear(runtime_release_clear),
    .runtime_filter_write(runtime_filter_write),
    .runtime_filter_write_data(runtime_filter_write_word),
    .runtime_filter_enable_write(runtime_filter_enable_write),
    .runtime_filter_enable_data(runtime_filter_enable_data)
  );

  voice_descriptor_store descriptor_store (
    .clk(clk),
    .write_en(descriptor_write),
    .write_voice(selected_voice),
    .write_offset(selected_offset),
    .write_data(bus_req.wdata),
    .read_voice(descriptor_read_voice),
    .read_offset(descriptor_read_offset),
    .read_data(descriptor_read_data)
  );

  always_comb begin
    voice_relative = bus_req.address - VOICE_BASE;
    selected_voice = voice_relative[8 +: VOICE_INDEX_WIDTH];
    selected_offset = {8'd0, voice_relative[7:0]};
    voice_address = (bus_req.address >= VOICE_BASE) &&
                    (voice_relative < VOICE_LIMIT);
    global_address = (bus_req.address == ADDR_VERSION);

    inspect_address = bus_read_address;
    inspect_relative = inspect_address - VOICE_BASE;
    inspect_voice = inspect_relative[8 +: VOICE_INDEX_WIDTH];
    inspect_offset = {8'd0, inspect_relative[7:0]};
    inspect_voice_address = (inspect_address >= VOICE_BASE) &&
                            (inspect_relative < VOICE_LIMIT);

    commit_start_voice = bus_req.valid && bus_req.write && voice_address &&
                         (selected_offset == OFF_VOICE_CTL) &&
                         (| (bus_req.wdata & REG_VOICE_CONTROL_APPLY_MASK)) &&
                         (bus_state == BUS_IDLE);
    commit_start_filter = bus_req.valid && bus_req.write && voice_address &&
                          (selected_offset == OFF_FILTER_A2) &&
                          (| (bus_req.wdata & REG_FILTER_A2_APPLY_MASK)) &&
                          (bus_state == BUS_IDLE);
    bus_read_start = bus_req.valid && !bus_req.write && voice_address &&
                     known_voice_offset(selected_offset) && (bus_state == BUS_IDLE);

    descriptor_write = bus_req.valid && bus_req.write && voice_address &&
                       shadow_offset(selected_offset) && (bus_state == BUS_IDLE);

    shadow_filter_write = bus_req.valid && bus_req.write && voice_address &&
                          (bus_state == BUS_IDLE) &&
                          ((selected_offset == OFF_FILTER_B0_B1) ||
                           (selected_offset == OFF_FILTER_B2_A1) ||
                           (selected_offset == OFF_FILTER_A2));
    shadow_filter_enable_write = bus_req.valid && bus_req.write && voice_address &&
                                 (selected_offset == OFF_FILTER_CTL) &&
                                 (bus_state == BUS_IDLE);
    shadow_filter_write_data = shadow_filter_coeff[selected_voice];
    unique case (selected_offset)
      OFF_FILTER_B0_B1: begin
        shadow_filter_write_data[FILTER_B0_LSB +: FILTER_COEFF_WIDTH] = bus_req.wdata[15:0];
        shadow_filter_write_data[FILTER_B1_LSB +: FILTER_COEFF_WIDTH] = bus_req.wdata[31:16];
      end
      OFF_FILTER_B2_A1: begin
        shadow_filter_write_data[FILTER_B2_LSB +: FILTER_COEFF_WIDTH] = bus_req.wdata[15:0];
        shadow_filter_write_data[FILTER_A1_LSB +: FILTER_COEFF_WIDTH] = bus_req.wdata[31:16];
      end
      OFF_FILTER_A2: begin
        shadow_filter_write_data[FILTER_A2_LSB +: FILTER_COEFF_WIDTH] = bus_req.wdata[15:0];
      end
      default: begin
      end
    endcase

    descriptor_read_voice = '0;
    descriptor_read_offset = '0;
    if (commit_engine_busy) begin
      descriptor_read_voice = commit_descriptor_read_voice;
      descriptor_read_offset = commit_descriptor_read_offset;
    end else if (inspect_voice_address) begin
      descriptor_read_voice = inspect_voice;
      descriptor_read_offset = inspect_offset;
    end

    shadow_filter_inspect_data = 32'd0;
    unique case (inspect_offset)
      OFF_FILTER_CTL: shadow_filter_inspect_data = {31'd0, shadow_filter_enable_read_data};
      OFF_FILTER_B0_B1: shadow_filter_inspect_data = {
        shadow_filter_read_data[FILTER_B1_LSB +: FILTER_COEFF_WIDTH],
        shadow_filter_read_data[FILTER_B0_LSB +: FILTER_COEFF_WIDTH]
      };
      OFF_FILTER_B2_A1: shadow_filter_inspect_data = {
        shadow_filter_read_data[FILTER_A1_LSB +: FILTER_COEFF_WIDTH],
        shadow_filter_read_data[FILTER_B2_LSB +: FILTER_COEFF_WIDTH]
      };
      OFF_FILTER_A2: shadow_filter_inspect_data = {
        16'd0,
        shadow_filter_read_data[FILTER_A2_LSB +: FILTER_COEFF_WIDTH]
      };
      default: begin
      end
    endcase

    inspect_data = 32'd0;
    if (inspect_voice_address) begin
      unique case (inspect_offset)
        OFF_STATUS:   inspect_data = {31'd0, config_valid[inspect_voice]};
        OFF_ENVELOPE_RT: inspect_data = runtime_envelope_inspect_data;
        OFF_PHASE_RT: inspect_data = runtime_phase_inspect_data;
        OFF_GAIN_RT:  inspect_data = runtime_gain_inspect_data;
        OFF_RELEASE:  inspect_data = runtime_release_inspect_data;
        OFF_FILTER_CTL,
        OFF_FILTER_B0_B1,
        OFF_FILTER_B2_A1,
        OFF_FILTER_A2: inspect_data = shadow_filter_inspect_data;
        default:      inspect_data = descriptor_read_data;
      endcase
    end else if (inspect_address == ADDR_VERSION) begin
      inspect_data = REG_VERSION_VALUE;
    end

    address_valid = (voice_address && known_voice_offset(selected_offset)) || global_address;
    bus_rsp.rdata = 32'd0;
    if ((bus_state == BUS_READ_DONE) && inspect_voice_address) begin
      bus_rsp.rdata = inspect_data;
    end else if (voice_address && !known_voice_offset(selected_offset)) begin
      address_valid = 1'b0;
    end else if (bus_req.address == ADDR_VERSION) begin
      bus_rsp.rdata = REG_VERSION_VALUE;
    end

    bus_rsp.ready = 1'b0;
    if (bus_req.valid) begin
      if (bus_state == BUS_IDLE) begin
        bus_rsp.ready = !commit_start_voice && !commit_start_filter && !bus_read_start;
      end else if (bus_state == BUS_READ_DONE) begin
        bus_rsp.ready = 1'b1;
      end else if (bus_state == BUS_DONE) begin
        bus_rsp.ready = 1'b1;
      end
    end
    bus_rsp.error = bus_req.valid && !address_valid && (bus_state == BUS_IDLE);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      shadow_filter_read_data <= DEFAULT_FILTER_COEFF;
      shadow_filter_enable_read_data <= 1'b0;
      for (int i = 0; i < NUM_VOICES; i++) begin
        shadow_filter_coeff[i] <= DEFAULT_FILTER_COEFF;
        shadow_filter_enable[i] <= 1'b0;
      end
      bus_read_address <= 16'd0;
      bus_state <= BUS_IDLE;
    end else begin
      shadow_filter_read_data <= shadow_filter_coeff[descriptor_read_voice];
      shadow_filter_enable_read_data <= shadow_filter_enable[descriptor_read_voice];
      if (shadow_filter_write)
        shadow_filter_coeff[selected_voice] <= shadow_filter_write_data;
      if (shadow_filter_enable_write)
        shadow_filter_enable[selected_voice] <= bus_req.wdata[0];

      unique case (bus_state)
        BUS_IDLE: begin
          if (bus_read_start) begin
            bus_read_address <= bus_req.address;
            bus_state <= BUS_READ_WAIT;
          end else if (commit_start_voice || commit_start_filter) begin
            bus_state <= BUS_COMMIT_WAIT;
          end
        end
        BUS_READ_WAIT: begin
          bus_state <= BUS_READ_DONE;
        end
        BUS_READ_DONE: begin
          if (!bus_req.valid) begin
            bus_state <= BUS_IDLE;
          end
        end
        BUS_COMMIT_WAIT: begin
          if (commit_engine_done) begin
            bus_state <= BUS_DONE;
          end
        end
        BUS_DONE: begin
          if (!bus_req.valid) begin
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
