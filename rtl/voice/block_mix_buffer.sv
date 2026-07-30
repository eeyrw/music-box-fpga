module block_mix_buffer (
  input  logic                                  clk,
  input  logic                                  rst,

  input  logic                                  block_req_valid,
  output logic                                  block_req_ready,
  input  synth_pkg::render_block_req_t          block_req,
  output logic                                  block_fill_ready,

  input  logic                                  contribution_valid,
  output logic                                  contribution_ready,
  input  logic [synth_pkg::BLOCK_FRAME_INDEX_WIDTH-1:0]
                                                contribution_frame_index,
  input  synth_pkg::stereo_pcm_t                contribution,

  input  logic                                  block_finish_valid,
  output logic                                  block_finish_ready,

  output logic                                  block_complete_valid,
  input  logic                                  block_complete_ready,
  output synth_pkg::render_block_complete_t     block_complete,

  input  logic                                  block_read_req_valid,
  output logic                                  block_read_req_ready,
  input  synth_pkg::render_block_read_req_t     block_read_req,
  output logic                                  block_read_rsp_valid,
  input  logic                                  block_read_rsp_ready,
  output synth_pkg::render_block_read_rsp_t     block_read_rsp,

  input  logic                                  block_release_valid,
  output logic                                  block_release_ready,
  input  logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                block_release_buffer_id
);
  import synth_pkg::*;

  typedef enum logic [2:0] {
    BANK_FREE,
    BANK_CLEARING,
    BANK_FILLING,
    BANK_PUBLISHED,
    BANK_OWNED
  } bank_state_t;

  bank_state_t bank_state [0:1];
  accum_t accum_l [0:1][0:MAX_BLOCK_FRAMES-1];
  accum_t accum_r [0:1][0:MAX_BLOCK_FRAMES-1];
  logic [TIMELINE_FRAME_WIDTH-1:0] bank_start_frame [0:1];
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] bank_frame_count [0:1];
  logic fill_bank;
  logic [BLOCK_FRAME_INDEX_WIDTH-1:0] clear_index;
  render_block_complete_t complete_reg;
  render_block_read_rsp_t read_rsp_reg;

  logic free_bank_available;
  logic selected_free_bank;
  logic block_req_count_valid;
  logic read_bank_owned;
  logic read_index_valid;

  always_comb begin
    free_bank_available = (bank_state[0] == BANK_FREE) ||
                          (bank_state[1] == BANK_FREE);
    selected_free_bank = (bank_state[0] != BANK_FREE);
    block_req_count_valid = (block_req.frame_count != '0) &&
                            (block_req.frame_count <=
                             BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES));
    block_req_ready = free_bank_available && block_req_count_valid &&
                      (bank_state[0] != BANK_CLEARING) &&
                      (bank_state[0] != BANK_FILLING) &&
                      (bank_state[1] != BANK_CLEARING) &&
                      (bank_state[1] != BANK_FILLING);

    contribution_ready = (bank_state[fill_bank] == BANK_FILLING) &&
                         (BLOCK_FRAME_COUNT_WIDTH'(contribution_frame_index) <
                          bank_frame_count[fill_bank]);
    block_finish_ready = (bank_state[fill_bank] == BANK_FILLING) &&
                         !block_complete_valid;

    read_bank_owned = bank_state[block_read_req.buffer_id] == BANK_OWNED;
    read_index_valid = BLOCK_FRAME_COUNT_WIDTH'(block_read_req.frame_index) <
                       bank_frame_count[block_read_req.buffer_id];
    block_read_req_ready = (!block_read_rsp_valid || block_read_rsp_ready) &&
                           read_bank_owned && read_index_valid;

    block_release_ready =
        bank_state[block_release_buffer_id] == BANK_OWNED;
  end

  assign block_fill_ready = bank_state[fill_bank] == BANK_FILLING;

  assign block_complete = complete_reg;
  assign block_read_rsp = read_rsp_reg;

  always_ff @(posedge clk) begin
    if (rst) begin
      bank_state[0] <= BANK_FREE;
      bank_state[1] <= BANK_FREE;
      bank_start_frame[0] <= '0;
      bank_start_frame[1] <= '0;
      bank_frame_count[0] <= '0;
      bank_frame_count[1] <= '0;
      fill_bank <= 1'b0;
      clear_index <= '0;
      complete_reg <= '0;
      block_complete_valid <= 1'b0;
      read_rsp_reg <= '0;
      block_read_rsp_valid <= 1'b0;
    end else begin
      if (block_complete_valid && block_complete_ready) begin
        block_complete_valid <= 1'b0;
        bank_state[complete_reg.buffer_id] <= BANK_OWNED;
      end

      if (block_read_rsp_valid && block_read_rsp_ready) begin
        block_read_rsp_valid <= 1'b0;
      end

      if (block_release_valid && block_release_ready) begin
        bank_state[block_release_buffer_id] <= BANK_FREE;
      end

      if (block_req_valid && block_req_ready) begin
        fill_bank <= selected_free_bank;
        bank_state[selected_free_bank] <= BANK_CLEARING;
        bank_start_frame[selected_free_bank] <= block_req.start_frame;
        bank_frame_count[selected_free_bank] <= block_req.frame_count;
        clear_index <= '0;
      end else if ((bank_state[fill_bank] == BANK_CLEARING)) begin
        accum_l[fill_bank][clear_index] <= '0;
        accum_r[fill_bank][clear_index] <= '0;
        if (BLOCK_FRAME_COUNT_WIDTH'(clear_index) + 1'b1 >=
            bank_frame_count[fill_bank]) begin
          bank_state[fill_bank] <= BANK_FILLING;
        end else begin
          clear_index <= clear_index + 1'b1;
        end
      end

      if (contribution_valid && contribution_ready) begin
        accum_l[fill_bank][contribution_frame_index] <=
            accum_l[fill_bank][contribution_frame_index] +
            MIX_WIDTH'($signed(contribution.l));
        accum_r[fill_bank][contribution_frame_index] <=
            accum_r[fill_bank][contribution_frame_index] +
            MIX_WIDTH'($signed(contribution.r));
      end

      if (block_finish_valid && block_finish_ready) begin
        bank_state[fill_bank] <= BANK_PUBLISHED;
        complete_reg.buffer_id <= fill_bank;
        complete_reg.start_frame <= bank_start_frame[fill_bank];
        complete_reg.frame_count <= bank_frame_count[fill_bank];
        block_complete_valid <= 1'b1;
      end

      if (block_read_req_valid && block_read_req_ready) begin
        read_rsp_reg.sample.l <=
            accum_l[block_read_req.buffer_id][block_read_req.frame_index][MIX_WIDTH-1:0];
        read_rsp_reg.sample.r <=
            accum_r[block_read_req.buffer_id][block_read_req.frame_index][MIX_WIDTH-1:0];
        block_read_rsp_valid <= 1'b1;
      end
    end
  end
endmodule
