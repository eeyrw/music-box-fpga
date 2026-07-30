module voice_major_command_plane #(
  parameter int WORD_FIFO_DEPTH = 1024
) (
  input  logic                                      clk,
  input  logic                                      rst,
  input  synth_pkg::reg_bus_req_t                   bus_req,
  output synth_pkg::reg_bus_rsp_t                   bus_rsp,
  input  logic                                      cmd_stream_valid,
  input  logic [31:0]                               cmd_stream_data,
  output logic                                      cmd_stream_ready,
  input  logic                                      render_busy,
  input  logic [31:0]                               current_frame,

  output logic                                      install_valid,
  input  logic                                      install_ready,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]      install_voice,
  output synth_pkg::block_voice_state_snapshot_t   install_state,
  output logic                                      control_event_valid,
  input  logic                                      control_event_ready,
  output synth_pkg::block_voice_event_t             control_event,
  input  logic                                      control_event_done_pulse,
  input  logic                                      stale_control_event_pulse,

  output synth_pkg::global_audio_config_t           audio_config,
  output logic [1:0]                                effect_clear,

  output logic [31:0]                               command_error_count,
  output logic [31:0]                               stale_generation_count,
  output logic [$clog2(WORD_FIFO_DEPTH+1)-1:0]      word_level,
  output logic                                      action_pending
);
  import synth_pkg::*;
  import synth_register_pkg::*;
  import synth_dsp_lut_pkg::*;

  localparam logic [7:0] CMD_VOICE_START_MONO = 8'h10;
  localparam logic [7:0] CMD_VOICE_ENV = 8'h13;
  localparam logic [7:0] CMD_VOICE_RELEASE = 8'h14;
  localparam logic [7:0] CMD_VOICE_STOP = 8'h15;
  localparam logic [7:0] CMD_VOICE_GAIN = 8'h16;
  localparam logic [7:0] CMD_VOICE_FILTER = 8'h17;
  localparam logic [7:0] CMD_VOICE_PITCH = 8'h18;
  localparam logic [7:0] CMD_COMPRESSOR_CONFIG = 8'h20;
  localparam logic [7:0] CMD_MASTER_VOLUME = 8'h21;
  localparam logic [7:0] CMD_CHORUS_CONFIG = 8'h22;
  localparam logic [7:0] CMD_REVERB_CONFIG = 8'h23;
  localparam logic [7:0] CMD_EFFECT_CLEAR = 8'h24;
  localparam logic [7:0] CMD_STREAM_FLUSH = 8'h7f;
  localparam int MAX_PAYLOAD_WORDS = 16;

  typedef enum logic [2:0] {
    READ_HEADER,
    READ_PAYLOAD,
    DISPATCH_ACTION,
    DISPATCH_INSTALL,
    WAIT_CONTROL_EVENT
  } parser_state_t;

  parser_state_t parser_state_q;
  logic [7:0] opcode_q;
  logic [9:0] command_voice_q;
  logic [5:0] command_flags_q;
  logic [7:0] payload_count_q;
  logic [7:0] payload_index_q;
  logic [31:0] payload_q [0:MAX_PAYLOAD_WORDS-1];
  logic fifo_push;
  logic fifo_push_ready;
  logic fifo_pop;
  logic fifo_head_valid;
  logic [31:0] fifo_head_word;
  logic fifo_empty;
  logic fifo_full;
  logic fifo_flush;
  logic bus_cmd_write;
  logic action_valid_format;
  logic action_fire;
  logic [15:0] command_voice;
  logic voice_action;
  logic audio_action;
  logic audio_action_valid_format;
  logic voice_action_valid_format;
  logic [3:0] start_phase_inc_index;
  logic [3:0] start_gain_index;
  logic [3:0] start_filter_index;
  logic [3:0] start_env_index;
  logic [VOICE_ID_WIDTH-1:0] install_voice_decode;
  block_voice_state_snapshot_t install_state_decode;
  logic [VOICE_ID_WIDTH-1:0] install_voice_q;
  block_voice_state_snapshot_t install_state_q;

  function automatic logic [7:0] start_payload_words(
    input logic [3:0] flags
  );
    start_payload_words = 8'd5 +
        ((flags[1:0] != 2'b00) ? 8'd2 : 8'd0) +
        (flags[2] ? 8'd3 : 8'd0) +
        (flags[3] ? 8'd6 : 8'd0);
  endfunction

  function automatic logic payload_length_valid(
    input logic [7:0] opcode,
    input logic [7:0] count,
    input logic [5:0] flags
  );
    unique case (opcode)
      CMD_VOICE_START_MONO: payload_length_valid =
          (flags[5:4] == 2'b00) && (flags[1:0] != 2'b11) &&
        (count == start_payload_words(flags[3:0]));
      CMD_VOICE_ENV:        payload_length_valid = count == 8'd7;
      CMD_VOICE_RELEASE:    payload_length_valid = count == 8'd2;
      CMD_VOICE_STOP:       payload_length_valid = count == 8'd1;
      CMD_VOICE_GAIN:       payload_length_valid = count == 8'd2;
      CMD_VOICE_FILTER:     payload_length_valid = count == 8'd4;
      CMD_VOICE_PITCH:      payload_length_valid = count == 8'd2;
      CMD_COMPRESSOR_CONFIG: payload_length_valid = count == 8'd4;
      CMD_MASTER_VOLUME:     payload_length_valid = count == 8'd1;
      CMD_CHORUS_CONFIG:     payload_length_valid = count == 8'd6;
      CMD_REVERB_CONFIG:     payload_length_valid = count == 8'd9;
      CMD_EFFECT_CLEAR:      payload_length_valid = count == 8'd1;
      CMD_STREAM_FLUSH:     payload_length_valid = count == 8'd0;
      default:              payload_length_valid = 1'b0;
    endcase
  endfunction

  // Retain register writes for controlled debug injection. Production command
  // traffic uses cmd_stream_valid and must not be serialized through this port.
  assign bus_cmd_write = bus_req.valid && bus_req.write &&
                         (bus_req.address == REG_CMD_FIFO_DATA);
  assign fifo_push = cmd_stream_valid || bus_cmd_write;
  assign cmd_stream_ready = fifo_push_ready;
  assign action_pending = (parser_state_q != READ_HEADER) || !fifo_empty;
  assign command_voice = {6'd0, command_voice_q};
  assign voice_action = (opcode_q == CMD_VOICE_START_MONO) ||
      ((opcode_q >= CMD_VOICE_ENV) && (opcode_q <= CMD_VOICE_PITCH));
  assign audio_action = (opcode_q >= CMD_COMPRESSOR_CONFIG) &&
                        (opcode_q <= CMD_EFFECT_CLEAR);
  always_comb begin
    start_phase_inc_index = command_flags_q[1:0] != 2'b00 ? 4'd5 : 4'd3;
    start_gain_index = start_phase_inc_index + 1'b1;
    start_filter_index = start_gain_index + 1'b1;
    start_env_index = start_filter_index + (command_flags_q[2] ? 4'd3 : 4'd0);
  end
  always_comb begin
    audio_action_valid_format = 1'b1;
    unique case (opcode_q)
      CMD_COMPRESSOR_CONFIG: begin
        audio_action_valid_format = (payload_q[0][31:17] == '0) &&
            (payload_q[1] <= ENV_CB_SILENCE_Q12_20) &&
            (payload_q[2] <= ENV_CB_SILENCE_Q12_20) &&
            (payload_q[3] <= ENV_CB_SILENCE_Q12_20);
      end
      CMD_MASTER_VOLUME:
        audio_action_valid_format = payload_q[0][31:15] == '0;
      CMD_CHORUS_CONFIG: begin
        audio_action_valid_format = (payload_q[0][15:1] == '0) &&
            (payload_q[1][31:24] == '0) &&
            (payload_q[2][31:24] == '0) &&
            ($signed(payload_q[0][31:16]) <= 16'sh6000) &&
            ($signed(payload_q[0][31:16]) >= -16'sh6000) &&
            (payload_q[4][15:0] <= 16'h7fff) &&
            (payload_q[4][31:16] <= 16'h7fff);
      end
      CMD_REVERB_CONFIG: begin
        audio_action_valid_format = (payload_q[0][31:12] == '0) &&
            (payload_q[1][31:16] == '0) &&
            (payload_q[2][31:16] == '0) &&
            (payload_q[3][31:16] == '0) &&
            (payload_q[4][31:16] == '0) &&
            (payload_q[1][15:0] <= 16'h7fff) &&
            (payload_q[2][15:0] <= 16'h7fff) &&
            (payload_q[3][15:0] <= 16'h7fff) &&
            (payload_q[4][15:0] <= 16'h7fff);
        for (int word = 5; word < 9; word++) begin
          audio_action_valid_format = audio_action_valid_format &&
              (payload_q[word][15:0] <= 16'h2d41) &&
              (payload_q[word][31:16] <= 16'h2d41);
        end
      end
      CMD_EFFECT_CLEAR:
        audio_action_valid_format = (payload_q[0][31:2] == '0) &&
                                    (payload_q[0][1:0] != 2'b00);
      default: audio_action_valid_format = 1'b1;
    endcase
  end
  always_comb begin
    voice_action_valid_format = payload_q[0][31:16] == '0;
    unique case (opcode_q)
      CMD_VOICE_START_MONO: begin
        voice_action_valid_format = voice_action_valid_format &&
            (payload_q[2][31:PHASE_FRAME_WIDTH] == '0) &&
            (payload_q[2][PHASE_FRAME_WIDTH-1:0] != '0) &&
            !payload_q[start_gain_index][15] &&
            !payload_q[start_gain_index][31];
        if (command_flags_q[1:0] != 2'b00) begin
          voice_action_valid_format = voice_action_valid_format &&
              (payload_q[3][31:PHASE_FRAME_WIDTH] == '0) &&
              (payload_q[4][31:PHASE_FRAME_WIDTH] == '0) &&
              (payload_q[3][PHASE_FRAME_WIDTH-1:0] <
               payload_q[4][PHASE_FRAME_WIDTH-1:0]) &&
              (payload_q[4][PHASE_FRAME_WIDTH-1:0] <=
               payload_q[2][PHASE_FRAME_WIDTH-1:0]);
        end
        if (command_flags_q[2]) begin
          voice_action_valid_format = voice_action_valid_format &&
              (payload_q[start_filter_index + 4'd2][31:17] == '0);
        end
        if (command_flags_q[3]) begin
          voice_action_valid_format = voice_action_valid_format &&
              (payload_q[start_env_index][31:PHASE_FRAME_WIDTH] == '0) &&
              (payload_q[start_env_index + 4'd2][31:PHASE_FRAME_WIDTH] == '0) &&
              (payload_q[start_env_index + 4'd3] <= ENV_CB_SILENCE_Q12_20) &&
              (payload_q[start_env_index + 4'd4] <= ENV_CB_SILENCE_Q12_20) &&
              (payload_q[start_env_index + 4'd5] <= ENV_CB_SILENCE_Q12_20);
        end
      end
      CMD_VOICE_ENV: begin
        voice_action_valid_format = voice_action_valid_format &&
            (payload_q[1][31:PHASE_FRAME_WIDTH] == '0) &&
            (payload_q[3][31:PHASE_FRAME_WIDTH] == '0) &&
            (payload_q[4] <= ENV_CB_SILENCE_Q12_20) &&
            (payload_q[5] <= ENV_CB_SILENCE_Q12_20) &&
            (payload_q[6] <= ENV_CB_SILENCE_Q12_20);
      end
      CMD_VOICE_RELEASE:
        voice_action_valid_format = voice_action_valid_format &&
            (payload_q[1] <= ENV_CB_SILENCE_Q12_20);
      CMD_VOICE_GAIN:
        voice_action_valid_format = voice_action_valid_format &&
            !payload_q[1][15] && !payload_q[1][31];
      CMD_VOICE_FILTER:
        voice_action_valid_format = voice_action_valid_format &&
            (payload_q[3][31:17] == '0);
      default: begin end
    endcase
  end
  assign action_valid_format = payload_length_valid(
      opcode_q, payload_count_q, command_flags_q) &&
      (((opcode_q == CMD_STREAM_FLUSH) && (command_voice_q == '0) &&
        (command_flags_q == '0)) ||
       (audio_action && (command_voice_q == '0) &&
        (command_flags_q == '0) && audio_action_valid_format) ||
       (voice_action && (int'(command_voice) < NUM_VOICES) &&
        ((opcode_q == CMD_VOICE_START_MONO) || (command_flags_q == '0)) &&
        voice_action_valid_format));
  assign install_valid = parser_state_q == DISPATCH_INSTALL;
  assign install_voice = install_voice_q;
  assign install_state = install_state_q;
  assign control_event_valid = (parser_state_q == DISPATCH_ACTION) &&
      action_valid_format && voice_action &&
      (opcode_q != CMD_VOICE_START_MONO);
  assign action_fire = (install_valid && install_ready) ||
                       (control_event_valid && control_event_ready) ||
                       (audio_action && !render_busy);

  always_comb begin
    bus_rsp = '0;
    if (bus_req.valid) begin
      bus_rsp.ready = 1'b1;
      unique case (bus_req.address)
        REG_VERSION: begin
          bus_rsp.rdata = REG_VERSION_VALUE;
          bus_rsp.error = bus_req.write;
        end
        REG_CURRENT_SAMPLE: begin
          bus_rsp.rdata = current_frame;
          bus_rsp.error = bus_req.write;
        end
        REG_CMD_FIFO_STATUS: begin
          bus_rsp.rdata[0] = fifo_empty;
          bus_rsp.rdata[1] = fifo_full;
          bus_rsp.rdata[15:2] = 14'(word_level);
          bus_rsp.rdata[16] = !action_pending;
          bus_rsp.rdata[17] = action_pending;
          bus_rsp.rdata[30] = command_error_count != '0;
          bus_rsp.rdata[31] = stale_generation_count != '0;
          bus_rsp.error = bus_req.write;
        end
        REG_CMD_FIFO_DATA: begin
          bus_rsp.error = !bus_req.write || cmd_stream_valid || !fifo_push_ready;
        end
        default: bus_rsp.error = 1'b1;
      endcase
    end

    install_voice_decode = command_voice[VOICE_ID_WIDTH-1:0];
    install_state_decode = '0;
    install_state_decode.region.base_addr = payload_q[1];
    install_state_decode.region.length =
        payload_q[2][PHASE_FRAME_WIDTH-1:0];
    install_state_decode.region.loop_start = command_flags_q[1:0] != 2'b00 ?
        payload_q[3][PHASE_FRAME_WIDTH-1:0] : '0;
    install_state_decode.region.loop_end = command_flags_q[1:0] != 2'b00 ?
        payload_q[4][PHASE_FRAME_WIDTH-1:0] :
        payload_q[2][PHASE_FRAME_WIDTH-1:0];
    install_state_decode.region.loop_mode = command_flags_q[1:0];
    install_state_decode.event_params.phase_inc =
        payload_q[start_phase_inc_index];
    install_state_decode.event_params.gain_l =
        payload_q[start_gain_index][15:0];
    install_state_decode.event_params.gain_r =
        payload_q[start_gain_index][31:16];
    if (command_flags_q[2]) begin
      install_state_decode.event_params.filter_b0 =
          payload_q[start_filter_index][15:0];
      install_state_decode.event_params.filter_b1 =
          payload_q[start_filter_index][31:16];
      install_state_decode.event_params.filter_b2 =
          payload_q[start_filter_index + 1'b1][15:0];
      install_state_decode.event_params.filter_a1 =
          payload_q[start_filter_index + 1'b1][31:16];
      install_state_decode.event_params.filter_a2 =
          payload_q[start_filter_index + 4'd2][15:0];
      install_state_decode.event_params.filter_enable =
          payload_q[start_filter_index + 4'd2][16];
    end
    if (command_flags_q[3]) begin
      install_state_decode.env_params.delay_samples =
          payload_q[start_env_index][PHASE_FRAME_WIDTH-1:0];
      install_state_decode.env_params.attack_step_q0_32 =
          payload_q[start_env_index + 1'b1];
      install_state_decode.env_params.hold_samples =
          payload_q[start_env_index + 4'd2][PHASE_FRAME_WIDTH-1:0];
      install_state_decode.env_params.decay_step_cb_q12_20 =
          payload_q[start_env_index + 4'd3];
      install_state_decode.env_params.sustain_cb_q12_20 =
          payload_q[start_env_index + 4'd4];
      install_state_decode.env_params.release_step_cb_q12_20 =
          payload_q[start_env_index + 4'd5];
    end
    install_state_decode.dynamic.active = 1'b1;
    install_state_decode.dynamic.generation = payload_q[0][15:0];
    install_state_decode.dynamic.phase = '0;
    install_state_decode.dynamic.env_state.stage = ENV_DELAY;

    control_event = '0;
    control_event.target_frame = current_frame;
    control_event.host_voice_id = command_voice;
    control_event.generation = payload_q[0][15:0];
    unique case (opcode_q)
      CMD_VOICE_STOP: control_event.kind = BLOCK_VOICE_STOP;
      CMD_VOICE_RELEASE: begin
        control_event.kind = BLOCK_VOICE_RELEASE;
        control_event.env_params.release_step_cb_q12_20 = payload_q[1];
      end
      CMD_VOICE_GAIN: begin
        control_event.kind = BLOCK_VOICE_GAIN;
        control_event.event_params.gain_l = payload_q[1][15:0];
        control_event.event_params.gain_r = payload_q[1][31:16];
      end
      CMD_VOICE_PITCH: begin
        control_event.kind = BLOCK_VOICE_PITCH;
        control_event.event_params.phase_inc = payload_q[1];
      end
      CMD_VOICE_FILTER: begin
        control_event.kind = BLOCK_VOICE_FILTER;
        control_event.event_params.filter_b0 = payload_q[1][15:0];
        control_event.event_params.filter_b1 = payload_q[1][31:16];
        control_event.event_params.filter_b2 = payload_q[2][15:0];
        control_event.event_params.filter_a1 = payload_q[2][31:16];
        control_event.event_params.filter_a2 = payload_q[3][15:0];
        control_event.event_params.filter_enable = payload_q[3][16];
      end
      CMD_VOICE_ENV: begin
        control_event.kind = BLOCK_VOICE_ENV;
        control_event.env_params.delay_samples = payload_q[1][PHASE_FRAME_WIDTH-1:0];
        control_event.env_params.attack_step_q0_32 = payload_q[2];
        control_event.env_params.hold_samples = payload_q[3][PHASE_FRAME_WIDTH-1:0];
        control_event.env_params.decay_step_cb_q12_20 = payload_q[4];
        control_event.env_params.sustain_cb_q12_20 = payload_q[5];
        control_event.env_params.release_step_cb_q12_20 = payload_q[6];
      end
      default: control_event.kind = BLOCK_VOICE_STOP;
    endcase
  end

  assign fifo_pop = fifo_head_valid &&
      ((parser_state_q == READ_HEADER) || (parser_state_q == READ_PAYLOAD));
  assign fifo_flush = (parser_state_q == DISPATCH_ACTION) &&
                      (opcode_q == CMD_STREAM_FLUSH) && action_valid_format;

  control_word_fifo #(.DEPTH(WORD_FIFO_DEPTH), .WIDTH(32)) word_fifo (
    .clk,
    .rst,
    .flush(fifo_flush),
    .push(fifo_push),
    .push_word(cmd_stream_valid ? cmd_stream_data : bus_req.wdata),
    .push_ready(fifo_push_ready),
    .pop(fifo_pop),
    .head_valid(fifo_head_valid),
    .head_word(fifo_head_word),
    .empty(fifo_empty),
    .full(fifo_full),
    .level(word_level)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      parser_state_q <= READ_HEADER;
      opcode_q <= '0;
      command_voice_q <= '0;
      command_flags_q <= '0;
      payload_count_q <= '0;
      payload_index_q <= '0;
      command_error_count <= '0;
      stale_generation_count <= '0;
      audio_config <= '0;
      audio_config.master_volume <= 16'sh7fff;
      effect_clear <= '0;
      install_voice_q <= '0;
      install_state_q <= '0;
    end else begin
      effect_clear <= '0;
      unique case (parser_state_q)
        READ_HEADER: begin
          if (fifo_head_valid) begin
            opcode_q <= fifo_head_word[31:24];
            command_voice_q <= fifo_head_word[23:14];
            command_flags_q <= fifo_head_word[13:8];
            payload_count_q <= fifo_head_word[7:0];
            payload_index_q <= '0;
            parser_state_q <= fifo_head_word[7:0] == 0 ?
                              DISPATCH_ACTION : READ_PAYLOAD;
          end
        end
        READ_PAYLOAD: begin
          if (fifo_head_valid) begin
            if (payload_index_q < 8'(MAX_PAYLOAD_WORDS))
              payload_q[payload_index_q[3:0]] <= fifo_head_word;
            payload_index_q <= payload_index_q + 1'b1;
            if ((payload_index_q + 1'b1) >= payload_count_q)
              parser_state_q <= DISPATCH_ACTION;
          end
        end
        DISPATCH_ACTION: begin
          if (!action_valid_format) begin
            if (command_error_count != 32'hffff_ffff)
              command_error_count <= command_error_count + 1'b1;
            parser_state_q <= READ_HEADER;
          end else if (opcode_q == CMD_STREAM_FLUSH) begin
            parser_state_q <= READ_HEADER;
          end else if (opcode_q == CMD_VOICE_START_MONO) begin
            install_voice_q <= install_voice_decode;
            install_state_q <= install_state_decode;
            parser_state_q <= DISPATCH_INSTALL;
          end else if (action_fire) begin
            unique case (opcode_q)
              CMD_COMPRESSOR_CONFIG: begin
                audio_config.compressor.enable <= payload_q[0][0];
                audio_config.compressor.ratio_slope_q0_16 <= payload_q[0][16:1];
                audio_config.compressor.threshold_cb_q12_20 <= payload_q[1];
                audio_config.compressor.attack_step_cb_q12_20 <= payload_q[2];
                audio_config.compressor.release_step_cb_q12_20 <= payload_q[3];
              end
              CMD_MASTER_VOLUME:
                audio_config.master_volume <= $signed(payload_q[0][15:0]);
              CMD_CHORUS_CONFIG: begin
                audio_config.chorus.enable <= payload_q[0][0];
                audio_config.chorus.feedback_q1_15 <= $signed(payload_q[0][31:16]);
                audio_config.chorus.base_delay_q16_8 <= payload_q[1][23:0];
                audio_config.chorus.depth_q16_8 <= payload_q[2][23:0];
                audio_config.chorus.lfo_phase_inc_q0_32 <= payload_q[3];
                audio_config.chorus.input_send_q1_15 <= payload_q[4][15:0];
                audio_config.chorus.return_gain_q1_15 <= payload_q[4][31:16];
                audio_config.chorus.stereo_phase_offset_q0_32 <= payload_q[5];
              end
              CMD_REVERB_CONFIG: begin
                audio_config.reverb.enable <= payload_q[0][0];
                audio_config.reverb.pre_delay_frames <= payload_q[0][11:1];
                audio_config.reverb.input_send_q1_15 <= payload_q[1][15:0];
                audio_config.reverb.return_gain_q1_15 <= payload_q[2][15:0];
                audio_config.reverb.damping_q1_15 <= payload_q[3][15:0];
                audio_config.reverb.chorus_to_reverb_q1_15 <= payload_q[4][15:0];
                for (int pair = 0; pair < 4; pair++) begin
                  audio_config.reverb.feedback_gain_q1_15[pair * 2] <=
                      payload_q[5 + pair][15:0];
                  audio_config.reverb.feedback_gain_q1_15[pair * 2 + 1] <=
                      payload_q[5 + pair][31:16];
                end
              end
              CMD_EFFECT_CLEAR: effect_clear <= payload_q[0][1:0];
              default: begin end
            endcase
            parser_state_q <= audio_action ? READ_HEADER : WAIT_CONTROL_EVENT;
          end
        end
        DISPATCH_INSTALL: begin
          if (install_valid && install_ready)
            parser_state_q <= READ_HEADER;
        end
        WAIT_CONTROL_EVENT: begin
          if (control_event_done_pulse) begin
            if (stale_control_event_pulse &&
                stale_generation_count != 32'hffff_ffff)
              stale_generation_count <= stale_generation_count + 1'b1;
            parser_state_q <= READ_HEADER;
          end
        end
        default: parser_state_q <= READ_HEADER;
      endcase
    end
  end
endmodule
