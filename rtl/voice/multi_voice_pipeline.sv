module multi_voice_pipeline (
  input  logic                       clk,
  input  logic                       rst,
  output logic [$clog2(synth_pkg::NUM_VOICES)-1:0] voice_read_index,
  input  synth_pkg::voice_config_t   voice_config,
  input  synth_pkg::voice_runtime_t  voice_runtime,
  input  logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  input  logic [synth_pkg::NUM_VOICES-1:0] config_commit,
  input  logic                       sample_tick,
  output logic                       busy,
  output logic                       sample_valid,
  output synth_pkg::pcm_t            sample_l,
  output synth_pkg::pcm_t            sample_r,
  output logic                       mem_req_valid,
  output logic [31:0]                mem_req_addr,
  input  logic                       mem_req_ready,
  input  logic                       mem_rsp_valid,
  input  synth_pkg::pcm_t            mem_rsp_data
);
  import synth_pkg::*;

  typedef enum logic [4:0] {
    IDLE, SCAN_VOICE, READ_VOICE, WAIT_VOICE, START_VOICE, PROCESS_VOICE, REQ_L0, WAIT_L0, REQ_L1, WAIT_L1,
    REQ_R0, WAIT_R0, REQ_R1, WAIT_R1, DSP_START, DRAIN, FINISH
  } state_t;

  localparam int VOICE_INDEX_WIDTH = synth_pkg::VOICE_ID_WIDTH;
  localparam logic [VOICE_INDEX_WIDTH-1:0] LAST_VOICE = VOICE_INDEX_WIDTH'(NUM_VOICES - 1);
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

  typedef struct packed {
    logic [31:0] addr;
    logic [FETCH_SLOT_PTR_WIDTH-1:0] slot;
    endpoint_kind_t endpoint;
  } word_req_t;

  typedef struct packed {
    logic [FETCH_SLOT_PTR_WIDTH-1:0] slot;
    endpoint_kind_t endpoint;
  } rsp_meta_t;

  typedef struct packed {
    voice_dsp_context_t ctx;
    logic [2:0] pending;
  } fetch_slot_t;

  state_t state;
  logic [VOICE_INDEX_WIDTH-1:0] voice_index;
  logic [VOICE_INDEX_WIDTH-1:0] render_index;
  logic [NUM_VOICES-1:0] frame_commit;
  (* ram_style = "distributed" *) logic [PHASE_WIDTH-1:0] phase [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_WIDTH-1:0] phase_r [NUM_VOICES];
  logic [NUM_VOICES-1:0] phase_valid;
  logic [PHASE_WIDTH-1:0] phase_read;
  logic [PHASE_WIDTH-1:0] phase_r_read;
  logic phase_write_en;
  logic [PHASE_WIDTH-1:0] phase_write_data;
  logic [PHASE_WIDTH-1:0] phase_r_write_data;
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_l [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_l [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_r [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_r [NUM_VOICES];
  logic [NUM_VOICES-1:0] filter_state_valid;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_l_read;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_l_read;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_r_read;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_r_read;
  logic [PHASE_FRAME_WIDTH-1:0] frame_0;
  logic [PHASE_FRAME_WIDTH-1:0] frame_1;
  logic [PHASE_FRAME_WIDTH-1:0] frame_r0;
  logic [PHASE_FRAME_WIDTH-1:0] frame_r1;
  voice_dsp_context_t dsp_context;
  voice_dsp_context_t fetch_context;
  voice_dsp_context_t fetch_queue [FETCH_QUEUE_DEPTH];
  fetch_slot_t fetch_slots [FETCH_SLOT_DEPTH];
  word_req_t word_req_queue [WORD_REQ_DEPTH];
  rsp_meta_t rsp_meta_queue [WORD_REQ_DEPTH];
  voice_dsp_result_t dsp_result;
  logic [FETCH_QUEUE_PTR_WIDTH-1:0] fetch_queue_rd;
  logic [FETCH_QUEUE_PTR_WIDTH-1:0] fetch_queue_wr;
  logic [FETCH_QUEUE_COUNT_WIDTH-1:0] fetch_queue_count;
  logic [FETCH_SLOT_PTR_WIDTH-1:0] fetch_slot_wr;
  logic [FETCH_SLOT_COUNT_WIDTH-1:0] fetch_slot_count;
  logic [FETCH_SLOT_PTR_WIDTH-1:0] current_fetch_slot;
  logic [WORD_REQ_PTR_WIDTH-1:0] word_req_rd;
  logic [WORD_REQ_PTR_WIDTH-1:0] word_req_wr;
  logic [WORD_REQ_COUNT_WIDTH-1:0] word_req_count;
  logic [WORD_REQ_PTR_WIDTH-1:0] rsp_meta_rd;
  logic [WORD_REQ_PTR_WIDTH-1:0] rsp_meta_wr;
  logic [WORD_REQ_COUNT_WIDTH-1:0] rsp_meta_count;
  logic fetch_queue_empty;
  logic fetch_slot_full;
  logic fetch_slot_alloc;
  logic fetch_slot_complete;
  logic word_req_empty;
  logic word_req_full;
  logic rsp_meta_empty;
  logic rsp_meta_full;
  logic word_req_accept;
  logic rsp_meta_pop;
  logic enqueue_word_req;
  word_req_t enqueue_word_req_data;
  rsp_meta_t rsp_meta_head;
  voice_dsp_context_t allocated_fetch_context;
  voice_dsp_context_t completed_fetch_context;
  logic fetch_context_push;
  logic fetch_queue_pop;
  logic fetch_queue_store;
  logic dsp_issue_valid;
  logic dsp_valid;
  logic [VOICE_INDEX_WIDTH:0] outstanding_count;
  logic [VOICE_INDEX_WIDTH:0] outstanding_next;
  logic signed [31:0] accum_l;
  logic signed [31:0] accum_r;
  logic signed [31:0] next_accum_l;
  logic signed [31:0] next_accum_r;
  logic scan_at_last_voice;
  logic [32:0] phase_sum;
  logic [32:0] phase_r_sum;
  logic [32:0] loop_end_phase;
  logic [32:0] loop_end_phase_r;
  logic [31:0] loop_length_phase;
  logic [31:0] loop_length_phase_r;
  logic [31:0] wrapped_phase;
  logic [31:0] wrapped_phase_r;
  logic loop_active;
  logic voice_done_l;
  logic voice_done_r;
  logic voice_done;
  logic cfg_enable;
  logic cfg_stereo;
  logic [ADDR_WIDTH-1:0] cfg_base_addr;
  logic [ADDR_WIDTH-1:0] cfg_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_length;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_length_r;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_start_r;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_end;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_end_r;
  logic [PHASE_WIDTH-1:0] cfg_phase_inc;
  logic signed [15:0] cfg_gain_l;
  logic signed [15:0] cfg_gain_r;
  logic signed [15:0] cfg_envelope_level;
  logic [1:0] cfg_loop_mode;
  logic cfg_released;
  logic cfg_filter_enable;
  logic signed [31:0] cfg_filter_b0;
  logic signed [31:0] cfg_filter_b1;
  logic signed [31:0] cfg_filter_b2;
  logic signed [31:0] cfg_filter_a1;
  logic signed [31:0] cfg_filter_a2;
  logic current_enable;
  logic current_config_valid;
  logic current_commit;
  logic current_stereo;
  logic [ADDR_WIDTH-1:0] current_base_addr;
  logic [ADDR_WIDTH-1:0] current_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_length;
  logic [PHASE_FRAME_WIDTH-1:0] current_length_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_start_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_end;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_end_r;
  logic [PHASE_WIDTH-1:0] current_phase_inc;
  logic signed [15:0] current_gain_l;
  logic signed [15:0] current_gain_r;
  logic signed [15:0] current_envelope_level;
  logic [1:0] current_loop_mode;
  logic current_released;
  logic current_filter_enable;
  logic signed [31:0] current_filter_b0;
  logic signed [31:0] current_filter_b1;
  logic signed [31:0] current_filter_b2;
  logic signed [31:0] current_filter_a1;
  logic signed [31:0] current_filter_a2;
  logic [PHASE_WIDTH-1:0] current_phase;
  logic [PHASE_WIDTH-1:0] current_phase_r;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z1_l;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z2_l;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z1_r;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z2_r;
  logic prefetch_active;
  logic prefetch_done;
  logic prefetch_ready;
  logic [1:0] prefetch_wait;
  logic [VOICE_INDEX_WIDTH-1:0] prefetch_scan_index;
  logic [VOICE_INDEX_WIDTH-1:0] prefetch_index;

  function automatic pcm_t saturate_pcm(input logic signed [63:0] value);
    if (value > 64'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -64'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  assign voice_read_index = render_index;
  assign cfg_enable = voice_config.enable;
  assign cfg_stereo = voice_config.stereo;
  assign cfg_base_addr = voice_config.base_addr;
  assign cfg_base_addr_r = voice_config.base_addr_r;
  assign cfg_length = voice_config.length;
  assign cfg_length_r = voice_config.length_r;
  assign cfg_loop_start = voice_config.loop_start;
  assign cfg_loop_start_r = voice_config.loop_start_r;
  assign cfg_loop_end = voice_config.loop_end;
  assign cfg_loop_end_r = voice_config.loop_end_r;
  assign cfg_phase_inc = voice_runtime.phase_inc;
  assign cfg_gain_l = voice_runtime.gain_l;
  assign cfg_gain_r = voice_runtime.gain_r;
  assign cfg_envelope_level = voice_runtime.envelope_level;
  assign cfg_loop_mode = voice_config.loop_mode;
  assign cfg_released = voice_runtime.released;
  assign cfg_filter_enable = voice_runtime.filter_enable;
  assign cfg_filter_b0 = voice_runtime.filter_b0;
  assign cfg_filter_b1 = voice_runtime.filter_b1;
  assign cfg_filter_b2 = voice_runtime.filter_b2;
  assign cfg_filter_a1 = voice_runtime.filter_a1;
  assign cfg_filter_a2 = voice_runtime.filter_a2;
  always_comb begin
    phase_sum = {1'b0, current_phase} + {1'b0, current_phase_inc};
    phase_r_sum = {1'b0, current_phase_r} + {1'b0, current_phase_inc};
    loop_end_phase = {1'b0, current_loop_end, {PHASE_FRAC_WIDTH{1'b0}}};
    loop_end_phase_r = {1'b0, current_loop_end_r, {PHASE_FRAC_WIDTH{1'b0}}};
    loop_length_phase = {(current_loop_end - current_loop_start), {PHASE_FRAC_WIDTH{1'b0}}};
    loop_length_phase_r = {(current_loop_end_r - current_loop_start_r), {PHASE_FRAC_WIDTH{1'b0}}};
    wrapped_phase = phase_sum[31:0] - loop_length_phase;
    wrapped_phase_r = phase_r_sum[31:0] - loop_length_phase_r;
    loop_active = (current_loop_mode == LOOP_MODE_CONTINUOUS) ||
                  ((current_loop_mode == LOOP_MODE_UNTIL_RELEASE) && !current_released);
    voice_done_l = (current_loop_mode == LOOP_MODE_NONE || !loop_active) &&
                   (current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] >= current_length);
    voice_done_r = !current_stereo || ((current_loop_mode == LOOP_MODE_NONE || !loop_active) &&
                   (current_phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] >= current_length_r));
    voice_done = voice_done_l && voice_done_r;
    next_accum_l = accum_l + $signed({{16{dsp_result.contribution_l[15]}}, dsp_result.contribution_l});
    next_accum_r = accum_r + $signed({{16{dsp_result.contribution_r[15]}}, dsp_result.contribution_r});
    outstanding_next = outstanding_count + {{VOICE_INDEX_WIDTH{1'b0}}, dsp_issue_valid} -
                        {{VOICE_INDEX_WIDTH{1'b0}}, dsp_valid};
    scan_at_last_voice = (voice_index == LAST_VOICE);
    phase_write_en = fetch_slot_alloc;
    phase_write_data = (loop_active && phase_sum >= loop_end_phase) ? wrapped_phase : phase_sum[31:0];
    phase_r_write_data = (loop_active && phase_r_sum >= loop_end_phase_r) ? wrapped_phase_r : phase_r_sum[31:0];
  end

  always_comb begin
    fetch_queue_empty = (fetch_queue_count == '0);
    fetch_slot_full = (fetch_slot_count == FETCH_SLOT_COUNT_WIDTH'(FETCH_SLOT_DEPTH));
    fetch_slot_alloc = (state == PROCESS_VOICE) && current_enable && current_config_valid &&
                       !voice_done && !fetch_slot_full;

    allocated_fetch_context = '0;
    allocated_fetch_context.voice_index = voice_index;
    allocated_fetch_context.filter_enable = current_filter_enable;
    allocated_fetch_context.gain_l = current_gain_l;
    allocated_fetch_context.gain_r = current_gain_r;
    allocated_fetch_context.envelope_level = current_envelope_level;
    allocated_fetch_context.filter_b0 = current_filter_b0;
    allocated_fetch_context.filter_b1 = current_filter_b1;
    allocated_fetch_context.filter_b2 = current_filter_b2;
    allocated_fetch_context.filter_a1 = current_filter_a1;
    allocated_fetch_context.filter_a2 = current_filter_a2;
    allocated_fetch_context.filter_z1_l = current_filter_z1_l;
    allocated_fetch_context.filter_z2_l = current_filter_z2_l;
    allocated_fetch_context.filter_z1_r = current_filter_z1_r;
    allocated_fetch_context.filter_z2_r = current_filter_z2_r;
    allocated_fetch_context.fraction = current_phase[PHASE_FRAC_WIDTH-1:0];

    rsp_meta_head = rsp_meta_queue[rsp_meta_rd];
    completed_fetch_context = fetch_slots[rsp_meta_head.slot].ctx;

    unique case (rsp_meta_head.endpoint)
      ENDPOINT_L0: completed_fetch_context.raw_l0 = mem_rsp_data;
      ENDPOINT_L1: begin
        completed_fetch_context.raw_l1 = mem_rsp_data;
        if (fetch_slots[rsp_meta_head.slot].pending == 3'd1) begin
          completed_fetch_context.raw_r0 = fetch_slots[rsp_meta_head.slot].ctx.raw_l0;
          completed_fetch_context.raw_r1 = mem_rsp_data;
        end
      end
      ENDPOINT_R0: completed_fetch_context.raw_r0 = mem_rsp_data;
      ENDPOINT_R1: completed_fetch_context.raw_r1 = mem_rsp_data;
      default: begin
      end
    endcase

    fetch_context_push = rsp_meta_pop &&
                         (fetch_slots[rsp_meta_head.slot].pending == 3'd1);
    fetch_slot_complete = fetch_context_push;
    fetch_queue_pop = !fetch_queue_empty;
    fetch_queue_store = fetch_context_push && !fetch_queue_empty;
    dsp_issue_valid = fetch_queue_pop || (fetch_context_push && fetch_queue_empty);

    fetch_context = completed_fetch_context;

    dsp_context = fetch_queue_empty ? fetch_context : fetch_queue[fetch_queue_rd];
  end

  voice_dsp_pipeline dsp_pipeline (
    .clk,
    .rst,
    .valid_i(dsp_issue_valid),
    .context_i(dsp_context),
    .valid_o(dsp_valid),
    .result_o(dsp_result)
  );

  always_ff @(posedge clk) begin
    phase_read <= phase[render_index];
    phase_r_read <= phase_r[render_index];
    if (phase_write_en)
      phase[voice_index] <= phase_write_data;
    if (phase_write_en && current_stereo)
      phase_r[voice_index] <= phase_r_write_data;

    filter_z1_l_read <= filter_z1_l[render_index];
    filter_z2_l_read <= filter_z2_l[render_index];
    filter_z1_r_read <= filter_z1_r[render_index];
    filter_z2_r_read <= filter_z2_r[render_index];
    if (dsp_valid && dsp_result.filter_enable) begin
      filter_z1_l[dsp_result.voice_index] <= dsp_result.next_z1_l;
      filter_z2_l[dsp_result.voice_index] <= dsp_result.next_z2_l;
      filter_z1_r[dsp_result.voice_index] <= dsp_result.next_z1_r;
      filter_z2_r[dsp_result.voice_index] <= dsp_result.next_z2_r;
    end
  end

  always_comb begin
    word_req_empty = (word_req_count == '0);
    word_req_full = (word_req_count == WORD_REQ_COUNT_WIDTH'(WORD_REQ_DEPTH));
    rsp_meta_empty = (rsp_meta_count == '0);
    rsp_meta_full = (rsp_meta_count == WORD_REQ_COUNT_WIDTH'(WORD_REQ_DEPTH));
    word_req_accept = !word_req_empty && !rsp_meta_full && mem_req_ready;
    rsp_meta_pop = mem_rsp_valid && !rsp_meta_empty;

    busy = (state != IDLE);
    mem_req_valid = !word_req_empty && !rsp_meta_full;
    mem_req_addr = 32'd0;
    if (!word_req_empty)
      mem_req_addr = word_req_queue[word_req_rd].addr;

    enqueue_word_req = 1'b0;
    enqueue_word_req_data = '0;
    enqueue_word_req_data.slot = current_fetch_slot;
    unique case (state)
      REQ_L0: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_L0;
        enqueue_word_req_data.addr = current_base_addr + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_0};
      end
      REQ_L1: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_L1;
        enqueue_word_req_data.addr = current_base_addr + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_1};
      end
      REQ_R0: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_R0;
        enqueue_word_req_data.addr = current_base_addr_r + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_r0};
      end
      REQ_R1: begin
        enqueue_word_req = !word_req_full;
        enqueue_word_req_data.endpoint = ENDPOINT_R1;
        enqueue_word_req_data.addr = current_base_addr_r + {{(ADDR_WIDTH-PHASE_FRAME_WIDTH){1'b0}}, frame_r1};
      end
      default: begin
      end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      voice_index <= '0;
      render_index <= '0;
      frame_0 <= '0;
      frame_1 <= '0;
      frame_r0 <= '0;
      frame_r1 <= '0;
      current_stereo <= 1'b0;
      current_base_addr <= '0;
      current_base_addr_r <= '0;
      current_enable <= 1'b0;
      current_config_valid <= 1'b0;
      current_commit <= 1'b0;
      current_length <= '0;
      current_length_r <= '0;
      current_loop_start <= '0;
      current_loop_start_r <= '0;
      current_loop_end <= '0;
      current_loop_end_r <= '0;
      current_phase <= '0;
      current_phase_r <= '0;
      current_phase_inc <= '0;
      current_gain_l <= '0;
      current_gain_r <= '0;
      current_envelope_level <= '0;
      current_loop_mode <= LOOP_MODE_NONE;
      current_released <= 1'b0;
      current_filter_enable <= 1'b0;
      current_filter_b0 <= '0;
      current_filter_b1 <= '0;
      current_filter_b2 <= '0;
      current_filter_a1 <= '0;
      current_filter_a2 <= '0;
      current_filter_z1_l <= '0;
      current_filter_z2_l <= '0;
      current_filter_z1_r <= '0;
      current_filter_z2_r <= '0;
      fetch_queue_rd <= '0;
      fetch_queue_wr <= '0;
      fetch_queue_count <= '0;
      for (int q = 0; q < FETCH_QUEUE_DEPTH; q++)
        fetch_queue[q] <= '0;
      fetch_slot_wr <= '0;
      fetch_slot_count <= '0;
      current_fetch_slot <= '0;
      for (int s = 0; s < FETCH_SLOT_DEPTH; s++)
        fetch_slots[s] <= '0;
      word_req_rd <= '0;
      word_req_wr <= '0;
      word_req_count <= '0;
      for (int w = 0; w < WORD_REQ_DEPTH; w++)
        word_req_queue[w] <= '0;
      rsp_meta_rd <= '0;
      rsp_meta_wr <= '0;
      rsp_meta_count <= '0;
      for (int m = 0; m < WORD_REQ_DEPTH; m++)
        rsp_meta_queue[m] <= '0;
      prefetch_active <= 1'b0;
      prefetch_done <= 1'b0;
      prefetch_ready <= 1'b0;
      prefetch_wait <= '0;
      prefetch_scan_index <= '0;
      prefetch_index <= '0;
      accum_l <= 32'sd0;
      accum_r <= 32'sd0;
      outstanding_count <= '0;
      sample_valid <= 1'b0;
      sample_l <= '0;
      sample_r <= '0;
      frame_commit <= '0;
      phase_valid <= '0;
      filter_state_valid <= '0;
    end else begin
      sample_valid <= 1'b0;

      if (fetch_queue_pop)
        fetch_queue_rd <= fetch_queue_rd + 1'b1;
      if (fetch_queue_store) begin
        fetch_queue[fetch_queue_wr] <= fetch_context;
        fetch_queue_wr <= fetch_queue_wr + 1'b1;
      end
      unique case ({fetch_queue_store, fetch_queue_pop})
        2'b10: fetch_queue_count <= fetch_queue_count + 1'b1;
        2'b01: fetch_queue_count <= fetch_queue_count - 1'b1;
        default: begin
        end
      endcase

      if (fetch_slot_alloc) begin
        current_fetch_slot <= fetch_slot_wr;
        fetch_slots[fetch_slot_wr].ctx <= allocated_fetch_context;
        fetch_slots[fetch_slot_wr].pending <= current_stereo ? 3'd4 : 3'd2;
        fetch_slot_wr <= fetch_slot_wr + 1'b1;
      end
      if (rsp_meta_pop) begin
        fetch_slots[rsp_meta_head.slot].ctx <= completed_fetch_context;
        fetch_slots[rsp_meta_head.slot].pending <= fetch_slots[rsp_meta_head.slot].pending - 3'd1;
        rsp_meta_rd <= rsp_meta_rd + 1'b1;
      end
      unique case ({fetch_slot_alloc, fetch_slot_complete})
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

      if (dsp_valid) begin
        if (dsp_result.filter_enable)
          filter_state_valid[dsp_result.voice_index] <= 1'b1;
        accum_l <= next_accum_l;
        accum_r <= next_accum_r;
      end
      outstanding_count <= outstanding_next;

      if (prefetch_active) begin
        if (prefetch_wait != 2'd0) begin
          prefetch_wait <= prefetch_wait - 2'd1;
          if (prefetch_wait == 2'd1) begin
            prefetch_ready <= 1'b1;
            prefetch_done <= 1'b1;
            prefetch_active <= 1'b0;
          end
        end else if (config_valid[prefetch_scan_index]) begin
          prefetch_index <= prefetch_scan_index;
          render_index <= prefetch_scan_index;
          prefetch_wait <= 2'd2;
        end else if (prefetch_scan_index == LAST_VOICE) begin
          prefetch_done <= 1'b1;
          prefetch_active <= 1'b0;
        end else begin
          prefetch_scan_index <= prefetch_scan_index + 1'b1;
        end
      end

      unique case (state)
        IDLE: begin
          if (sample_tick) begin
            accum_l <= 32'sd0;
            accum_r <= 32'sd0;
            outstanding_count <= '0;
            frame_commit <= config_commit;
            voice_index <= '0;
            render_index <= '0;
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            state <= SCAN_VOICE;
          end
        end
        SCAN_VOICE: begin
          if (config_valid[voice_index]) begin
            render_index <= voice_index;
            state <= READ_VOICE;
          end else if (scan_at_last_voice) begin
            state <= DRAIN;
          end else begin
            voice_index <= voice_index + 1'b1;
          end
        end
        READ_VOICE: begin
          state <= WAIT_VOICE;
        end
        WAIT_VOICE: begin
          state <= START_VOICE;
        end
        START_VOICE: begin
          current_enable <= cfg_enable;
          current_config_valid <= config_valid[voice_index];
          current_commit <= frame_commit[voice_index];
          current_stereo <= cfg_stereo;
          current_base_addr <= cfg_base_addr;
          current_base_addr_r <= cfg_base_addr_r;
          current_length <= cfg_length;
          current_length_r <= cfg_length_r;
          current_loop_start <= cfg_loop_start;
          current_loop_start_r <= cfg_loop_start_r;
          current_loop_end <= cfg_loop_end;
          current_loop_end_r <= cfg_loop_end_r;
          current_phase <= frame_commit[voice_index] ? voice_config.phase_init :
                           (phase_valid[voice_index] ? phase_read : '0);
          current_phase_r <= frame_commit[voice_index] ? voice_config.phase_init :
                             (phase_valid[voice_index] ? phase_r_read : '0);
          current_phase_inc <= cfg_phase_inc;
          current_gain_l <= cfg_gain_l;
          current_gain_r <= cfg_gain_r;
          current_envelope_level <= cfg_envelope_level;
          current_loop_mode <= cfg_loop_mode;
          current_released <= cfg_released;
          current_filter_enable <= cfg_filter_enable;
          current_filter_b0 <= cfg_filter_b0;
          current_filter_b1 <= cfg_filter_b1;
          current_filter_b2 <= cfg_filter_b2;
          current_filter_a1 <= cfg_filter_a1;
          current_filter_a2 <= cfg_filter_a2;
          current_filter_z1_l <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z1_l_read;
          current_filter_z2_l <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z2_l_read;
          current_filter_z1_r <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z1_r_read;
          current_filter_z2_r <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z2_r_read;
          prefetch_ready <= 1'b0;
          prefetch_done <= (voice_index == LAST_VOICE);
          prefetch_active <= (voice_index != LAST_VOICE);
          prefetch_scan_index <= voice_index + 1'b1;
          prefetch_wait <= '0;
          state <= PROCESS_VOICE;
        end
        PROCESS_VOICE: begin
          if (!current_enable || !current_config_valid || voice_done) begin
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            if (scan_at_last_voice) begin
              state <= DRAIN;
            end else begin
              voice_index <= voice_index + 1'b1;
              state <= SCAN_VOICE;
            end
          end else if (!fetch_slot_full) begin
            if (current_commit)
              filter_state_valid[voice_index] <= 1'b0;
            if (voice_done_l) begin
              frame_0 <= current_length - 24'd1;
              frame_1 <= current_length - 24'd1;
            end else begin
              frame_0 <= current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH];
              if (loop_active)
                frame_1 <= (current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1 >= current_loop_end) ?
                           current_loop_start : current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1;
              else
                frame_1 <= (current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1 >= current_length) ?
                           current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] : current_phase[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1;
            end

            if (!current_stereo || voice_done_r) begin
              frame_r0 <= current_stereo ? (current_length_r - 24'd1) : '0;
              frame_r1 <= current_stereo ? (current_length_r - 24'd1) : '0;
            end else begin
              frame_r0 <= current_phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH];
              if (loop_active)
                frame_r1 <= (current_phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1 >= current_loop_end_r) ?
                            current_loop_start_r : current_phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1;
              else
                frame_r1 <= (current_phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1 >= current_length_r) ?
                            current_phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] : current_phase_r[PHASE_WIDTH-1:PHASE_FRAC_WIDTH] + 24'd1;
            end
            phase_valid[voice_index] <= 1'b1;
            state <= REQ_L0;
          end
        end
        REQ_L0: if (enqueue_word_req) state <= REQ_L1;
        REQ_L1: if (enqueue_word_req) state <= current_stereo ? REQ_R0 : DSP_START;
        REQ_R0: if (enqueue_word_req) state <= REQ_R1;
        REQ_R1: if (enqueue_word_req) state <= DSP_START;
        DSP_START: begin
          if (scan_at_last_voice)
            state <= DRAIN;
          else if (prefetch_ready) begin
            voice_index <= prefetch_index;
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            state <= START_VOICE;
          end else if (prefetch_done) begin
            state <= DRAIN;
          end
          else begin
            voice_index <= voice_index + 1'b1;
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            state <= SCAN_VOICE;
          end
        end
        DRAIN: begin
          if (outstanding_next == '0 && fetch_slot_count == '0 && fetch_queue_count == '0 &&
              word_req_count == '0 && rsp_meta_count == '0)
            state <= FINISH;
        end
        FINISH: begin
          sample_l <= saturate_pcm({{32{accum_l[31]}}, accum_l});
          sample_r <= saturate_pcm({{32{accum_r[31]}}, accum_r});
          sample_valid <= 1'b1;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
