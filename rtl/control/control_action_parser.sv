module control_action_parser (
  input  logic clk,
  input  logic rst,
  input  logic flush,
  input  logic [31:0] word_data,
  input  logic word_valid,
  output logic word_ready,
  output logic action_valid,
  input  logic action_ready,
  output synth_pkg::control_action_t action,
  output logic command_error_pulse
);
  import synth_pkg::*;

  typedef enum logic [1:0] {READ_HEADER, READ_PAYLOAD, EMIT_ACTION} state_t;
  state_t state;
  logic [7:0] payload_index;
  logic command_recognized;
  logic fixed_length_valid;
  logic command_valid;
  logic env_update_valid;
  logic voice_valid;
  logic [7:0] env_field_count;

  function automatic logic recognized_opcode(input command_opcode_t opcode);
    unique case (opcode)
      VOICE_DEFINE_MONO, VOICE_DEFINE_STEREO, VOICE_START,
      VOICE_ENV_UPDATE, VOICE_RELEASE, VOICE_STOP,
      VOICE_GAIN_PHASE, VOICE_FILTER, COMPRESSOR_CONFIG, MASTER_VOLUME,
      CHORUS_CONFIG, REVERB_CONFIG, EFFECT_CLEAR,
      STREAM_FLUSH:
        recognized_opcode = 1'b1;
      default: recognized_opcode = 1'b0;
    endcase
  endfunction

  function automatic logic fixed_payload_length_valid(
    input command_opcode_t opcode,
    input logic [7:0] payload_words
  );
    unique case (opcode)
      VOICE_DEFINE_MONO:   fixed_payload_length_valid = payload_words == 8'd11;
      VOICE_DEFINE_STEREO: fixed_payload_length_valid = payload_words == 8'd15;
      VOICE_START:         fixed_payload_length_valid = payload_words == 8'd8;
      VOICE_ENV_UPDATE:    fixed_payload_length_valid =
                              (payload_words >= 8'd1) && (payload_words <= 8'd7);
      VOICE_RELEASE:       fixed_payload_length_valid = payload_words == 8'd1;
      VOICE_STOP:          fixed_payload_length_valid = payload_words == 8'd0;
      VOICE_GAIN_PHASE:    fixed_payload_length_valid = payload_words == 8'd2;
      VOICE_FILTER:        fixed_payload_length_valid = payload_words == 8'd3;
      COMPRESSOR_CONFIG:   fixed_payload_length_valid = payload_words == 8'd4;
      MASTER_VOLUME:       fixed_payload_length_valid = payload_words == 8'd1;
      CHORUS_CONFIG:       fixed_payload_length_valid = payload_words == 8'd6;
      REVERB_CONFIG:       fixed_payload_length_valid = payload_words == 8'd9;
      EFFECT_CLEAR:        fixed_payload_length_valid = payload_words == 8'd1;
      STREAM_FLUSH:        fixed_payload_length_valid = payload_words == 8'd0;
      default:             fixed_payload_length_valid = 1'b0;
    endcase
  endfunction

  always_comb begin
    command_recognized = recognized_opcode(action.opcode);
    fixed_length_valid = fixed_payload_length_valid(action.opcode, action.payload_words);
    voice_valid = (action.opcode == STREAM_FLUSH) ||
                  (((action.opcode == COMPRESSOR_CONFIG) ||
                    (action.opcode == MASTER_VOLUME) ||
                    (action.opcode == CHORUS_CONFIG) ||
                    (action.opcode == REVERB_CONFIG) ||
                    (action.opcode == EFFECT_CLEAR)) ?
                   ((action.voice == 8'd0) && (action.seq == 8'd0)) :
                   (int'(action.voice) < NUM_VOICES));
    env_field_count = 8'($countones(action.payload[0][5:0]));
    env_update_valid = (action.opcode != VOICE_ENV_UPDATE) ||
                       ((action.payload[0][31:6] == '0) &&
                        (action.payload[0][5:0] != '0) &&
                        (action.payload_words == (8'd1 + env_field_count)));
    command_valid = command_recognized && fixed_length_valid &&
                    voice_valid && env_update_valid;

    word_ready = (state == READ_HEADER) || (state == READ_PAYLOAD);
    action_valid = (state == EMIT_ACTION) && command_valid;
  end

  always_ff @(posedge clk) begin
    if (rst || flush) begin
      state <= READ_HEADER;
      payload_index <= 8'd0;
      action <= '0;
      command_error_pulse <= 1'b0;
    end else begin
      command_error_pulse <= 1'b0;
      unique case (state)
        READ_HEADER: begin
          if (word_valid && word_ready) begin
            action <= '0;
            action.opcode <= command_opcode_t'(word_data[31:24]);
            action.voice <= word_data[23:16];
            action.seq <= word_data[15:8];
            action.payload_words <= word_data[7:0];
            payload_index <= 8'd0;
            if (word_data[7:0] == 8'd0)
              state <= EMIT_ACTION;
            else
              state <= READ_PAYLOAD;
          end
        end

        READ_PAYLOAD: begin
          if (word_valid && word_ready) begin
            if (payload_index < 8'(CONTROL_ACTION_MAX_PAYLOAD_WORDS))
              action.payload[payload_index] <= word_data;
            payload_index <= payload_index + 8'd1;
            if ((payload_index + 8'd1) >= action.payload_words)
              state <= EMIT_ACTION;
          end
        end

        EMIT_ACTION: begin
          if (!command_valid) begin
            command_error_pulse <= 1'b1;
            state <= READ_HEADER;
          end else if (action_ready) begin
            state <= READ_HEADER;
          end
        end

        default: state <= READ_HEADER;
      endcase
    end
  end
endmodule
