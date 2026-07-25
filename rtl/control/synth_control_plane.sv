module synth_control_plane (
  input  logic                       clk,
  input  logic                       rst,
  input  synth_pkg::reg_bus_req_t    bus_req,
  input  logic                       cmd_stream_valid,
  input  logic [31:0]                cmd_stream_data,
  output logic                       cmd_stream_ready,
  input  logic                       frame_request,
  input  logic                       renderer_busy,
  output logic                       frame_start,
  output logic                       control_busy,
  output synth_pkg::reg_bus_rsp_t    bus_rsp,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] render_voice_index,
  input  logic                       runtime_snapshot_prepare,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] runtime_snapshot_voice,
  output logic                       runtime_snapshot_valid,
  input  logic [31:0]                current_sample,
  output synth_pkg::voice_config_t   render_config,
  output synth_pkg::voice_runtime_t  render_runtime,
  output synth_pkg::compressor_config_t compressor_config,
  output logic signed [15:0]        master_volume,
  output logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0] commit_pulse
);
  import synth_pkg::*;
  import synth_register_pkg::*;

  localparam int CMD_FIFO_DEPTH = 1024;
  localparam int ACTION_FIFO_DEPTH = 32;
  localparam int DEBUG_WORDS = 24;

  typedef enum logic [2:0] {
    DEBUG_IDLE, DEBUG_WAIT_CONTROL, DEBUG_READ_0, DEBUG_READ_1, DEBUG_WRITE
  } debug_state_t;

  logic command_word_push;
  logic [31:0] command_word_data;
  logic command_word_ready;
  logic bus_command_push;
  logic [$clog2(CMD_FIFO_DEPTH+1)-1:0] command_word_level;
  logic [$clog2(ACTION_FIFO_DEPTH+1)-1:0] action_level;
  logic [31:0] command_error_count;
  logic [31:0] stale_seq_count;
  logic [NUM_VOICES-1:0] prepared_valid;
  logic address_known;
  logic transaction_busy;
  logic debug_capture_write;
  logic debug_capture_response_valid;
  logic debug_index_write;
  logic debug_read_select;
  logic [VOICE_ID_WIDTH-1:0] debug_voice_index;
  logic [4:0] debug_word_index;
  debug_state_t debug_state;
  logic [7:0] debug_prepared_seq;
  active_voice_t debug_active;
  logic debug_snapshot_valid;
  logic debug_snapshot_prepared_valid;
  logic debug_snapshot_active_valid;
  logic [7:0] debug_snapshot_prepared_seq;
  logic [7:0] debug_snapshot_active_seq;
  logic [2:0] debug_snapshot_stage;
  logic debug_snapshot_audible;
  logic debug_snapshot_released;
  logic [4:0] debug_bus_word_index;
  (* ram_style = "distributed" *) logic [31:0] debug_words [0:DEBUG_WORDS-1];

  // The snapshot aperture intentionally serializes only the documented subset.
/* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] debug_word(
    input active_voice_t voice,
    input logic [4:0] index
  );
    begin
      unique case (index)
        5'd0:  debug_word = voice.voice.base_addr;
        5'd1:  debug_word = voice.voice.base_addr_r;
        5'd2:  debug_word = {8'd0, voice.voice.length};
        5'd3:  debug_word = {8'd0, voice.voice.length_r};
        5'd4:  debug_word = {8'd0, voice.voice.loop_start};
        5'd5:  debug_word = {8'd0, voice.voice.loop_start_r};
        5'd6:  debug_word = {8'd0, voice.voice.loop_end};
        5'd7:  debug_word = {8'd0, voice.voice.loop_end_r};
        5'd8:  debug_word = voice.voice.phase_init;
        5'd9:  debug_word = voice.phase_inc;
        5'd10: debug_word = {voice.gain_r, voice.gain_l};
        5'd11: debug_word = {8'd0, voice.voice.loop_mode, voice.voice.stereo,
                             voice.released, voice.audible, voice.env_state.stage,
                             16'd0};
        5'd12: debug_word = {15'd0, voice.filter_enable, voice.filter_a2};
        5'd13: debug_word = {voice.filter_b1, voice.filter_b0};
        5'd14: debug_word = {voice.filter_a1, voice.filter_b2};
        5'd15: debug_word = {8'd0, voice.env_params.delay_samples};
        5'd16: debug_word = voice.env_params.attack_step_q0_32;
        5'd17: debug_word = {8'd0, voice.env_params.hold_samples};
        5'd18: debug_word = voice.env_params.decay_step_cb_q12_20;
        5'd19: debug_word = voice.env_params.sustain_cb_q12_20;
        5'd20: debug_word = voice.env_params.release_step_cb_q12_20;
        5'd21: debug_word = {8'd0, voice.env_state.elapsed};
        5'd22: debug_word = voice.env_state.attack_level_q0_32;
        5'd23: debug_word = voice.env_state.attenuation_cb_q12_20;
        default: debug_word = 32'd0;
      endcase
    end
  endfunction
/* verilator lint_on UNUSEDSIGNAL */

  assign bus_command_push = bus_req.valid && bus_req.write &&
                            (bus_req.address == REG_CMD_FIFO_DATA) &&
                            !cmd_stream_valid && command_word_ready;
  assign cmd_stream_ready = command_word_ready && !bus_command_push;
  assign command_word_push = bus_command_push ||
                             (cmd_stream_valid && cmd_stream_ready);
  assign command_word_data = cmd_stream_valid ? cmd_stream_data : bus_req.wdata;
  assign debug_index_write = bus_req.valid && bus_req.write &&
                             (bus_req.address == REG_DEBUG_VOICE_INDEX) &&
                             (debug_state == DEBUG_IDLE) &&
                             (int'(bus_req.wdata[7:0]) < NUM_VOICES) &&
                             (bus_req.wdata[31:8] == '0);
  assign debug_capture_write = bus_req.valid && bus_req.write &&
                               (bus_req.address == REG_DEBUG_VOICE_CAPTURE) &&
                               (debug_state == DEBUG_IDLE) &&
                               (bus_req.wdata == 32'd1);
  assign debug_capture_response_valid = bus_req.valid && bus_req.write &&
                                        (bus_req.address == REG_DEBUG_VOICE_CAPTURE) &&
                                        ((debug_state == DEBUG_IDLE) ||
                                         (debug_state == DEBUG_WAIT_CONTROL)) &&
                                        (bus_req.wdata == 32'd1);
  assign debug_read_select = (debug_state == DEBUG_READ_0) ||
                             (debug_state == DEBUG_READ_1) ||
                             (debug_state == DEBUG_WRITE);
  assign debug_bus_word_index = 5'((bus_req.address - REG_DEBUG_VOICE_BASE_L) >> 2);
  assign control_busy = transaction_busy || (debug_state != DEBUG_IDLE);

  transactional_control_plane #(
    .WORD_FIFO_DEPTH(CMD_FIFO_DEPTH),
    .ACTION_FIFO_DEPTH(ACTION_FIFO_DEPTH),
    .MAX_ACTION_BATCH(16)
  ) control (
    .clk,
    .rst,
    .word_push(command_word_push),
    .word_push_data(command_word_data),
    .word_push_ready(command_word_ready),
    .frame_request(frame_request && (debug_state == DEBUG_IDLE) &&
                   !debug_capture_write),
    .frame_start,
    .control_busy(transaction_busy),
    .word_level(command_word_level),
    .action_level,
    .command_error_count,
    .stale_seq_count,
    .render_voice_index,
    .snapshot_prepare(runtime_snapshot_prepare),
    .snapshot_voice(runtime_snapshot_voice),
    .snapshot_valid(runtime_snapshot_valid),
    .debug_read_select,
    .debug_read_voice(debug_voice_index),
    .debug_prepared_seq,
    .debug_active,
    .render_config,
    .render_runtime,
    .compressor_config,
    .master_volume,
    .config_valid,
    .commit_pulse,
    .prepared_valid
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      debug_state <= DEBUG_IDLE;
      debug_voice_index <= '0;
      debug_word_index <= '0;
      debug_snapshot_valid <= 1'b0;
      debug_snapshot_prepared_valid <= 1'b0;
      debug_snapshot_active_valid <= 1'b0;
      debug_snapshot_prepared_seq <= '0;
      debug_snapshot_active_seq <= '0;
      debug_snapshot_stage <= '0;
      debug_snapshot_audible <= 1'b0;
      debug_snapshot_released <= 1'b0;
    end else begin
      if (debug_index_write)
        debug_voice_index <= bus_req.wdata[VOICE_ID_WIDTH-1:0];
      if (debug_capture_write) begin
        debug_snapshot_valid <= 1'b0;
        debug_state <= DEBUG_WAIT_CONTROL;
      end else begin
        unique case (debug_state)
          DEBUG_IDLE: begin end
          DEBUG_WAIT_CONTROL: begin
            if (!transaction_busy && !renderer_busy)
              debug_state <= DEBUG_READ_0;
          end
          DEBUG_READ_0: debug_state <= DEBUG_READ_1;
          DEBUG_READ_1: begin
            debug_word_index <= '0;
            debug_state <= DEBUG_WRITE;
          end
          DEBUG_WRITE: begin
            debug_words[debug_word_index] <=
                debug_word(debug_active, debug_word_index);
            if (debug_word_index == 5'(DEBUG_WORDS-1)) begin
              debug_snapshot_prepared_valid <= prepared_valid[debug_voice_index];
              debug_snapshot_active_valid <= config_valid[debug_voice_index];
              debug_snapshot_prepared_seq <= debug_prepared_seq;
              debug_snapshot_active_seq <= debug_active.seq;
              debug_snapshot_stage <= debug_active.env_state.stage;
              debug_snapshot_audible <= debug_active.audible;
              debug_snapshot_released <= debug_active.released;
              debug_snapshot_valid <= 1'b1;
              debug_state <= DEBUG_IDLE;
            end else begin
              debug_word_index <= debug_word_index + 1'b1;
            end
          end
          default: debug_state <= DEBUG_IDLE;
        endcase
      end
    end
  end

  always_comb begin
    address_known = (bus_req.address == REG_VERSION) ||
                    (bus_req.address == REG_CURRENT_SAMPLE) ||
                    (bus_req.address == REG_CMD_FIFO_STATUS) ||
                    (bus_req.address == REG_CMD_FIFO_DATA) ||
                    (bus_req.address == REG_CMD_ERROR_STATUS) ||
                    (bus_req.address == REG_CMD_ACTION_STATUS) ||
                    (bus_req.address == REG_DEBUG_VOICE_INDEX) ||
                    (bus_req.address == REG_DEBUG_VOICE_CAPTURE) ||
                    (bus_req.address == REG_DEBUG_VOICE_STATUS) ||
                    ((bus_req.address >= REG_DEBUG_VOICE_BASE_L) &&
                     (bus_req.address <= REG_DEBUG_ENV_ATTENUATION) &&
                     (bus_req.address[1:0] == 2'b00));

    bus_rsp = '0;
    bus_rsp.ready = bus_req.valid;
    bus_rsp.error = bus_req.valid && (!address_known ||
                    (bus_req.write &&
                     (bus_req.address != REG_CMD_FIFO_DATA) &&
                     !debug_index_write && !debug_capture_response_valid) ||
                    (bus_req.write && (bus_req.address == REG_CMD_FIFO_DATA) &&
                     (!command_word_ready || cmd_stream_valid)));

    unique case (bus_req.address)
      REG_VERSION: bus_rsp.rdata = REG_VERSION_VALUE;
      REG_CURRENT_SAMPLE: bus_rsp.rdata = current_sample;
      REG_CMD_FIFO_STATUS: begin
        bus_rsp.rdata[0] = command_word_level == '0;
        bus_rsp.rdata[1] = !command_word_ready;
        bus_rsp.rdata[15:2] = 14'(command_word_level);
        bus_rsp.rdata[16] = action_level == '0;
        bus_rsp.rdata[17] = action_level == $bits(action_level)'(ACTION_FIFO_DEPTH);
        bus_rsp.rdata[29:18] = 12'(action_level);
        bus_rsp.rdata[30] = command_error_count != '0;
        bus_rsp.rdata[31] = stale_seq_count != '0;
      end
      REG_CMD_ERROR_STATUS: begin
        bus_rsp.rdata[0] = command_error_count != '0;
        bus_rsp.rdata[1] = stale_seq_count != '0;
      end
      REG_CMD_ACTION_STATUS: begin
        bus_rsp.rdata[0] = action_level == '0;
        bus_rsp.rdata[1] = action_level == $bits(action_level)'(ACTION_FIFO_DEPTH);
        bus_rsp.rdata[15:2] = 14'(action_level);
      end
      REG_DEBUG_VOICE_INDEX: bus_rsp.rdata = 32'(debug_voice_index);
      REG_DEBUG_VOICE_STATUS: begin
        bus_rsp.rdata[0] = debug_state != DEBUG_IDLE;
        bus_rsp.rdata[1] = debug_snapshot_valid;
        bus_rsp.rdata[2] = debug_snapshot_prepared_valid;
        bus_rsp.rdata[3] = debug_snapshot_active_valid;
        bus_rsp.rdata[4] = debug_snapshot_audible;
        bus_rsp.rdata[5] = debug_snapshot_released;
        bus_rsp.rdata[8:6] = debug_snapshot_stage;
        bus_rsp.rdata[16:9] = debug_snapshot_prepared_seq;
        bus_rsp.rdata[24:17] = debug_snapshot_active_seq;
      end
      default: bus_rsp.rdata = 32'd0;
    endcase
    if ((bus_req.address >= REG_DEBUG_VOICE_BASE_L) &&
        (bus_req.address <= REG_DEBUG_ENV_ATTENUATION) &&
        (bus_req.address[1:0] == 2'b00))
      bus_rsp.rdata = debug_words[debug_bus_word_index];
  end

  logic unused_prepared_valid;
  assign unused_prepared_valid = ^prepared_valid;
endmodule
