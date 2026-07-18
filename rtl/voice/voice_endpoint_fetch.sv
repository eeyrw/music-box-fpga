module voice_endpoint_fetch (
  input  logic                                  clk,
  input  logic                                  rst,
  input  logic                                  issue_valid,
  output logic                                  issue_ready,
  input  logic                                  issue_stereo,
  input  logic [synth_pkg::ADDR_WIDTH-1:0]      issue_base_addr,
  input  logic [synth_pkg::ADDR_WIDTH-1:0]      issue_base_addr_r,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] issue_frame_0,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] issue_frame_1,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] issue_frame_r0,
  input  logic [synth_pkg::PHASE_FRAME_WIDTH-1:0] issue_frame_r1,
  input  synth_pkg::voice_dsp_context_t         issue_context,
  output logic                                  context_valid,
  output synth_pkg::voice_dsp_context_t         context_o,
  output logic                                  empty,
  output logic                                  mem_req_valid,
  output logic [31:0]                           mem_req_addr,
  input  logic                                  mem_req_ready,
  input  logic                                  mem_rsp_valid,
  input  synth_pkg::pcm_t                       mem_rsp_data
);
  import synth_pkg::*;

  localparam int FETCH_QUEUE_DEPTH = 2;
  localparam int FETCH_QUEUE_PTR_WIDTH = $clog2(FETCH_QUEUE_DEPTH);
  localparam int FETCH_QUEUE_COUNT_WIDTH = $clog2(FETCH_QUEUE_DEPTH + 1);
  localparam int FETCH_SLOT_DEPTH = 4;
  localparam int FETCH_SLOT_PTR_WIDTH = $clog2(FETCH_SLOT_DEPTH);
  localparam int FETCH_SLOT_COUNT_WIDTH = $clog2(FETCH_SLOT_DEPTH + 1);
  localparam int WORD_REQ_DEPTH = 16;
  localparam int WORD_REQ_PTR_WIDTH = $clog2(WORD_REQ_DEPTH);
  localparam int WORD_REQ_COUNT_WIDTH = $clog2(WORD_REQ_DEPTH + 1);

  typedef enum logic [1:0] {
    ENDPOINT_L0,
    ENDPOINT_L1,
    ENDPOINT_R0,
    ENDPOINT_R1
  } endpoint_kind_t;

  typedef enum logic [2:0] {
    ENQ_IDLE,
    ENQ_L0,
    ENQ_L1,
    ENQ_R0,
    ENQ_R1
  } enq_state_t;

  typedef struct packed {
    logic [31:0] addr;
    logic [FETCH_SLOT_PTR_WIDTH-1:0] slot;
    endpoint_kind_t endpoint;
  } word_req_t;

  typedef struct packed {
    logic [FETCH_SLOT_PTR_WIDTH-1:0] slot;
    endpoint_kind_t endpoint;
  } rsp_meta_t;

  enq_state_t enq_state;
  logic enq_stereo;
  logic [ADDR_WIDTH-1:0] enq_base_addr;
  logic [ADDR_WIDTH-1:0] enq_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] enq_frame_0;
  logic [PHASE_FRAME_WIDTH-1:0] enq_frame_1;
  logic [PHASE_FRAME_WIDTH-1:0] enq_frame_r0;
  logic [PHASE_FRAME_WIDTH-1:0] enq_frame_r1;
  logic [FETCH_SLOT_PTR_WIDTH-1:0] enq_slot;

  (* ram_style = "distributed" *) voice_dsp_context_t fetch_queue [FETCH_QUEUE_DEPTH];
  (* ram_style = "distributed" *) voice_dsp_context_t fetch_slot_context [FETCH_SLOT_DEPTH];
  (* ram_style = "distributed" *) pcm_t fetch_slot_raw_l0 [FETCH_SLOT_DEPTH];
  (* ram_style = "distributed" *) pcm_t fetch_slot_raw_l1 [FETCH_SLOT_DEPTH];
  (* ram_style = "distributed" *) pcm_t fetch_slot_raw_r0 [FETCH_SLOT_DEPTH];
  (* ram_style = "distributed" *) pcm_t fetch_slot_raw_r1 [FETCH_SLOT_DEPTH];
  logic [2:0] fetch_slot_pending [FETCH_SLOT_DEPTH];
  (* ram_style = "distributed" *) word_req_t word_req_queue [WORD_REQ_DEPTH];
  (* ram_style = "distributed" *) rsp_meta_t rsp_meta_queue [WORD_REQ_DEPTH];

  logic [FETCH_QUEUE_PTR_WIDTH-1:0] fetch_queue_rd;
  logic [FETCH_QUEUE_PTR_WIDTH-1:0] fetch_queue_wr;
  logic [FETCH_QUEUE_COUNT_WIDTH-1:0] fetch_queue_count;
  logic [FETCH_SLOT_PTR_WIDTH-1:0] fetch_slot_wr;
  logic [FETCH_SLOT_COUNT_WIDTH-1:0] fetch_slot_count;
  logic [WORD_REQ_PTR_WIDTH-1:0] word_req_rd;
  logic [WORD_REQ_PTR_WIDTH-1:0] word_req_wr;
  logic [WORD_REQ_COUNT_WIDTH-1:0] word_req_count;
  logic [WORD_REQ_PTR_WIDTH-1:0] rsp_meta_rd;
  logic [WORD_REQ_PTR_WIDTH-1:0] rsp_meta_wr;
  logic [WORD_REQ_COUNT_WIDTH-1:0] rsp_meta_count;

  logic fetch_queue_empty;
  logic fetch_slot_full;
  logic word_req_empty;
  logic word_req_full;
  logic rsp_meta_empty;
  logic rsp_meta_full;
  logic issue_accept;
  logic context_pop;
  logic word_req_accept;
  logic rsp_meta_pop;
  logic enqueue_word_req;
  word_req_t enqueue_word_req_data;
  rsp_meta_t rsp_meta_head;
  voice_dsp_context_t completed_fetch_context;
  logic fetch_context_push;
  logic fetch_queue_store;
  logic fetch_slot_complete;

  assign fetch_queue_empty = (fetch_queue_count == '0);
  assign fetch_slot_full = (fetch_slot_count == FETCH_SLOT_COUNT_WIDTH'(FETCH_SLOT_DEPTH));
  assign word_req_empty = (word_req_count == '0);
  assign word_req_full = (word_req_count == WORD_REQ_COUNT_WIDTH'(WORD_REQ_DEPTH));
  assign rsp_meta_empty = (rsp_meta_count == '0);
  assign rsp_meta_full = (rsp_meta_count == WORD_REQ_COUNT_WIDTH'(WORD_REQ_DEPTH));
  assign issue_ready = (enq_state == ENQ_IDLE) && !fetch_slot_full;
  assign issue_accept = issue_valid && issue_ready;
  assign context_valid = !fetch_queue_empty;
  assign context_pop = context_valid;
  assign context_o = fetch_queue[fetch_queue_rd];
  assign empty = (enq_state == ENQ_IDLE) && !issue_accept && !context_valid &&
                 (fetch_slot_count == '0) && (fetch_queue_count == '0) &&
                 (word_req_count == '0) && (rsp_meta_count == '0);
  assign mem_req_valid = !word_req_empty && !rsp_meta_full;
  assign word_req_accept = !word_req_empty && !rsp_meta_full && mem_req_ready;
  assign rsp_meta_pop = mem_rsp_valid && !rsp_meta_empty;

  always_comb begin
    mem_req_addr = 32'd0;
    if (!word_req_empty)
      mem_req_addr = word_req_queue[word_req_rd].addr;

    enqueue_word_req = 1'b0;
    enqueue_word_req_data = '0;
    enqueue_word_req_data.slot = enq_slot;
    unique case (enq_state)
      ENQ_L0: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_L0;
        enqueue_word_req_data.addr = enq_base_addr +
                                     {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, enq_frame_0};
      end
      ENQ_L1: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_L1;
        enqueue_word_req_data.addr = enq_base_addr +
                                     {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, enq_frame_1};
      end
      ENQ_R0: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_R0;
        enqueue_word_req_data.addr = enq_base_addr_r +
                                     {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, enq_frame_r0};
      end
      ENQ_R1: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_R1;
        enqueue_word_req_data.addr = enq_base_addr_r +
                                     {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, enq_frame_r1};
      end
      default: begin
      end
    endcase

    rsp_meta_head = rsp_meta_queue[rsp_meta_rd];
    completed_fetch_context = fetch_slot_context[rsp_meta_head.slot];
    completed_fetch_context.raw_l0 = fetch_slot_raw_l0[rsp_meta_head.slot];
    completed_fetch_context.raw_l1 = fetch_slot_raw_l1[rsp_meta_head.slot];
    completed_fetch_context.raw_r0 = fetch_slot_raw_r0[rsp_meta_head.slot];
    completed_fetch_context.raw_r1 = fetch_slot_raw_r1[rsp_meta_head.slot];

    unique case (rsp_meta_head.endpoint)
      ENDPOINT_L0: completed_fetch_context.raw_l0 = mem_rsp_data;
      ENDPOINT_L1: begin
        completed_fetch_context.raw_l1 = mem_rsp_data;
        if (fetch_slot_pending[rsp_meta_head.slot] == 3'd1) begin
          completed_fetch_context.raw_r0 = fetch_slot_raw_l0[rsp_meta_head.slot];
          completed_fetch_context.raw_r1 = mem_rsp_data;
        end
      end
      ENDPOINT_R0: completed_fetch_context.raw_r0 = mem_rsp_data;
      ENDPOINT_R1: completed_fetch_context.raw_r1 = mem_rsp_data;
      default: begin
      end
    endcase

    fetch_context_push = rsp_meta_pop &&
                         (fetch_slot_pending[rsp_meta_head.slot] == 3'd1);
    fetch_queue_store = fetch_context_push;
    fetch_slot_complete = fetch_context_push;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      enq_state <= ENQ_IDLE;
      enq_stereo <= 1'b0;
      enq_base_addr <= '0;
      enq_base_addr_r <= '0;
      enq_frame_0 <= '0;
      enq_frame_1 <= '0;
      enq_frame_r0 <= '0;
      enq_frame_r1 <= '0;
      enq_slot <= '0;
      fetch_queue_rd <= '0;
      fetch_queue_wr <= '0;
      fetch_queue_count <= '0;
      fetch_slot_wr <= '0;
      fetch_slot_count <= '0;
      for (int s = 0; s < FETCH_SLOT_DEPTH; s++)
        fetch_slot_pending[s] <= '0;
      word_req_rd <= '0;
      word_req_wr <= '0;
      word_req_count <= '0;
      rsp_meta_rd <= '0;
      rsp_meta_wr <= '0;
      rsp_meta_count <= '0;
    end else begin
      if (issue_accept) begin
        enq_state <= ENQ_L0;
        enq_stereo <= issue_stereo;
        enq_base_addr <= issue_base_addr;
        enq_base_addr_r <= issue_base_addr_r;
        enq_frame_0 <= issue_frame_0;
        enq_frame_1 <= issue_frame_1;
        enq_frame_r0 <= issue_frame_r0;
        enq_frame_r1 <= issue_frame_r1;
        enq_slot <= fetch_slot_wr;
        fetch_slot_context[fetch_slot_wr] <= issue_context;
        fetch_slot_pending[fetch_slot_wr] <= issue_stereo ? 3'd4 : 3'd2;
        fetch_slot_wr <= fetch_slot_wr + 1'b1;
      end else if (enqueue_word_req) begin
        unique case (enq_state)
          ENQ_L0: enq_state <= ENQ_L1;
          ENQ_L1: enq_state <= enq_stereo ? ENQ_R0 : ENQ_IDLE;
          ENQ_R0: enq_state <= ENQ_R1;
          ENQ_R1: enq_state <= ENQ_IDLE;
          default: enq_state <= ENQ_IDLE;
        endcase
      end

      if (context_pop)
        fetch_queue_rd <= fetch_queue_rd + 1'b1;
      if (fetch_queue_store) begin
        fetch_queue[fetch_queue_wr] <= completed_fetch_context;
        fetch_queue_wr <= fetch_queue_wr + 1'b1;
      end
      unique case ({fetch_queue_store, context_pop})
        2'b10: fetch_queue_count <= fetch_queue_count + 1'b1;
        2'b01: fetch_queue_count <= fetch_queue_count - 1'b1;
        default: begin
        end
      endcase

      if (rsp_meta_pop) begin
        unique case (rsp_meta_head.endpoint)
          ENDPOINT_L0: fetch_slot_raw_l0[rsp_meta_head.slot] <= mem_rsp_data;
          ENDPOINT_L1: fetch_slot_raw_l1[rsp_meta_head.slot] <= mem_rsp_data;
          ENDPOINT_R0: fetch_slot_raw_r0[rsp_meta_head.slot] <= mem_rsp_data;
          ENDPOINT_R1: fetch_slot_raw_r1[rsp_meta_head.slot] <= mem_rsp_data;
          default: begin
          end
        endcase
        fetch_slot_pending[rsp_meta_head.slot] <= fetch_slot_pending[rsp_meta_head.slot] - 3'd1;
        rsp_meta_rd <= rsp_meta_rd + 1'b1;
      end
      unique case ({issue_accept, fetch_slot_complete})
        2'b10: fetch_slot_count <= fetch_slot_count + 1'b1;
        2'b01: fetch_slot_count <= fetch_slot_count - 1'b1;
        default: begin
        end
      endcase

      if (enqueue_word_req) begin
        word_req_queue[word_req_wr] <= enqueue_word_req_data;
        word_req_wr <= word_req_wr + 1'b1;
      end
      if (word_req_accept) begin
        rsp_meta_queue[rsp_meta_wr].slot <= word_req_queue[word_req_rd].slot;
        rsp_meta_queue[rsp_meta_wr].endpoint <= word_req_queue[word_req_rd].endpoint;
        rsp_meta_wr <= rsp_meta_wr + 1'b1;
        word_req_rd <= word_req_rd + 1'b1;
      end
      unique case ({enqueue_word_req, word_req_accept})
        2'b10: word_req_count <= word_req_count + 1'b1;
        2'b01: word_req_count <= word_req_count - 1'b1;
        default: begin
        end
      endcase
      unique case ({word_req_accept, rsp_meta_pop})
        2'b10: rsp_meta_count <= rsp_meta_count + 1'b1;
        2'b01: rsp_meta_count <= rsp_meta_count - 1'b1;
        default: begin
        end
      endcase
    end
  end
endmodule
