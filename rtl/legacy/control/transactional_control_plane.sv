module transactional_control_plane #(
  parameter int WORD_FIFO_DEPTH = 1024,
  parameter int ACTION_FIFO_DEPTH = 32,
  parameter int MAX_ACTION_BATCH = 16
) (
  input  logic clk,
  input  logic rst,
  input  logic word_push,
  input  logic [31:0] word_push_data,
  output logic word_push_ready,
  input  logic frame_request,
  output logic frame_start,
  output logic control_busy,
  output logic [$clog2(WORD_FIFO_DEPTH+1)-1:0] word_level,
  output logic [$clog2(ACTION_FIFO_DEPTH+1)-1:0] action_level,
  output logic [31:0] command_error_count,
  output logic [31:0] stale_seq_count,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] render_voice_index,
  input  logic snapshot_prepare,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] snapshot_voice,
  output logic snapshot_valid,
  input  logic debug_read_select,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] debug_read_voice,
  output logic [7:0] debug_prepared_seq,
  output synth_pkg::active_voice_t debug_active,
  output synth_pkg::voice_config_t render_config,
  output synth_pkg::voice_runtime_t render_runtime,
  output synth_pkg::global_audio_config_t audio_config,
  output logic [1:0] effect_clear,
  output logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0] commit_pulse,
  output logic [synth_pkg::NUM_VOICES-1:0] prepared_valid
);
  import synth_pkg::*;

  localparam int BATCH_COUNT_WIDTH = $clog2(MAX_ACTION_BATCH+1);
  typedef enum logic [1:0] {BATCH_IDLE, BATCH_ISSUE, BATCH_WAIT} batch_state_t;
  batch_state_t batch_state;
  logic [BATCH_COUNT_WIDTH-1:0] actions_remaining;
  logic word_pop;
  logic word_valid;
  logic [31:0] word_data;
  logic word_empty;
  logic word_full;
  logic parser_word_ready;
  logic parser_action_valid;
  logic parser_action_ready;
  logic action_push_ready;
  control_action_t parser_action;
  logic parser_error_pulse;
  logic action_head_valid;
  logic action_head_ready;
  control_action_t action_head;
  logic executor_ready;
  logic executor_done;
  logic executor_flush;
  logic executor_error_pulse;
  logic stale_seq_pulse;
  logic fifo_flush;

  assign word_pop = word_valid && parser_word_ready;
  assign fifo_flush = executor_flush;
  assign parser_action_ready = action_push_ready;
  assign action_head_ready = (batch_state == BATCH_ISSUE) && executor_ready;
  assign control_busy = (batch_state != BATCH_IDLE) || frame_start;

  control_word_fifo #(.DEPTH(WORD_FIFO_DEPTH), .WIDTH(32)) word_fifo (
    .clk, .rst, .flush(fifo_flush), .push(word_push), .push_word(word_push_data),
    .push_ready(word_push_ready), .pop(word_pop), .head_valid(word_valid),
    .head_word(word_data), .empty(word_empty), .full(word_full), .level(word_level)
  );

  control_action_parser parser (
    .clk, .rst, .flush(fifo_flush), .word_data, .word_valid,
    .word_ready(parser_word_ready), .action_valid(parser_action_valid),
    .action_ready(parser_action_ready), .action(parser_action),
    .command_error_pulse(parser_error_pulse)
  );

  control_action_fifo #(.DEPTH(ACTION_FIFO_DEPTH)) action_fifo (
    .clk, .rst, .flush(fifo_flush), .push_valid(parser_action_valid),
    .push_ready(action_push_ready), .push_action(parser_action), .head_valid(action_head_valid),
    .head_ready(action_head_ready), .head_action(action_head), .level(action_level)
  );

  control_action_executor executor (
    .clk, .rst, .frame_start,
    .action_valid(action_head_valid && (batch_state == BATCH_ISSUE)),
    .action_ready(executor_ready), .action(action_head), .action_done(executor_done),
    .stream_flush(executor_flush), .command_error_pulse(executor_error_pulse),
    .stale_seq_pulse, .render_voice_index, .snapshot_prepare, .snapshot_voice,
    .snapshot_valid,
    .debug_read_select, .debug_read_voice, .debug_prepared_seq, .debug_active,
    .render_config, .render_runtime, .audio_config, .effect_clear,
    .config_valid, .commit_pulse, .prepared_valid
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      batch_state <= BATCH_IDLE;
      actions_remaining <= '0;
      frame_start <= 1'b0;
      command_error_count <= 32'd0;
      stale_seq_count <= 32'd0;
    end else begin
      frame_start <= 1'b0;
      if ((parser_error_pulse || executor_error_pulse) &&
          (command_error_count != 32'hffff_ffff))
        command_error_count <= command_error_count + 32'd1;
      if (stale_seq_pulse && (stale_seq_count != 32'hffff_ffff))
        stale_seq_count <= stale_seq_count + 32'd1;

      unique case (batch_state)
        BATCH_IDLE: begin
          if (frame_request) begin
            if (action_level == '0) begin
              frame_start <= 1'b1;
            end else begin
              actions_remaining <= (action_level > $bits(action_level)'(MAX_ACTION_BATCH)) ?
                                   BATCH_COUNT_WIDTH'(MAX_ACTION_BATCH) :
                                   BATCH_COUNT_WIDTH'(action_level);
              batch_state <= BATCH_ISSUE;
            end
          end
        end
        BATCH_ISSUE: begin
          if (action_head_valid && executor_ready)
            batch_state <= BATCH_WAIT;
        end
        BATCH_WAIT: begin
          if (executor_done) begin
            if ((actions_remaining == BATCH_COUNT_WIDTH'(1)) || executor_flush) begin
              actions_remaining <= '0;
              frame_start <= 1'b1;
              batch_state <= BATCH_IDLE;
            end else begin
              actions_remaining <= actions_remaining - 1'b1;
              batch_state <= BATCH_ISSUE;
            end
          end
        end
        default: batch_state <= BATCH_IDLE;
      endcase
    end
  end

  logic unused_fifo_status;
  assign unused_fifo_status = word_empty | word_full;
endmodule
