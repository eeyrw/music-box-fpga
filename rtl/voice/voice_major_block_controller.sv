module voice_major_block_controller (
  input  logic                                      clk,
  input  logic                                      rst,

  input  logic                                      block_req_valid,
  output logic                                      block_req_ready,
  input  synth_pkg::render_block_req_t              block_req,
  input  logic [synth_pkg::NUM_VOICES-1:0]          active_bitmap,
  output logic                                      render_busy,

  output logic                                      state_read_req_valid,
  input  logic                                      state_read_req_ready,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]      state_read_req_voice,
  input  logic                                      state_read_rsp_valid,
  output logic                                      state_read_rsp_ready,
  input  synth_pkg::block_voice_state_snapshot_t   state_read_rsp,

  output logic                                      dynamic_write_valid,
  input  logic                                      dynamic_write_ready,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]      dynamic_write_voice,
  output synth_pkg::voice_dynamic_state_t           dynamic_write_data,

  output logic                                      line_req_valid,
  input  logic                                      line_req_ready,
  output synth_pkg::ordered_line_req_t              line_req,
  input  logic                                      line_rsp_valid,
  output logic                                      line_rsp_ready,
  input  synth_pkg::ordered_line_rsp_t              line_rsp,

  output logic                                      block_complete_valid,
  input  logic                                      block_complete_ready,
  output synth_pkg::render_block_complete_t         block_complete,
  input  logic                                      block_read_req_valid,
  output logic                                      block_read_req_ready,
  input  synth_pkg::render_block_read_req_t         block_read_req,
  output logic                                      block_read_rsp_valid,
  input  logic                                      block_read_rsp_ready,
  output synth_pkg::render_block_read_rsp_t         block_read_rsp,
  input  logic                                      block_release_valid,
  output logic                                      block_release_ready,
  input  logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                    block_release_buffer_id
);
  import synth_pkg::*;

  typedef enum logic [2:0] {
    CTRL_IDLE,
    CTRL_WAIT_FILL,
    CTRL_SELECT_GROUP,
    CTRL_SELECT_VOICE,
    CTRL_REQUEST_STATE,
    CTRL_WAIT_STATE,
    CTRL_DRAIN,
    CTRL_FINISH
  } controller_state_t;

  localparam int ACTIVE_GROUP_SIZE = 32;
  localparam int ACTIVE_GROUP_COUNT =
      (NUM_VOICES + ACTIVE_GROUP_SIZE - 1) / ACTIVE_GROUP_SIZE;
  localparam int ACTIVE_GROUP_INDEX_WIDTH =
      (ACTIVE_GROUP_COUNT > 1) ? $clog2(ACTIVE_GROUP_COUNT) : 1;

  controller_state_t state_q;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] frame_count_q;
  logic [NUM_VOICES-1:0] active_bitmap_q;
  logic [ACTIVE_GROUP_COUNT-1:0] active_group_bitmap_q;
  logic [ACTIVE_GROUP_COUNT-1:0] incoming_group_bitmap;
  logic [ACTIVE_GROUP_INDEX_WIDTH-1:0] selected_group_q;
  logic [ACTIVE_GROUP_INDEX_WIDTH-1:0] selected_group_next;
  logic [4:0] selected_bit_next;
  logic [ACTIVE_GROUP_SIZE-1:0] selected_group_bits;
  logic [ACTIVE_GROUP_SIZE-1:0] selected_group_after_pick;
  logic group_found;
  logic bit_found;
  logic [VOICE_ID_WIDTH-1:0] scan_voice_q;
  logic pending_state_valid_q;
  logic [VOICE_ID_WIDTH-1:0] pending_state_voice_q;
  block_voice_state_snapshot_t pending_state_q;
  localparam int OUTSTANDING_WIDTH = $clog2(NUM_VOICES + 1);
  logic [OUTSTANDING_WIDTH-1:0] outstanding_voices_q;

  logic mix_req_valid;
  logic mix_req_ready;
  logic mix_fill_ready;
  logic mix_contribution_valid;
  logic mix_contribution_ready;
  stereo_pcm_t mix_contribution;
  logic mix_finish_valid;
  logic mix_finish_ready;

  logic engine_start_valid;
  logic engine_start_ready;
  logic engine_contribution_valid;
  logic engine_contribution_ready;
  block_voice_contribution_t engine_contribution;
  logic engine_result_valid;
  logic engine_result_ready;
  logic [VOICE_ID_WIDTH-1:0] engine_result_voice_index;
  voice_dynamic_state_t engine_result;
  logic engine_start_fire;
  logic state_read_rsp_fire;

  assign mix_req_valid = (state_q == CTRL_IDLE) && block_req_valid;
  assign block_req_ready = (state_q == CTRL_IDLE) && mix_req_ready;
  assign render_busy = (state_q != CTRL_IDLE) ||
                       (block_req_valid && block_req_ready);

  assign state_read_req_valid = state_q == CTRL_REQUEST_STATE;
  assign state_read_req_voice = scan_voice_q;
  assign engine_start_valid = pending_state_valid_q;
  assign engine_start_fire = engine_start_valid && engine_start_ready;
  assign state_read_rsp_ready = (state_q == CTRL_WAIT_STATE) &&
                                (!pending_state_valid_q || engine_start_fire);
  assign state_read_rsp_fire = state_read_rsp_valid && state_read_rsp_ready;

  assign dynamic_write_valid = engine_result_valid;
  assign dynamic_write_voice = engine_result_voice_index;
  assign dynamic_write_data = engine_result;
  assign engine_result_ready = dynamic_write_ready;

  assign mix_contribution_valid = engine_contribution_valid;
  assign engine_contribution_ready = mix_contribution_ready;
  assign mix_contribution.l = engine_contribution.contribution_l;
  assign mix_contribution.r = engine_contribution.contribution_r;
  assign mix_finish_valid = state_q == CTRL_FINISH;

  always_comb begin
    incoming_group_bitmap = '0;
    for (int group_index = 0;
         group_index < ACTIVE_GROUP_COUNT; group_index++) begin
      for (int bit_index = 0;
           bit_index < ACTIVE_GROUP_SIZE; bit_index++) begin
        if ((group_index * ACTIVE_GROUP_SIZE + bit_index) < NUM_VOICES)
          incoming_group_bitmap[group_index] |=
              active_bitmap[group_index * ACTIVE_GROUP_SIZE + bit_index];
      end
    end

    group_found = 1'b0;
    selected_group_next = '0;
    for (int group_index = 0;
         group_index < ACTIVE_GROUP_COUNT; group_index++) begin
      if (!group_found && active_group_bitmap_q[group_index]) begin
        selected_group_next = ACTIVE_GROUP_INDEX_WIDTH'(group_index);
        group_found = 1'b1;
      end
    end

    selected_group_bits = '0;
    for (int bit_index = 0;
         bit_index < ACTIVE_GROUP_SIZE; bit_index++) begin
      if ((int'(selected_group_q) * ACTIVE_GROUP_SIZE + bit_index) <
          NUM_VOICES) begin
        selected_group_bits[bit_index] = active_bitmap_q[
            int'(selected_group_q) * ACTIVE_GROUP_SIZE + bit_index];
      end
    end

    bit_found = 1'b0;
    selected_bit_next = '0;
    for (int bit_index = 0;
         bit_index < ACTIVE_GROUP_SIZE; bit_index++) begin
      if (!bit_found && selected_group_bits[bit_index]) begin
        selected_bit_next = 5'(bit_index);
        bit_found = 1'b1;
      end
    end
    selected_group_after_pick = selected_group_bits;
    if (bit_found) selected_group_after_pick[selected_bit_next] = 1'b0;
  end

  block_mono_voice_engine engine (
    .clk,
    .rst,
    .start_valid(engine_start_valid),
    .start_ready(engine_start_ready),
    .start_voice_index(pending_state_voice_q),
    .start_frame_count(frame_count_q),
    .start_region(pending_state_q.region),
    .start_params(pending_state_q.event_params),
    .start_env_params(pending_state_q.env_params),
    .start_dynamic(pending_state_q.dynamic),
    .line_req_valid,
    .line_req_ready,
    .line_req,
    .line_rsp_valid,
    .line_rsp_ready,
    .line_rsp,
    .contribution_valid(engine_contribution_valid),
    .contribution_ready(engine_contribution_ready),
    .contribution(engine_contribution),
    .result_valid(engine_result_valid),
    .result_ready(engine_result_ready),
    .result_voice_index(engine_result_voice_index),
    .result_dynamic(engine_result)
  );

  block_mix_buffer mix_buffer (
    .clk,
    .rst,
    .block_req_valid(mix_req_valid),
    .block_req_ready(mix_req_ready),
    .block_req,
    .block_fill_ready(mix_fill_ready),
    .contribution_valid(mix_contribution_valid),
    .contribution_ready(mix_contribution_ready),
    .contribution_frame_index(engine_contribution.block_frame_index),
    .contribution(mix_contribution),
    .block_finish_valid(mix_finish_valid),
    .block_finish_ready(mix_finish_ready),
    .block_complete_valid,
    .block_complete_ready,
    .block_complete,
    .block_read_req_valid,
    .block_read_req_ready,
    .block_read_req,
    .block_read_rsp_valid,
    .block_read_rsp_ready,
    .block_read_rsp,
    .block_release_valid,
    .block_release_ready,
    .block_release_buffer_id
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= CTRL_IDLE;
      frame_count_q <= '0;
      active_bitmap_q <= '0;
      active_group_bitmap_q <= '0;
      selected_group_q <= '0;
      scan_voice_q <= '0;
      pending_state_valid_q <= 1'b0;
      pending_state_voice_q <= '0;
      pending_state_q <= '0;
      outstanding_voices_q <= '0;
    end else begin
      unique case ({engine_start_fire,
                    engine_result_valid && engine_result_ready})
        2'b10: outstanding_voices_q <= outstanding_voices_q + 1'b1;
        2'b01: outstanding_voices_q <= outstanding_voices_q - 1'b1;
        default: outstanding_voices_q <= outstanding_voices_q;
      endcase

      unique case ({state_read_rsp_fire, engine_start_fire})
        2'b10: pending_state_valid_q <= 1'b1;
        2'b01: pending_state_valid_q <= 1'b0;
        default: pending_state_valid_q <= pending_state_valid_q;
      endcase
      if (state_read_rsp_fire) begin
        pending_state_voice_q <= scan_voice_q;
        pending_state_q <= state_read_rsp;
      end

      unique case (state_q)
        CTRL_IDLE: begin
          if (block_req_valid && block_req_ready) begin
            frame_count_q <= block_req.frame_count;
            active_bitmap_q <= active_bitmap;
            active_group_bitmap_q <= incoming_group_bitmap;
            scan_voice_q <= '0;
            state_q <= CTRL_WAIT_FILL;
          end
        end
        CTRL_WAIT_FILL: begin
          if (mix_fill_ready) state_q <= CTRL_SELECT_GROUP;
        end
        CTRL_SELECT_GROUP: begin
          if (!group_found) begin
            state_q <= CTRL_DRAIN;
          end else begin
            selected_group_q <= selected_group_next;
            state_q <= CTRL_SELECT_VOICE;
          end
        end
        CTRL_SELECT_VOICE: begin
          if (!bit_found) begin
            active_group_bitmap_q[selected_group_q] <= 1'b0;
            state_q <= CTRL_SELECT_GROUP;
          end else begin
            scan_voice_q <= VOICE_ID_WIDTH'(
                int'(selected_group_q) * ACTIVE_GROUP_SIZE +
                int'(selected_bit_next));
            active_bitmap_q[
                int'(selected_group_q) * ACTIVE_GROUP_SIZE +
                int'(selected_bit_next)] <= 1'b0;
            if (selected_group_after_pick == '0)
              active_group_bitmap_q[selected_group_q] <= 1'b0;
            state_q <= CTRL_REQUEST_STATE;
          end
        end
        CTRL_REQUEST_STATE: begin
          if (state_read_req_valid && state_read_req_ready)
            state_q <= CTRL_WAIT_STATE;
        end
        CTRL_WAIT_STATE: begin
          if (state_read_rsp_fire) begin
            state_q <= active_group_bitmap_q[selected_group_q] ?
                       CTRL_SELECT_VOICE : CTRL_SELECT_GROUP;
          end
        end
        CTRL_DRAIN: begin
          if ((outstanding_voices_q == '0) && !engine_result_valid &&
              !pending_state_valid_q)
            state_q <= CTRL_FINISH;
        end
        CTRL_FINISH: begin
          if (mix_finish_valid && mix_finish_ready) state_q <= CTRL_IDLE;
        end
        default: state_q <= CTRL_IDLE;
      endcase
    end
  end
endmodule
