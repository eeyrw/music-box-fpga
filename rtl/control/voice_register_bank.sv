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
  localparam logic [15:0] VOICE_STRIDE    = 16'h0100;
  localparam logic [15:0] VOICE_LIMIT     = 16'(NUM_VOICES * VOICE_STRIDE);
  localparam logic [15:0] OFF_BASE        = 16'h0000;
  localparam logic [15:0] OFF_BASE_R      = 16'h0004;
  localparam logic [15:0] OFF_LENGTH      = 16'h0008;
  localparam logic [15:0] OFF_LENGTH_R    = 16'h000c;
  localparam logic [15:0] OFF_LOOP_START  = 16'h0010;
  localparam logic [15:0] OFF_LOOP_START_R = 16'h0014;
  localparam logic [15:0] OFF_LOOP_END    = 16'h0018;
  localparam logic [15:0] OFF_LOOP_END_R  = 16'h001c;
  localparam logic [15:0] OFF_REGION_MODE = 16'h0020;
  localparam logic [15:0] OFF_PHASE_INIT  = 16'h0030;
  localparam logic [15:0] OFF_PHASE_INC   = 16'h0034;
  localparam logic [15:0] OFF_PHASE_RT    = 16'h0038;
  localparam logic [15:0] OFF_GAIN_L      = 16'h0040;
  localparam logic [15:0] OFF_GAIN_R      = 16'h0044;
  localparam logic [15:0] OFF_GAIN_RT     = 16'h0048;
  localparam logic [15:0] OFF_ENVELOPE    = 16'h004c;
  localparam logic [15:0] OFF_FILTER_CTL  = 16'h0050;
  localparam logic [15:0] OFF_FILTER_B0   = 16'h0054;
  localparam logic [15:0] OFF_FILTER_B1   = 16'h0058;
  localparam logic [15:0] OFF_FILTER_B2   = 16'h005c;
  localparam logic [15:0] OFF_FILTER_A1   = 16'h0060;
  localparam logic [15:0] OFF_FILTER_A2   = 16'h0064;
  localparam logic [15:0] OFF_FILTER_COMMIT = 16'h0068;
  localparam logic [15:0] OFF_CONTROL     = 16'h0070;
  localparam logic [15:0] OFF_COMMIT      = 16'h0074;
  localparam logic [15:0] OFF_RELEASE     = 16'h0078;
  localparam logic [15:0] OFF_STATUS      = 16'h007c;
  localparam logic [15:0] ADDR_VERSION    = 16'h3000;

  localparam int VOICE_INDEX_WIDTH = $clog2(NUM_VOICES);

  function automatic logic known_voice_offset(input logic [15:0] offset);
    unique case (offset)
      OFF_CONTROL, OFF_BASE, OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
      OFF_PHASE_INIT, OFF_PHASE_INC, OFF_GAIN_L, OFF_GAIN_R, OFF_COMMIT,
      OFF_STATUS, OFF_ENVELOPE, OFF_PHASE_RT, OFF_REGION_MODE, OFF_FILTER_CTL,
      OFF_FILTER_B0, OFF_FILTER_B1, OFF_FILTER_B2, OFF_FILTER_A1,
      OFF_FILTER_A2, OFF_GAIN_RT, OFF_RELEASE, OFF_BASE_R,
      OFF_FILTER_COMMIT, OFF_LENGTH_R, OFF_LOOP_START_R, OFF_LOOP_END_R: known_voice_offset = 1'b1;
      default: known_voice_offset = 1'b0;
    endcase
  endfunction

  function automatic logic shadow_offset(input logic [15:0] offset);
    unique case (offset)
      OFF_CONTROL, OFF_BASE, OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
      OFF_PHASE_INIT, OFF_PHASE_INC, OFF_GAIN_L, OFF_GAIN_R, OFF_ENVELOPE,
      OFF_PHASE_RT, OFF_REGION_MODE, OFF_FILTER_CTL, OFF_FILTER_B0,
      OFF_FILTER_B1, OFF_FILTER_B2, OFF_FILTER_A1, OFF_FILTER_A2,
      OFF_GAIN_RT, OFF_BASE_R, OFF_LENGTH_R, OFF_LOOP_START_R,
      OFF_LOOP_END_R: shadow_offset = 1'b1;
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

  logic [NUM_VOICES-1:0] shadow_envelope_written;
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
  logic [159:0] runtime_filter_write_word;
  logic runtime_release_clear;
  logic runtime_filter_enable_write;
  logic runtime_filter_enable_data;
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
    .bus_phase_write(bus_valid && bus_write && voice_address &&
                     (selected_offset == OFF_PHASE_RT) && (bus_state == BUS_IDLE)),
    .bus_gain_write(bus_valid && bus_write && voice_address &&
                    (selected_offset == OFF_GAIN_RT) && (bus_state == BUS_IDLE)),
    .bus_envelope_write(bus_valid && bus_write && voice_address &&
                        (selected_offset == OFF_ENVELOPE) && (bus_state == BUS_IDLE)),
    .bus_release_write(bus_valid && bus_write && voice_address &&
                       (selected_offset == OFF_RELEASE) && (bus_state == BUS_IDLE)),
    .bus_write_voice(selected_voice),
    .bus_wdata(bus_wdata),
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
    .envelope_written(shadow_envelope_written[selected_voice]),
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
    .write_data(bus_wdata),
    .read_voice(descriptor_read_voice),
    .read_offset(descriptor_read_offset),
    .read_data(descriptor_read_data)
  );

  always_comb begin
    voice_relative = bus_address - VOICE_BASE;
    selected_voice = voice_relative[8 +: VOICE_INDEX_WIDTH];
    selected_offset = {8'd0, voice_relative[7:0]};
    voice_address = (bus_address >= VOICE_BASE) &&
                    (voice_relative < VOICE_LIMIT);
    global_address = (bus_address == ADDR_VERSION);

    inspect_address = bus_read_address;
    inspect_relative = inspect_address - VOICE_BASE;
    inspect_voice = inspect_relative[8 +: VOICE_INDEX_WIDTH];
    inspect_offset = {8'd0, inspect_relative[7:0]};
    inspect_voice_address = (inspect_address >= VOICE_BASE) &&
                            (inspect_relative < VOICE_LIMIT);

    commit_start_voice = bus_valid && bus_write && voice_address &&
                         (selected_offset == OFF_COMMIT) && bus_wdata[0] &&
                         (bus_state == BUS_IDLE);
    commit_start_filter = bus_valid && bus_write && voice_address &&
                          (selected_offset == OFF_FILTER_COMMIT) && bus_wdata[0] &&
                          (bus_state == BUS_IDLE);
    bus_read_start = bus_valid && !bus_write && voice_address &&
                     known_voice_offset(selected_offset) && (bus_state == BUS_IDLE);

    descriptor_write = bus_valid && bus_write && voice_address &&
                       shadow_offset(selected_offset) && (bus_state == BUS_IDLE);

    descriptor_read_voice = '0;
    descriptor_read_offset = '0;
    if (commit_engine_busy) begin
      descriptor_read_voice = commit_descriptor_read_voice;
      descriptor_read_offset = commit_descriptor_read_offset;
    end else if (inspect_voice_address) begin
      descriptor_read_voice = inspect_voice;
      descriptor_read_offset = inspect_offset;
    end

    inspect_data = 32'd0;
    if (inspect_voice_address) begin
      unique case (inspect_offset)
        OFF_STATUS:   inspect_data = {31'd0, config_valid[inspect_voice]};
        OFF_ENVELOPE: inspect_data = runtime_envelope_inspect_data;
        OFF_PHASE_RT: inspect_data = runtime_phase_inspect_data;
        OFF_GAIN_RT:  inspect_data = runtime_gain_inspect_data;
        OFF_RELEASE:  inspect_data = runtime_release_inspect_data;
        OFF_COMMIT,
        OFF_FILTER_COMMIT: inspect_data = 32'd0;
        default:      inspect_data = descriptor_read_data;
      endcase
    end else if (inspect_address == ADDR_VERSION) begin
      inspect_data = 32'h0005_0000;
    end

    address_valid = (voice_address && known_voice_offset(selected_offset)) || global_address;
    bus_rdata = 32'd0;
    if ((bus_state == BUS_READ_DONE) && inspect_voice_address) begin
      bus_rdata = inspect_data;
    end else if (voice_address && !known_voice_offset(selected_offset)) begin
      address_valid = 1'b0;
    end else if (bus_address == ADDR_VERSION) begin
      bus_rdata = 32'h0005_0000;
    end

    bus_ready = 1'b0;
    if (bus_valid) begin
      if (bus_state == BUS_IDLE) begin
        bus_ready = !commit_start_voice && !commit_start_filter && !bus_read_start;
      end else if (bus_state == BUS_READ_DONE) begin
        bus_ready = 1'b1;
      end else if (bus_state == BUS_DONE) begin
        bus_ready = 1'b1;
      end
    end
    bus_error = bus_valid && !address_valid && (bus_state == BUS_IDLE);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      shadow_envelope_written <= '0;
      bus_read_address <= 16'd0;
      bus_state <= BUS_IDLE;
    end else begin
      unique case (bus_state)
        BUS_IDLE: begin
          if (bus_read_start) begin
            bus_read_address <= bus_address;
            bus_state <= BUS_READ_WAIT;
          end else if (commit_start_voice || commit_start_filter) begin
            bus_state <= BUS_COMMIT_WAIT;
          end else if (bus_valid && bus_write && voice_address) begin
            if (selected_offset == OFF_ENVELOPE) begin
              shadow_envelope_written[selected_voice] <= 1'b1;
            end
          end
        end
        BUS_READ_WAIT: begin
          bus_state <= BUS_READ_DONE;
        end
        BUS_READ_DONE: begin
          if (!bus_valid) begin
            bus_state <= BUS_IDLE;
          end
        end
        BUS_COMMIT_WAIT: begin
          if (commit_engine_done) begin
            bus_state <= BUS_DONE;
          end
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
