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

  output logic [31:0]                               command_error_count,
  output logic [31:0]                               stale_generation_count,
  output logic [$clog2(WORD_FIFO_DEPTH+1)-1:0]      word_level,
  output logic                                      action_pending
);
  import synth_pkg::*;
  import synth_register_pkg::*;

  localparam logic [7:0] CMD_VOICE_START_MONO = 8'h10;
  localparam logic [7:0] CMD_VOICE_ENV = 8'h13;
  localparam logic [7:0] CMD_VOICE_RELEASE = 8'h14;
  localparam logic [7:0] CMD_VOICE_STOP = 8'h15;
  localparam logic [7:0] CMD_VOICE_GAIN = 8'h16;
  localparam logic [7:0] CMD_VOICE_FILTER = 8'h17;
  localparam logic [7:0] CMD_VOICE_PITCH = 8'h18;
  localparam logic [7:0] CMD_STREAM_FLUSH = 8'h7f;
  localparam int MAX_PAYLOAD_WORDS = 17;

  typedef enum logic [2:0] {
    READ_HEADER,
    READ_PAYLOAD,
    DISPATCH_ACTION,
    WAIT_CONTROL_EVENT
  } parser_state_t;

  parser_state_t parser_state_q;
  logic [7:0] opcode_q;
  logic [7:0] voice_q;
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

  function automatic logic payload_length_valid(
    input logic [7:0] opcode,
    input logic [7:0] count
  );
    unique case (opcode)
      CMD_VOICE_START_MONO: payload_length_valid = count == 8'd17;
      CMD_VOICE_ENV:        payload_length_valid = count == 8'd7;
      CMD_VOICE_RELEASE:    payload_length_valid = count == 8'd2;
      CMD_VOICE_STOP:       payload_length_valid = count == 8'd1;
      CMD_VOICE_GAIN:       payload_length_valid = count == 8'd2;
      CMD_VOICE_FILTER:     payload_length_valid = count == 8'd4;
      CMD_VOICE_PITCH:      payload_length_valid = count == 8'd2;
      CMD_STREAM_FLUSH:     payload_length_valid = count == 8'd0;
      default:              payload_length_valid = 1'b0;
    endcase
  endfunction

  assign bus_cmd_write = bus_req.valid && bus_req.write &&
                         (bus_req.address == REG_CMD_FIFO_DATA);
  assign fifo_push = cmd_stream_valid || bus_cmd_write;
  assign cmd_stream_ready = fifo_push_ready;
  assign action_pending = (parser_state_q != READ_HEADER) || !fifo_empty;
  assign action_valid_format = (voice_q < NUM_VOICES) &&
      payload_length_valid(opcode_q, payload_count_q);
  assign install_valid = (parser_state_q == DISPATCH_ACTION) &&
                         action_valid_format &&
                         (opcode_q == CMD_VOICE_START_MONO);
  assign control_event_valid = (parser_state_q == DISPATCH_ACTION) &&
      action_valid_format && (opcode_q != CMD_VOICE_START_MONO) &&
      (opcode_q != CMD_STREAM_FLUSH);
  assign action_fire = (install_valid && install_ready) ||
                       (control_event_valid && control_event_ready);

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
        REG_CMD_ERROR_STATUS: begin
          bus_rsp.rdata = {30'd0, stale_generation_count != '0,
                           command_error_count != '0};
          bus_rsp.error = bus_req.write;
        end
        REG_CMD_ACTION_STATUS: begin
          bus_rsp.rdata = {30'd0, action_pending, !action_pending};
          bus_rsp.error = bus_req.write;
        end
        REG_CMD_FIFO_DATA: begin
          bus_rsp.error = !bus_req.write || cmd_stream_valid || !fifo_push_ready;
        end
        default: bus_rsp.error = 1'b1;
      endcase
    end

    install_voice = voice_q[VOICE_ID_WIDTH-1:0];
    install_state = '0;
    install_state.region.base_addr = payload_q[1];
    install_state.region.length = payload_q[2][PHASE_FRAME_WIDTH-1:0];
    install_state.region.loop_start = payload_q[3][PHASE_FRAME_WIDTH-1:0];
    install_state.region.loop_end = payload_q[4][PHASE_FRAME_WIDTH-1:0];
    install_state.region.loop_mode = payload_q[0][17:16];
    install_state.event_params.phase_inc = payload_q[6];
    install_state.event_params.gain_l = payload_q[7][15:0];
    install_state.event_params.gain_r = payload_q[7][31:16];
    install_state.event_params.filter_b0 = payload_q[8][15:0];
    install_state.event_params.filter_b1 = payload_q[8][31:16];
    install_state.event_params.filter_b2 = payload_q[9][15:0];
    install_state.event_params.filter_a1 = payload_q[9][31:16];
    install_state.event_params.filter_a2 = payload_q[10][15:0];
    install_state.event_params.filter_enable = payload_q[10][16];
    install_state.env_params.delay_samples = payload_q[11][PHASE_FRAME_WIDTH-1:0];
    install_state.env_params.attack_step_q0_32 = payload_q[12];
    install_state.env_params.hold_samples = payload_q[13][PHASE_FRAME_WIDTH-1:0];
    install_state.env_params.decay_step_cb_q12_20 = payload_q[14];
    install_state.env_params.sustain_cb_q12_20 = payload_q[15];
    install_state.env_params.release_step_cb_q12_20 = payload_q[16];
    install_state.dynamic.active = 1'b1;
    install_state.dynamic.generation = payload_q[0][15:0];
    install_state.dynamic.phase = payload_q[5];
    install_state.dynamic.env_state.stage = ENV_DELAY;

    control_event = '0;
    control_event.target_frame = current_frame;
    control_event.host_voice_id = 16'(voice_q);
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
      voice_q <= '0;
      payload_count_q <= '0;
      payload_index_q <= '0;
      command_error_count <= '0;
      stale_generation_count <= '0;
    end else begin
      unique case (parser_state_q)
        READ_HEADER: begin
          if (fifo_head_valid) begin
            opcode_q <= fifo_head_word[31:24];
            voice_q <= fifo_head_word[23:16];
            payload_count_q <= fifo_head_word[7:0];
            payload_index_q <= '0;
            parser_state_q <= fifo_head_word[7:0] == 0 ?
                              DISPATCH_ACTION : READ_PAYLOAD;
          end
        end
        READ_PAYLOAD: begin
          if (fifo_head_valid) begin
            if (payload_index_q < MAX_PAYLOAD_WORDS)
              payload_q[payload_index_q] <= fifo_head_word;
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
          end else if (action_fire) begin
            parser_state_q <= opcode_q == CMD_VOICE_START_MONO ?
                              READ_HEADER : WAIT_CONTROL_EVENT;
          end
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

  logic unused_render_busy;
  assign unused_render_busy = render_busy;
endmodule
