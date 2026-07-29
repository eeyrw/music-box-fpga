module block_interleaved_voice_renderer (
  input  logic                                      clk,
  input  logic                                      rst,

  input  logic                                      start_valid,
  output logic                                      start_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      start_voice_index,
  input  logic [synth_pkg::BLOCK_FRAME_COUNT_WIDTH-1:0]
                                                    start_frame_count,
  input  logic [synth_pkg::MAX_BLOCK_FRAMES-1:0]    start_phase_advance_mask,
  input  logic [synth_pkg::MAX_BLOCK_FRAMES-1:0]    start_render_mask,
  input  logic signed [synth_pkg::MAX_BLOCK_FRAMES-1:0][15:0]
                                                    start_envelope_levels,
  input  logic                                      start_active,
  input  logic [synth_pkg::VOICE_GENERATION_WIDTH-1:0]
                                                    start_generation,
  input  logic [synth_pkg::PHASE_WIDTH-1:0]         start_phase,
  input  synth_pkg::voice_playback_region_t         start_region,
  input  synth_pkg::voice_event_params_t            start_params,
  input  logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0]
                                                    start_filter_z1,
  input  logic signed [synth_pkg::FILTER_STATE_WIDTH-1:0]
                                                    start_filter_z2,
  input  logic                                      start_env_active,
  input  synth_pkg::volume_env_state_t              start_env_state,

  output logic                                      line_req_valid,
  input  logic                                      line_req_ready,
  output synth_pkg::ordered_line_req_t              line_req,
  input  logic                                      line_rsp_valid,
  output logic                                      line_rsp_ready,
  input  synth_pkg::ordered_line_rsp_t              line_rsp,

  output logic                                      contribution_valid,
  input  logic                                      contribution_ready,
  output synth_pkg::block_voice_contribution_t      contribution,

  output logic                                      result_valid,
  input  logic                                      result_ready,
  output synth_pkg::block_voice_dsp_result_t        result,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]      result_voice_index,
  output logic                                      result_env_active,
  output synth_pkg::volume_env_state_t              result_env_state
);
  import synth_pkg::*;

  localparam int ENDPOINT_COUNT = MAX_BLOCK_FRAMES * BLOCK_ENDPOINT_COUNT;
  localparam int LINE_SHIFT = $clog2(BLOCK_LINE_WORDS);
  localparam int LINE_ADDR_WIDTH = ADDR_WIDTH - LINE_SHIFT;
  localparam int JOB_RAM_DEPTH =
      BLOCK_WORK_ENTRY_COUNT * MAX_BLOCK_FRAMES;
  localparam int JOB_RAM_ADDR_WIDTH = $clog2(JOB_RAM_DEPTH);
  localparam int MEMORY_SCAN_GROUP_SIZE = 4;
  localparam int MEMORY_SCAN_GROUP_COUNT =
      ENDPOINT_COUNT / MEMORY_SCAN_GROUP_SIZE;
  localparam int MEMORY_SCAN_GROUP_WIDTH =
      $clog2(MEMORY_SCAN_GROUP_COUNT);
  localparam int ENDPOINT_BANK_DEPTH =
      BLOCK_WORK_ENTRY_COUNT * MEMORY_SCAN_GROUP_COUNT;
  localparam int ENDPOINT_BANK_ADDR_WIDTH = $clog2(ENDPOINT_BANK_DEPTH);
  localparam int ENDPOINT_INDEX_WIDTH = $clog2(ENDPOINT_COUNT);

  typedef enum logic [3:0] {
    WORK_FREE,
    WORK_PLAN,
    WORK_PLAN_CALC,
    WORK_MEM_WAIT,
    WORK_MEM_FETCH,
    WORK_READY,
    WORK_DRAIN,
    WORK_COMPLETE,
    WORK_PLAN_FINAL
  } work_state_t;

  typedef struct packed {
    logic [BLOCK_FRAME_INDEX_WIDTH-1:0] block_frame_index;
    logic [PHASE_FRAC_WIDTH-1:0] fraction;
    logic signed [15:0] envelope_level;
  } job_payload_t;
  localparam int JOB_PAYLOAD_WIDTH = $bits(job_payload_t);

  work_state_t work_state_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  block_voice_context_t work_context_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0]
      work_endpoint_addr_bank_0 [0:ENDPOINT_BANK_DEPTH-1];
  (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0]
      work_endpoint_addr_bank_1 [0:ENDPOINT_BANK_DEPTH-1];
  (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0]
      work_endpoint_addr_bank_2 [0:ENDPOINT_BANK_DEPTH-1];
  (* ram_style = "distributed" *) logic [ADDR_WIDTH-1:0]
      work_endpoint_addr_bank_3 [0:ENDPOINT_BANK_DEPTH-1];
  (* ram_style = "block" *) logic [JOB_PAYLOAD_WIDTH-1:0]
      work_job_payload_mem
      [0:JOB_RAM_DEPTH-1];
  pcm_t work_endpoint_sample_q
      [0:BLOCK_WORK_ENTRY_COUNT-1][0:ENDPOINT_COUNT-1];
  logic [ENDPOINT_COUNT-1:0] work_endpoint_valid_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [ENDPOINT_COUNT-1:0] work_endpoint_pending_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [ENDPOINT_COUNT-1:0] work_endpoint_required_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic work_window_checked_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] work_job_count_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] work_issue_index_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] work_frame_count_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] work_frame_cursor_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [MAX_BLOCK_FRAMES-1:0] work_phase_advance_mask_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [MAX_BLOCK_FRAMES-1:0] work_render_mask_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic signed [MAX_BLOCK_FRAMES-1:0][15:0] work_envelope_levels_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic work_active_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [PHASE_WIDTH-1:0] work_phase_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  voice_playback_region_t work_region_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic [PHASE_WIDTH-1:0] work_phase_inc_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic work_released_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  block_phase_result_t work_phase_result_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic signed [FILTER_STATE_WIDTH-1:0] work_z1_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic signed [FILTER_STATE_WIDTH-1:0] work_z2_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic work_hazard_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  logic work_env_active_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  volume_env_state_t work_env_state_q [0:BLOCK_WORK_ENTRY_COUNT-1];

  logic [BLOCK_WORK_ID_WIDTH-1:0] plan_rr_q;
  logic plan_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] plan_work_id;
  logic plan_current_done;
  logic [PHASE_FRAME_WIDTH-1:0] plan_frame_0;
  logic [PHASE_FRAME_WIDTH-1:0] plan_frame_1;
  logic [PHASE_FRAC_WIDTH-1:0] plan_fraction;
  logic [PHASE_WIDTH-1:0] plan_next_phase;
  logic plan_store_job;
  logic plan_step_finishes;
  logic work_phase_candidate_active_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  typedef struct packed {
    logic valid;
    logic finalize;
    logic [BLOCK_WORK_ID_WIDTH-1:0] work_id;
    logic active;
    logic [PHASE_WIDTH-1:0] phase;
    voice_playback_region_t region;
    logic [PHASE_WIDTH-1:0] phase_inc;
    logic released;
    logic [BLOCK_FRAME_COUNT_WIDTH-1:0] frame_count;
    logic [BLOCK_FRAME_COUNT_WIDTH-1:0] frame_cursor;
    logic [BLOCK_FRAME_COUNT_WIDTH-1:0] job_count;
    logic phase_advance;
    logic render;
    logic signed [15:0] envelope_level;
  } plan_stage_t;
  plan_stage_t plan_q;

  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_rr_q;
  logic memory_candidate_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_candidate_work_id;
  logic memory_select_valid_q;
  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_select_work_id_q;
  logic memory_scan_mask_phase_q;
  logic [MEMORY_SCAN_GROUP_WIDTH-1:0] memory_scan_group_q;
  logic memory_scan_find_found;
  logic [LINE_ADDR_WIDTH-1:0] memory_scan_find_line_addr;
  logic [LINE_ADDR_WIDTH-1:0] memory_scan_line_addr_q;
  logic [ENDPOINT_BANK_ADDR_WIDTH-1:0] memory_scan_bank_addr;
  logic [ADDR_WIDTH-1:0] memory_scan_group_addr
      [0:MEMORY_SCAN_GROUP_SIZE-1];
  logic [ENDPOINT_COUNT-1:0] memory_scan_group_mask;
  logic [LINE_SHIFT-1:0] memory_scan_group_word_index
      [0:ENDPOINT_COUNT-1];
  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_work_id;
  logic memory_request_valid_q;
  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_request_work_id_q;
  logic [ENDPOINT_COUNT-1:0] memory_request_line_mask_q;
  logic [LINE_SHIFT-1:0] memory_request_word_index_q
      [0:ENDPOINT_COUNT-1];
  logic [LINE_ADDR_WIDTH-1:0] memory_request_line_addr_q;
  logic [VOICE_ID_WIDTH-1:0] memory_request_voice_q;
  logic memory_request_refill_q;
  logic memory_action;
  logic [ENDPOINT_COUNT-1:0] response_line_mask_q;
  logic [LINE_SHIFT-1:0] response_word_index_q
      [0:ENDPOINT_COUNT-1];
  logic cache_req_valid;
  logic cache_req_ready;
  logic [ADDR_WIDTH-1:0] cache_req_addr;
  logic [BLOCK_WORK_ID_WIDTH-1:0] cache_req_tag;
  logic [VOICE_ID_WIDTH-1:0] cache_req_voice;
  logic cache_req_refill;
  logic cache_rsp_valid;
  logic [ADDR_WIDTH-1:0] cache_rsp_addr;
  logic [BLOCK_WORK_ID_WIDTH-1:0] cache_rsp_tag;
  ordered_line_rsp_t cache_rsp;
  logic [63:0] cache_stat_client_requests;
  logic [63:0] cache_stat_cache_hits;
  logic [63:0] cache_stat_mshr_merges;
  logic [63:0] cache_stat_memory_misses;
  logic [63:0] cache_stat_evictions;
  logic [63:0] cache_stat_miss_stall_cycles;
  logic [63:0] cache_stat_window_refills;
  logic [63:0] cache_stat_fallback_reads;

  logic free_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] free_work_id;
  logic start_fire;
  logic [BLOCK_WORK_ID_WIDTH-1:0] issue_rr_q;
  logic issue_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] issue_candidate_work_id;
  logic issue_endpoints_ready;
  logic issue_select_valid_q;
  logic [BLOCK_WORK_ID_WIDTH-1:0] issue_select_work_id_q;
  logic [BLOCK_FRAME_INDEX_WIDTH-1:0] issue_select_job_index_q;
  job_payload_t issue_job_payload_q;
  logic issue_select_capture;

  block_dsp_sample_token_t dsp_token;
  logic dsp_token_valid;
  logic dsp_token_ready;
  block_dsp_sample_token_t dsp_token_q;
  block_dsp_sample_token_t dsp_token_q_next;
  logic dsp_token_valid_q;
  logic issue_token_slot_ready;
  logic issue_capture;
  block_dsp_state_update_t dsp_state_update;
  logic dsp_state_update_valid;
  block_dsp_retire_t dsp_retire;
  logic dsp_retire_valid;
  logic dsp_retire_ready;

  logic complete_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] complete_work_id;
  logic result_slot_available;
  logic dsp_last_publish;
  logic complete_publish;
  logic result_valid_q;
  block_voice_dsp_result_t result_q;
  logic [VOICE_ID_WIDTH-1:0] result_voice_index_q;
  logic result_env_active_q;
  volume_env_state_t result_env_state_q;

  mono_phase_frame plan_phase_frame (
    .loop_mode(plan_q.region.loop_mode),
    .released(plan_q.released),
    .phase(plan_q.phase),
    .phase_inc(plan_q.phase_inc),
    .length(plan_q.region.length),
    .loop_start(plan_q.region.loop_start),
    .loop_end(plan_q.region.loop_end),
    .done(plan_current_done),
    .frame_0(plan_frame_0),
    .frame_1(plan_frame_1),
    .fraction(plan_fraction),
    .next_phase(plan_next_phase)
  );

  block_interleaved_voice_dsp dsp (
    .clk,
    .rst,
    .token_valid(dsp_token_valid),
    .token_ready(dsp_token_ready),
    .token(dsp_token),
    .state_update_valid(dsp_state_update_valid),
    .state_update(dsp_state_update),
    .retire_valid(dsp_retire_valid),
    .retire_ready(dsp_retire_ready),
    .retire(dsp_retire)
  );

  voice_sample_window #(
    .WINDOW_WORDS(32),
    .TAG_COUNT(BLOCK_WORK_ENTRY_COUNT),
    .TAG_WIDTH(BLOCK_WORK_ID_WIDTH)
  ) line_cache (
    .clk,
    .rst,
    .client_req_valid(cache_req_valid),
    .client_req_ready(cache_req_ready),
    .client_req_addr(cache_req_addr),
    .client_req_tag(cache_req_tag),
    .client_req_voice(cache_req_voice),
    .client_req_refill(cache_req_refill),
    .client_rsp_valid(cache_rsp_valid),
    .client_rsp_ready(1'b1),
    .client_rsp_addr(cache_rsp_addr),
    .client_rsp_tag(cache_rsp_tag),
    .client_rsp(cache_rsp),
    .memory_req_valid(line_req_valid),
    .memory_req_ready(line_req_ready),
    .memory_req(line_req),
    .memory_rsp_valid(line_rsp_valid),
    .memory_rsp_ready(line_rsp_ready),
    .memory_rsp(line_rsp),
    .stat_client_requests(cache_stat_client_requests),
    .stat_window_hits(cache_stat_cache_hits),
    .stat_window_refills(cache_stat_window_refills),
    .stat_fallback_reads(cache_stat_fallback_reads),
    .stat_memory_reads(cache_stat_memory_misses),
    .stat_evictions(cache_stat_evictions),
    .stat_stall_cycles(cache_stat_miss_stall_cycles)
  );

  assign cache_stat_mshr_merges = '0;

  assign start_fire = start_valid && start_ready;
  assign memory_action = cache_req_valid && cache_req_ready;

  always_comb begin
    plan_found = 1'b0;
    plan_work_id = '0;
    for (int offset = 0; offset < BLOCK_WORK_ENTRY_COUNT; offset++) begin
      logic [BLOCK_WORK_ID_WIDTH-1:0] candidate;
      candidate = plan_rr_q + BLOCK_WORK_ID_WIDTH'(offset);
      if (!plan_found && ((work_state_q[candidate] == WORK_PLAN) ||
                          (work_state_q[candidate] == WORK_PLAN_FINAL))) begin
        plan_found = 1'b1;
        plan_work_id = candidate;
      end
    end
  end

  always_comb begin
    result_slot_available = !result_valid_q || result_ready;
    dsp_retire_ready = contribution_ready &&
        (!dsp_retire.last || result_slot_available);
    dsp_last_publish = dsp_retire_valid && dsp_retire_ready && dsp_retire.last;

    complete_found = 1'b0;
    complete_work_id = '0;
    for (int entry = 0; entry < BLOCK_WORK_ENTRY_COUNT; entry++) begin
      if (!complete_found && (work_state_q[entry] == WORK_COMPLETE)) begin
        complete_found = 1'b1;
        complete_work_id = BLOCK_WORK_ID_WIDTH'(entry);
      end
    end
    complete_publish = complete_found && result_slot_available &&
                       !dsp_last_publish;

    free_found = 1'b0;
    free_work_id = '0;
    for (int entry = 0; entry < BLOCK_WORK_ENTRY_COUNT; entry++) begin
      if (!free_found && (work_state_q[entry] == WORK_FREE)) begin
        free_found = 1'b1;
        free_work_id = BLOCK_WORK_ID_WIDTH'(entry);
      end
    end
    if (!free_found && dsp_last_publish) begin
      free_found = 1'b1;
      free_work_id = dsp_retire.work_id;
    end else if (!free_found && complete_publish) begin
      free_found = 1'b1;
      free_work_id = complete_work_id;
    end
    start_ready = free_found;

    plan_store_job = plan_q.valid && plan_q.active &&
        !plan_current_done &&
        (plan_q.frame_cursor < plan_q.frame_count) &&
        plan_q.phase_advance && plan_q.render;
    plan_step_finishes = plan_q.valid &&
        ((!plan_q.active) || plan_current_done ||
         (plan_q.frame_cursor >= plan_q.frame_count) ||
         !plan_q.phase_advance ||
         ((plan_q.frame_cursor + 1'b1) >= plan_q.frame_count));

    memory_candidate_found = 1'b0;
    memory_candidate_work_id = '0;
    for (int offset = 0; offset < BLOCK_WORK_ENTRY_COUNT; offset++) begin
      logic [BLOCK_WORK_ID_WIDTH-1:0] candidate;
      logic [ENDPOINT_COUNT-1:0] missing_endpoints;
      candidate = memory_rr_q + BLOCK_WORK_ID_WIDTH'(offset);
      missing_endpoints = work_endpoint_required_q[candidate] &
                          ~work_endpoint_valid_q[candidate] &
                          ~work_endpoint_pending_q[candidate];
      if (!memory_candidate_found &&
          ((work_state_q[candidate] == WORK_MEM_WAIT) ||
           (work_state_q[candidate] == WORK_MEM_FETCH)) &&
          (missing_endpoints != '0)) begin
        memory_candidate_found = 1'b1;
        memory_candidate_work_id = candidate;
      end
    end

    memory_scan_find_found = 1'b0;
    memory_scan_find_line_addr = '0;
    memory_scan_group_mask = '0;
    memory_scan_bank_addr =
        (ENDPOINT_BANK_ADDR_WIDTH'(memory_select_work_id_q) <<
         MEMORY_SCAN_GROUP_WIDTH) |
        ENDPOINT_BANK_ADDR_WIDTH'(memory_scan_group_q);
    memory_scan_group_addr[0] =
        work_endpoint_addr_bank_0[memory_scan_bank_addr];
    memory_scan_group_addr[1] =
        work_endpoint_addr_bank_1[memory_scan_bank_addr];
    memory_scan_group_addr[2] =
        work_endpoint_addr_bank_2[memory_scan_bank_addr];
    memory_scan_group_addr[3] =
        work_endpoint_addr_bank_3[memory_scan_bank_addr];
    for (int endpoint = 0; endpoint < ENDPOINT_COUNT; endpoint++) begin
      memory_scan_group_word_index[endpoint] = '0;
    end
    for (int lane = 0; lane < MEMORY_SCAN_GROUP_SIZE; lane++) begin
      logic endpoint_missing;
      logic [ENDPOINT_INDEX_WIDTH-1:0] endpoint_index;
      endpoint_index = ENDPOINT_INDEX_WIDTH'(
          (int'(memory_scan_group_q) * MEMORY_SCAN_GROUP_SIZE) + lane);
      endpoint_missing = memory_select_valid_q &&
          work_endpoint_required_q[memory_select_work_id_q][endpoint_index] &&
          !work_endpoint_valid_q[memory_select_work_id_q][endpoint_index] &&
          !work_endpoint_pending_q[memory_select_work_id_q][endpoint_index];
      if (!memory_scan_mask_phase_q && !memory_scan_find_found &&
          endpoint_missing) begin
        memory_scan_find_found = 1'b1;
        memory_scan_find_line_addr =
            memory_scan_group_addr[lane][ADDR_WIDTH-1:LINE_SHIFT];
      end
      if (memory_scan_mask_phase_q && endpoint_missing &&
          (memory_scan_group_addr[lane][ADDR_WIDTH-1:LINE_SHIFT] ==
           memory_scan_line_addr_q)) begin
        memory_scan_group_mask[endpoint_index] = 1'b1;
        memory_scan_group_word_index[endpoint_index] =
            memory_scan_group_addr[lane][LINE_SHIFT-1:0];
      end
    end

    memory_work_id = memory_request_work_id_q;
    cache_req_valid = memory_request_valid_q;
    cache_req_addr = {memory_request_line_addr_q, {LINE_SHIFT{1'b0}}};
    cache_req_tag = memory_request_work_id_q;
    cache_req_voice = memory_request_voice_q;
    cache_req_refill = memory_request_refill_q;

    issue_found = 1'b0;
    issue_candidate_work_id = '0;
    issue_endpoints_ready = 1'b0;
    issue_token_slot_ready = !dsp_token_valid_q || dsp_token_ready;
    for (int offset = 0; offset < BLOCK_WORK_ENTRY_COUNT; offset++) begin
      logic [BLOCK_WORK_ID_WIDTH-1:0] candidate;
      logic hazard_resolves;
      logic endpoints_ready;
      logic [BLOCK_FRAME_INDEX_WIDTH-1:0] job_index;
      candidate = issue_rr_q + BLOCK_WORK_ID_WIDTH'(offset);
      job_index = work_issue_index_q[candidate]
          [BLOCK_FRAME_INDEX_WIDTH-1:0];
      hazard_resolves = dsp_state_update_valid &&
                        (dsp_state_update.work_id == candidate);
      endpoints_ready =
          work_endpoint_valid_q[candidate][{job_index, 1'b0}] &&
          work_endpoint_valid_q[candidate][{job_index, 1'b1}];
      if (!issue_found && !issue_select_valid_q && endpoints_ready &&
          (!work_hazard_q[candidate] || hazard_resolves) &&
          (((work_state_q[candidate] == WORK_MEM_WAIT) ||
            (work_state_q[candidate] == WORK_MEM_FETCH) ||
            (work_state_q[candidate] == WORK_READY)) &&
           (work_issue_index_q[candidate] < work_job_count_q[candidate]))) begin
        issue_found = 1'b1;
        issue_candidate_work_id = candidate;
        issue_endpoints_ready = endpoints_ready;
      end
    end

    issue_select_capture = issue_found && issue_endpoints_ready &&
                           !issue_select_valid_q;
    issue_capture = issue_select_valid_q && issue_token_slot_ready;
    dsp_token_valid = dsp_token_valid_q;
    dsp_token = dsp_token_q;

    dsp_token_q_next = '0;
    dsp_token_q_next.work_id = issue_select_work_id_q;
    dsp_token_q_next.last = (work_issue_index_q[issue_select_work_id_q] + 1'b1) >=
                            work_job_count_q[issue_select_work_id_q];
    dsp_token_q_next.voice_context = work_context_q[issue_select_work_id_q];
    dsp_token_q_next.sample.job.block_frame_index =
        issue_job_payload_q.block_frame_index;
    dsp_token_q_next.sample.job.fraction = issue_job_payload_q.fraction;
    dsp_token_q_next.sample.job.endpoint_mask = '1;
    dsp_token_q_next.sample.job.endpoint_addr = '0;
    dsp_token_q_next.sample.job.envelope_level =
        issue_job_payload_q.envelope_level;
    dsp_token_q_next.sample.sample_0 =
        work_endpoint_sample_q[issue_select_work_id_q][
            {issue_select_job_index_q, 1'b0}];
    dsp_token_q_next.sample.sample_1 =
        work_endpoint_sample_q[issue_select_work_id_q][
            {issue_select_job_index_q, 1'b1}];
    dsp_token_q_next.filter_z1 =
        (dsp_state_update_valid &&
         (dsp_state_update.work_id == issue_select_work_id_q)) ?
        dsp_state_update.filter_z1 : work_z1_q[issue_select_work_id_q];
    dsp_token_q_next.filter_z2 =
        (dsp_state_update_valid &&
         (dsp_state_update.work_id == issue_select_work_id_q)) ?
        dsp_state_update.filter_z2 : work_z2_q[issue_select_work_id_q];

    contribution_valid = dsp_retire_valid;
    contribution = dsp_retire.contribution;
    result_valid = result_valid_q;
    result = result_q;
    result_voice_index = result_voice_index_q;
    result_env_active = result_env_active_q;
    result_env_state = result_env_state_q;
  end

  integer endpoint;
  always_ff @(posedge clk) begin
    if (rst) begin
      plan_rr_q <= '0;
      plan_q.valid <= 1'b0;
      memory_rr_q <= '0;
      memory_select_valid_q <= 1'b0;
      memory_scan_mask_phase_q <= 1'b0;
      memory_scan_group_q <= '0;
      memory_request_valid_q <= 1'b0;
      issue_rr_q <= '0;
      issue_select_valid_q <= 1'b0;
      dsp_token_valid_q <= 1'b0;
      result_valid_q <= 1'b0;
      for (int entry = 0; entry < BLOCK_WORK_ENTRY_COUNT; entry++) begin
        work_state_q[entry] <= WORK_FREE;
      end
    end else begin
      plan_q.valid <= plan_found;
      if (!memory_select_valid_q && !memory_request_valid_q &&
          memory_candidate_found) begin
        memory_select_valid_q <= 1'b1;
        memory_select_work_id_q <= memory_candidate_work_id;
        memory_scan_mask_phase_q <= 1'b0;
        memory_scan_group_q <= '0;
        memory_request_line_mask_q <= '0;
      end else if (memory_select_valid_q) begin
        if (!memory_scan_mask_phase_q) begin
          if (memory_scan_find_found) begin
            memory_scan_mask_phase_q <= 1'b1;
            memory_scan_line_addr_q <= memory_scan_find_line_addr;
            memory_request_line_mask_q <= '0;
          end else if (memory_scan_group_q ==
                       MEMORY_SCAN_GROUP_WIDTH'(MEMORY_SCAN_GROUP_COUNT - 1)) begin
            memory_select_valid_q <= 1'b0;
            memory_scan_group_q <= '0;
          end else begin
            memory_scan_group_q <= memory_scan_group_q + 1'b1;
          end
        end else begin
          memory_request_line_mask_q <= memory_request_line_mask_q |
                                        memory_scan_group_mask;
          for (int scan_endpoint = 0; scan_endpoint < ENDPOINT_COUNT;
               scan_endpoint++) begin
            if (memory_scan_group_mask[scan_endpoint])
              memory_request_word_index_q[scan_endpoint] <=
                  memory_scan_group_word_index[scan_endpoint];
          end
          if (memory_scan_group_q ==
              MEMORY_SCAN_GROUP_WIDTH'(MEMORY_SCAN_GROUP_COUNT - 1)) begin
            memory_select_valid_q <= 1'b0;
            memory_scan_mask_phase_q <= 1'b0;
            memory_scan_group_q <= '0;
            memory_request_valid_q <= 1'b1;
            memory_request_work_id_q <= memory_select_work_id_q;
            memory_request_line_addr_q <= memory_scan_line_addr_q;
            memory_request_voice_q <=
                work_context_q[memory_select_work_id_q].voice_index;
            memory_request_refill_q <=
                !work_window_checked_q[memory_select_work_id_q];
          end else begin
            memory_scan_group_q <= memory_scan_group_q + 1'b1;
          end
        end
      end else if (memory_action) begin
        memory_request_valid_q <= 1'b0;
      end

      unique case ({issue_capture, dsp_token_valid_q && dsp_token_ready})
        2'b10: dsp_token_valid_q <= 1'b1;
        2'b01: dsp_token_valid_q <= 1'b0;
        default: dsp_token_valid_q <= dsp_token_valid_q;
      endcase
      if (issue_capture)
        dsp_token_q <= dsp_token_q_next;

      if (issue_select_capture) begin
        issue_select_valid_q <= 1'b1;
        issue_select_work_id_q <= issue_candidate_work_id;
        issue_select_job_index_q <= work_issue_index_q[
            issue_candidate_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0];
        issue_job_payload_q <= job_payload_t'(work_job_payload_mem[
            (JOB_RAM_ADDR_WIDTH'(issue_candidate_work_id) <<
             BLOCK_FRAME_INDEX_WIDTH) |
            JOB_RAM_ADDR_WIDTH'(work_issue_index_q[
                issue_candidate_work_id])]);
      end else if (issue_capture) begin
        issue_select_valid_q <= 1'b0;
      end

      if (result_valid_q && result_ready)
        result_valid_q <= 1'b0;

      if (start_fire) begin
        work_state_q[free_work_id] <= WORK_PLAN;
        work_context_q[free_work_id].generation <= start_generation;
        work_context_q[free_work_id].voice_index <= start_voice_index;
        work_context_q[free_work_id].gain_l <= start_params.gain_l;
        work_context_q[free_work_id].gain_r <= start_params.gain_r;
        work_context_q[free_work_id].filter_enable <= start_params.filter_enable;
        work_context_q[free_work_id].filter_b0 <= start_params.filter_b0;
        work_context_q[free_work_id].filter_b1 <= start_params.filter_b1;
        work_context_q[free_work_id].filter_b2 <= start_params.filter_b2;
        work_context_q[free_work_id].filter_a1 <= start_params.filter_a1;
        work_context_q[free_work_id].filter_a2 <= start_params.filter_a2;
        work_endpoint_valid_q[free_work_id] <= '0;
        work_endpoint_pending_q[free_work_id] <= '0;
        work_endpoint_required_q[free_work_id] <= '0;
        work_window_checked_q[free_work_id] <= 1'b0;
        work_job_count_q[free_work_id] <= '0;
        work_issue_index_q[free_work_id] <= '0;
        work_frame_count_q[free_work_id] <= start_frame_count;
        work_frame_cursor_q[free_work_id] <= '0;
        work_phase_advance_mask_q[free_work_id] <= start_phase_advance_mask;
        work_render_mask_q[free_work_id] <= start_render_mask;
        work_envelope_levels_q[free_work_id] <= start_envelope_levels;
        work_active_q[free_work_id] <= start_active;
        work_phase_q[free_work_id] <= start_phase;
        work_region_q[free_work_id] <= start_region;
        work_phase_inc_q[free_work_id] <= start_params.phase_inc;
        work_released_q[free_work_id] <= start_params.released;
        work_z1_q[free_work_id] <= start_filter_z1;
        work_z2_q[free_work_id] <= start_filter_z2;
        work_hazard_q[free_work_id] <= 1'b0;
        work_env_active_q[free_work_id] <= start_env_active;
        work_env_state_q[free_work_id] <= start_env_state;
      end

      if (plan_found) begin
        plan_rr_q <= plan_work_id + 1'b1;
        plan_q.finalize <=
            work_state_q[plan_work_id] == WORK_PLAN_FINAL;
        plan_q.work_id <= plan_work_id;
        plan_q.active <= work_active_q[plan_work_id];
        plan_q.phase <= work_phase_q[plan_work_id];
        plan_q.region <= work_region_q[plan_work_id];
        plan_q.phase_inc <= work_phase_inc_q[plan_work_id];
        plan_q.released <= work_released_q[plan_work_id];
        plan_q.frame_count <= work_frame_count_q[plan_work_id];
        plan_q.frame_cursor <= work_frame_cursor_q[plan_work_id];
        plan_q.job_count <= work_job_count_q[plan_work_id];
        plan_q.phase_advance <= work_phase_advance_mask_q[plan_work_id][
            work_frame_cursor_q[plan_work_id]
                [BLOCK_FRAME_INDEX_WIDTH-1:0]];
        plan_q.render <= work_render_mask_q[plan_work_id][
            work_frame_cursor_q[plan_work_id]
                [BLOCK_FRAME_INDEX_WIDTH-1:0]];
        plan_q.envelope_level <= work_envelope_levels_q[plan_work_id][
            work_frame_cursor_q[plan_work_id]
                [BLOCK_FRAME_INDEX_WIDTH-1:0]];
        work_state_q[plan_work_id] <= WORK_PLAN_CALC;
      end

      if (plan_q.valid) begin
        if (plan_q.finalize) begin
          work_phase_result_q[plan_q.work_id].generation <=
              work_context_q[plan_q.work_id].generation;
          work_phase_result_q[plan_q.work_id].active <=
              work_phase_candidate_active_q[plan_q.work_id] &&
              !plan_current_done;
          work_phase_result_q[plan_q.work_id].phase <= plan_q.phase;
          work_phase_result_q[plan_q.work_id].frames_walked <=
              plan_q.frame_cursor;
          work_state_q[plan_q.work_id] <=
              (plan_q.job_count == '0) ? WORK_COMPLETE : WORK_MEM_WAIT;
        end else begin
          if (plan_store_job) begin
            work_job_payload_mem[
                (JOB_RAM_ADDR_WIDTH'(plan_q.work_id) <<
                 BLOCK_FRAME_INDEX_WIDTH) |
                JOB_RAM_ADDR_WIDTH'(plan_q.job_count)] <= {
                    plan_q.frame_cursor[BLOCK_FRAME_INDEX_WIDTH-1:0],
                    plan_fraction,
                    plan_q.envelope_level
                };
            if (!plan_q.job_count[0]) begin
              work_endpoint_addr_bank_0[
                  (ENDPOINT_BANK_ADDR_WIDTH'(plan_q.work_id) <<
                   MEMORY_SCAN_GROUP_WIDTH) |
                  ENDPOINT_BANK_ADDR_WIDTH'(plan_q.job_count[
                      BLOCK_FRAME_INDEX_WIDTH-1:1])] <=
                  plan_q.region.base_addr + ADDR_WIDTH'(plan_frame_0);
              work_endpoint_addr_bank_1[
                  (ENDPOINT_BANK_ADDR_WIDTH'(plan_q.work_id) <<
                   MEMORY_SCAN_GROUP_WIDTH) |
                  ENDPOINT_BANK_ADDR_WIDTH'(plan_q.job_count[
                      BLOCK_FRAME_INDEX_WIDTH-1:1])] <=
                  plan_q.region.base_addr + ADDR_WIDTH'(plan_frame_1);
            end else begin
              work_endpoint_addr_bank_2[
                  (ENDPOINT_BANK_ADDR_WIDTH'(plan_q.work_id) <<
                   MEMORY_SCAN_GROUP_WIDTH) |
                  ENDPOINT_BANK_ADDR_WIDTH'(plan_q.job_count[
                      BLOCK_FRAME_INDEX_WIDTH-1:1])] <=
                  plan_q.region.base_addr + ADDR_WIDTH'(plan_frame_0);
              work_endpoint_addr_bank_3[
                  (ENDPOINT_BANK_ADDR_WIDTH'(plan_q.work_id) <<
                   MEMORY_SCAN_GROUP_WIDTH) |
                  ENDPOINT_BANK_ADDR_WIDTH'(plan_q.job_count[
                      BLOCK_FRAME_INDEX_WIDTH-1:1])] <=
                  plan_q.region.base_addr + ADDR_WIDTH'(plan_frame_1);
            end
            work_endpoint_required_q[plan_q.work_id][
                {plan_q.job_count
                     [BLOCK_FRAME_INDEX_WIDTH-1:0], 1'b0}] <= 1'b1;
            work_endpoint_required_q[plan_q.work_id][
                {plan_q.job_count
                     [BLOCK_FRAME_INDEX_WIDTH-1:0], 1'b1}] <= 1'b1;
            work_job_count_q[plan_q.work_id] <= plan_q.job_count + 1'b1;
          end

          if (plan_q.active && !plan_current_done &&
              (plan_q.frame_cursor < plan_q.frame_count) &&
              plan_q.phase_advance) begin
            work_phase_q[plan_q.work_id] <= plan_next_phase;
            work_frame_cursor_q[plan_q.work_id] <= plan_q.frame_cursor + 1'b1;
          end

          if (plan_step_finishes) begin
            work_phase_candidate_active_q[plan_q.work_id] <=
                plan_q.active && !plan_current_done && plan_q.phase_advance;
            work_state_q[plan_q.work_id] <= WORK_PLAN_FINAL;
          end else
            work_state_q[plan_q.work_id] <= WORK_PLAN;
        end
      end

      for (int entry = 0; entry < BLOCK_WORK_ENTRY_COUNT; entry++) begin
        if (((work_state_q[entry] == WORK_MEM_WAIT) ||
             (work_state_q[entry] == WORK_MEM_FETCH)) &&
            ((work_endpoint_required_q[entry] &
              ~work_endpoint_valid_q[entry]) == '0))
          work_state_q[entry] <= WORK_READY;
      end

      if (memory_action) begin
        memory_rr_q <= memory_work_id + 1'b1;
        response_line_mask_q <= memory_request_line_mask_q;
        response_word_index_q <= memory_request_word_index_q;
        work_state_q[memory_work_id] <= WORK_MEM_FETCH;
        work_window_checked_q[memory_work_id] <= 1'b1;
        work_endpoint_pending_q[memory_work_id] <=
            work_endpoint_pending_q[memory_work_id] |
            memory_request_line_mask_q;
      end

      if (cache_rsp_valid) begin
        for (endpoint = 0; endpoint < ENDPOINT_COUNT;
             endpoint = endpoint + 1) begin
          if (response_line_mask_q[endpoint]) begin
            work_endpoint_sample_q[cache_rsp_tag][endpoint] <=
                cache_rsp.words[response_word_index_q[endpoint]];
            work_endpoint_valid_q[cache_rsp_tag][endpoint] <= 1'b1;
            work_endpoint_pending_q[cache_rsp_tag][endpoint] <= 1'b0;
          end
        end
      end

      if (issue_capture) begin
        work_issue_index_q[issue_select_work_id_q] <=
            work_issue_index_q[issue_select_work_id_q] + 1'b1;
        issue_rr_q <= issue_select_work_id_q + 1'b1;
        work_hazard_q[issue_select_work_id_q] <=
            work_context_q[issue_select_work_id_q].filter_enable;
        if (dsp_token_q_next.last)
          work_state_q[issue_select_work_id_q] <= WORK_DRAIN;
      end

      if (dsp_state_update_valid) begin
        work_z1_q[dsp_state_update.work_id] <= dsp_state_update.filter_z1;
        work_z2_q[dsp_state_update.work_id] <= dsp_state_update.filter_z2;
        work_hazard_q[dsp_state_update.work_id] <=
            issue_capture &&
            (issue_select_work_id_q == dsp_state_update.work_id) &&
            work_context_q[issue_select_work_id_q].filter_enable;
      end

      if (dsp_last_publish) begin
        result_valid_q <= 1'b1;
        result_q.phase_result <= work_phase_result_q[dsp_retire.work_id];
        result_q.filter_z1 <= dsp_retire.filter_z1;
        result_q.filter_z2 <= dsp_retire.filter_z2;
        result_voice_index_q <=
            work_context_q[dsp_retire.work_id].voice_index;
        result_env_active_q <= work_env_active_q[dsp_retire.work_id];
        result_env_state_q <= work_env_state_q[dsp_retire.work_id];
        if (!(start_fire && (free_work_id == dsp_retire.work_id))) begin
          work_state_q[dsp_retire.work_id] <= WORK_FREE;
          work_hazard_q[dsp_retire.work_id] <= 1'b0;
        end
      end else if (complete_publish) begin
        result_valid_q <= 1'b1;
        result_q.phase_result <= work_phase_result_q[complete_work_id];
        result_q.filter_z1 <= work_z1_q[complete_work_id];
        result_q.filter_z2 <= work_z2_q[complete_work_id];
        result_voice_index_q <= work_context_q[complete_work_id].voice_index;
        result_env_active_q <= work_env_active_q[complete_work_id];
        result_env_state_q <= work_env_state_q[complete_work_id];
        if (!(start_fire && (free_work_id == complete_work_id))) begin
          work_state_q[complete_work_id] <= WORK_FREE;
          work_hazard_q[complete_work_id] <= 1'b0;
        end
      end
    end
  end
endmodule
