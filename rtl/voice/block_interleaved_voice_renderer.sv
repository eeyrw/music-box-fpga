module block_interleaved_voice_renderer #(
  parameter int SEGMENT_BEATS = 4
) (
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
  localparam int SEGMENT_WORDS = SEGMENT_BEATS * BLOCK_LINE_WORDS;
  localparam int SEGMENT_SHIFT = $clog2(SEGMENT_WORDS);
  localparam int LINE_SHIFT = $clog2(BLOCK_LINE_WORDS);
  localparam int BEAT_COUNT_WIDTH = $clog2(SEGMENT_BEATS + 1);

  typedef enum logic [2:0] {
    WORK_FREE,
    WORK_PLAN,
    WORK_MEM_WAIT,
    WORK_MEM_FETCH,
    WORK_READY,
    WORK_DRAIN,
    WORK_COMPLETE
  } work_state_t;

  work_state_t work_state_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  block_voice_context_t work_context_q [0:BLOCK_WORK_ENTRY_COUNT-1];
  block_endpoint_job_t work_job_q
      [0:BLOCK_WORK_ENTRY_COUNT-1][0:MAX_BLOCK_FRAMES-1];
  pcm_t work_endpoint_sample_q
      [0:BLOCK_WORK_ENTRY_COUNT-1][0:ENDPOINT_COUNT-1];
  logic [ENDPOINT_COUNT-1:0] work_endpoint_valid_q
      [0:BLOCK_WORK_ENTRY_COUNT-1];
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
  voice_event_params_t work_params_q [0:BLOCK_WORK_ENTRY_COUNT-1];
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
  logic plan_next_done;
  logic plan_store_job;
  logic plan_finishes;

  logic memory_active_q;
  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_work_id_q;
  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_rr_q;
  logic [ADDR_WIDTH-1:0] memory_segment_base_q;
  logic [ENDPOINT_COUNT-1:0] memory_segment_mask_q;
  logic [BEAT_COUNT_WIDTH-1:0] memory_request_beat_q;
  logic [BEAT_COUNT_WIDTH-1:0] memory_response_beat_q;
  logic memory_start_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] memory_start_work_id;
  logic [ENDPOINT_COUNT-1:0] memory_remaining_mask;
  logic [ENDPOINT_COUNT-1:0] memory_current_remaining_mask;
  logic [ENDPOINT_COUNT-1:0] memory_start_segment_mask;
  logic [ADDR_WIDTH-1:0] memory_start_segment_base;
  logic [ADDR_WIDTH-LINE_SHIFT-1:0] memory_response_line_addr;

  logic free_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] free_work_id;
  logic start_fire;
  logic [BLOCK_WORK_ID_WIDTH-1:0] issue_rr_q;
  logic issue_found;
  logic [BLOCK_WORK_ID_WIDTH-1:0] issue_work_id;
  logic issue_endpoints_ready;

  block_dsp_sample_token_t dsp_token;
  logic dsp_token_valid;
  logic dsp_token_ready;
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
    .loop_mode(work_region_q[plan_work_id].loop_mode),
    .released(work_params_q[plan_work_id].released),
    .phase(work_phase_q[plan_work_id]),
    .phase_inc(work_params_q[plan_work_id].phase_inc),
    .length(work_region_q[plan_work_id].length),
    .loop_start(work_region_q[plan_work_id].loop_start),
    .loop_end(work_region_q[plan_work_id].loop_end),
    .done(plan_current_done),
    .frame_0(plan_frame_0),
    .frame_1(plan_frame_1),
    .fraction(plan_fraction),
    .next_phase(plan_next_phase)
  );

  mono_phase_frame plan_next_phase_frame (
    .loop_mode(work_region_q[plan_work_id].loop_mode),
    .released(work_params_q[plan_work_id].released),
    .phase(plan_next_phase),
    .phase_inc(work_params_q[plan_work_id].phase_inc),
    .length(work_region_q[plan_work_id].length),
    .loop_start(work_region_q[plan_work_id].loop_start),
    .loop_end(work_region_q[plan_work_id].loop_end),
    .done(plan_next_done),
    .frame_0(),
    .frame_1(),
    .fraction(),
    .next_phase()
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

  assign start_fire = start_valid && start_ready;

  always_comb begin
    plan_found = 1'b0;
    plan_work_id = '0;
    for (int offset = 0; offset < BLOCK_WORK_ENTRY_COUNT; offset++) begin
      logic [BLOCK_WORK_ID_WIDTH-1:0] candidate;
      candidate = plan_rr_q + BLOCK_WORK_ID_WIDTH'(offset);
      if (!plan_found && (work_state_q[candidate] == WORK_PLAN)) begin
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

    plan_store_job = plan_found && work_active_q[plan_work_id] &&
        !plan_current_done &&
        (work_frame_cursor_q[plan_work_id] <
         work_frame_count_q[plan_work_id]) &&
        work_phase_advance_mask_q[plan_work_id][
            work_frame_cursor_q[plan_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0]] &&
        work_render_mask_q[plan_work_id][
            work_frame_cursor_q[plan_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0]];
    plan_finishes = plan_found &&
        ((!work_active_q[plan_work_id]) || plan_current_done ||
         (work_frame_cursor_q[plan_work_id] >=
          work_frame_count_q[plan_work_id]) ||
         !work_phase_advance_mask_q[plan_work_id][
             work_frame_cursor_q[plan_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0]] ||
         ((work_frame_cursor_q[plan_work_id] + 1'b1) >=
          work_frame_count_q[plan_work_id]));

    memory_start_found = 1'b0;
    memory_start_work_id = '0;
    for (int offset = 0; offset < BLOCK_WORK_ENTRY_COUNT; offset++) begin
      logic [BLOCK_WORK_ID_WIDTH-1:0] candidate;
      candidate = memory_rr_q + BLOCK_WORK_ID_WIDTH'(offset);
      if (!memory_start_found &&
          (work_state_q[candidate] == WORK_MEM_WAIT)) begin
        memory_start_found = 1'b1;
        memory_start_work_id = candidate;
      end
    end

    memory_remaining_mask = '0;
    for (int endpoint = 0; endpoint < ENDPOINT_COUNT; endpoint++) begin
      if ((endpoint < (int'(work_job_count_q[memory_start_work_id]) *
                       BLOCK_ENDPOINT_COUNT)) &&
          work_job_q[memory_start_work_id]
              [endpoint / BLOCK_ENDPOINT_COUNT]
              .endpoint_mask[endpoint % BLOCK_ENDPOINT_COUNT] &&
          !work_endpoint_valid_q[memory_start_work_id][endpoint])
        memory_remaining_mask[endpoint] = 1'b1;
    end
    memory_current_remaining_mask = '0;
    for (int endpoint = 0; endpoint < ENDPOINT_COUNT; endpoint++) begin
      if ((endpoint < (int'(work_job_count_q[memory_work_id_q]) *
                       BLOCK_ENDPOINT_COUNT)) &&
          work_job_q[memory_work_id_q]
              [endpoint / BLOCK_ENDPOINT_COUNT]
              .endpoint_mask[endpoint % BLOCK_ENDPOINT_COUNT] &&
          !work_endpoint_valid_q[memory_work_id_q][endpoint])
        memory_current_remaining_mask[endpoint] = 1'b1;
    end
    memory_start_segment_base = '0;
    for (int endpoint = ENDPOINT_COUNT - 1; endpoint >= 0; endpoint--) begin
      if (memory_remaining_mask[endpoint]) begin
        memory_start_segment_base =
            (work_job_q[memory_start_work_id]
                 [endpoint / BLOCK_ENDPOINT_COUNT]
                 .endpoint_addr[endpoint % BLOCK_ENDPOINT_COUNT] >>
             SEGMENT_SHIFT) << SEGMENT_SHIFT;
      end
    end
    memory_start_segment_mask = '0;
    for (int endpoint = 0; endpoint < ENDPOINT_COUNT; endpoint++) begin
      logic [ADDR_WIDTH-1:0] endpoint_addr;
      endpoint_addr = work_job_q[memory_start_work_id]
          [endpoint / BLOCK_ENDPOINT_COUNT]
          .endpoint_addr[endpoint % BLOCK_ENDPOINT_COUNT];
      if (memory_remaining_mask[endpoint] &&
          (endpoint_addr >= memory_start_segment_base) &&
          (endpoint_addr <
           memory_start_segment_base + ADDR_WIDTH'(SEGMENT_WORDS)))
        memory_start_segment_mask[endpoint] = 1'b1;
    end

    line_req_valid = memory_active_q &&
        (memory_request_beat_q < BEAT_COUNT_WIDTH'(SEGMENT_BEATS));
    line_req.aligned_line_addr = memory_segment_base_q +
        ADDR_WIDTH'(memory_request_beat_q * BLOCK_LINE_WORDS);
    line_rsp_ready = memory_active_q &&
        (memory_response_beat_q < BEAT_COUNT_WIDTH'(SEGMENT_BEATS));
    memory_response_line_addr =
        memory_segment_base_q[ADDR_WIDTH-1:LINE_SHIFT] +
        (ADDR_WIDTH-LINE_SHIFT)'(memory_response_beat_q);

    issue_found = 1'b0;
    issue_work_id = '0;
    issue_endpoints_ready = 1'b0;
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
          (work_endpoint_valid_q[candidate][{job_index, 1'b0}] ||
           !work_job_q[candidate][job_index].endpoint_mask[0]) &&
          (work_endpoint_valid_q[candidate][{job_index, 1'b1}] ||
           !work_job_q[candidate][job_index].endpoint_mask[1]);
      if (!issue_found && endpoints_ready &&
          (!work_hazard_q[candidate] || hazard_resolves) &&
          (((work_state_q[candidate] == WORK_MEM_FETCH) ||
            (work_state_q[candidate] == WORK_READY)) &&
           (work_issue_index_q[candidate] < work_job_count_q[candidate]))) begin
        issue_found = 1'b1;
        issue_work_id = candidate;
        issue_endpoints_ready = endpoints_ready;
      end
    end

    dsp_token_valid = issue_found && issue_endpoints_ready;
    dsp_token = '0;
    dsp_token.work_id = issue_work_id;
    dsp_token.last = (work_issue_index_q[issue_work_id] + 1'b1) >=
                     work_job_count_q[issue_work_id];
    dsp_token.voice_context = work_context_q[issue_work_id];
    dsp_token.sample.job = work_job_q[issue_work_id][
        work_issue_index_q[issue_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0]];
    dsp_token.sample.sample_0 = work_endpoint_sample_q[issue_work_id][
        {work_issue_index_q[issue_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0], 1'b0}];
    dsp_token.sample.sample_1 = work_endpoint_sample_q[issue_work_id][
        {work_issue_index_q[issue_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0], 1'b1}];
    dsp_token.filter_z1 =
        (dsp_state_update_valid &&
         (dsp_state_update.work_id == issue_work_id)) ?
        dsp_state_update.filter_z1 : work_z1_q[issue_work_id];
    dsp_token.filter_z2 =
        (dsp_state_update_valid &&
         (dsp_state_update.work_id == issue_work_id)) ?
        dsp_state_update.filter_z2 : work_z2_q[issue_work_id];

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
      memory_active_q <= 1'b0;
      memory_work_id_q <= '0;
      memory_rr_q <= '0;
      memory_segment_base_q <= '0;
      memory_segment_mask_q <= '0;
      memory_request_beat_q <= '0;
      memory_response_beat_q <= '0;
      issue_rr_q <= '0;
      result_valid_q <= 1'b0;
      result_q <= '0;
      result_voice_index_q <= '0;
      result_env_active_q <= 1'b0;
      result_env_state_q <= '0;
      for (int entry = 0; entry < BLOCK_WORK_ENTRY_COUNT; entry++) begin
        work_state_q[entry] <= WORK_FREE;
        work_context_q[entry] <= '0;
        work_endpoint_valid_q[entry] <= '0;
        work_job_count_q[entry] <= '0;
        work_issue_index_q[entry] <= '0;
        work_frame_count_q[entry] <= '0;
        work_frame_cursor_q[entry] <= '0;
        work_phase_advance_mask_q[entry] <= '0;
        work_render_mask_q[entry] <= '0;
        work_envelope_levels_q[entry] <= '0;
        work_active_q[entry] <= 1'b0;
        work_phase_q[entry] <= '0;
        work_region_q[entry] <= '0;
        work_params_q[entry] <= '0;
        work_phase_result_q[entry] <= '0;
        work_z1_q[entry] <= '0;
        work_z2_q[entry] <= '0;
        work_hazard_q[entry] <= 1'b0;
        work_env_active_q[entry] <= 1'b0;
        work_env_state_q[entry] <= '0;
      end
    end else begin
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
        work_params_q[free_work_id] <= start_params;
        work_z1_q[free_work_id] <= start_filter_z1;
        work_z2_q[free_work_id] <= start_filter_z2;
        work_hazard_q[free_work_id] <= 1'b0;
        work_env_active_q[free_work_id] <= start_env_active;
        work_env_state_q[free_work_id] <= start_env_state;
      end

      if (plan_found) begin
        plan_rr_q <= plan_work_id + 1'b1;
        if (plan_store_job) begin
          work_job_q[plan_work_id][work_job_count_q[plan_work_id]
              [BLOCK_FRAME_INDEX_WIDTH-1:0]].block_frame_index <=
              work_frame_cursor_q[plan_work_id][BLOCK_FRAME_INDEX_WIDTH-1:0];
          work_job_q[plan_work_id][work_job_count_q[plan_work_id]
              [BLOCK_FRAME_INDEX_WIDTH-1:0]].fraction <= plan_fraction;
          work_job_q[plan_work_id][work_job_count_q[plan_work_id]
              [BLOCK_FRAME_INDEX_WIDTH-1:0]].endpoint_mask <= 2'b11;
          work_job_q[plan_work_id][work_job_count_q[plan_work_id]
              [BLOCK_FRAME_INDEX_WIDTH-1:0]].endpoint_addr[0] <=
              work_region_q[plan_work_id].base_addr + ADDR_WIDTH'(plan_frame_0);
          work_job_q[plan_work_id][work_job_count_q[plan_work_id]
              [BLOCK_FRAME_INDEX_WIDTH-1:0]].endpoint_addr[1] <=
              work_region_q[plan_work_id].base_addr + ADDR_WIDTH'(plan_frame_1);
          work_job_q[plan_work_id][work_job_count_q[plan_work_id]
              [BLOCK_FRAME_INDEX_WIDTH-1:0]].envelope_level <=
              work_envelope_levels_q[plan_work_id][
                  work_frame_cursor_q[plan_work_id]
                      [BLOCK_FRAME_INDEX_WIDTH-1:0]];
          work_job_count_q[plan_work_id] <=
              work_job_count_q[plan_work_id] + 1'b1;
        end

        if (work_active_q[plan_work_id] && !plan_current_done &&
            (work_frame_cursor_q[plan_work_id] <
             work_frame_count_q[plan_work_id]) &&
            work_phase_advance_mask_q[plan_work_id][
                work_frame_cursor_q[plan_work_id]
                    [BLOCK_FRAME_INDEX_WIDTH-1:0]]) begin
          work_phase_q[plan_work_id] <= plan_next_phase;
          work_frame_cursor_q[plan_work_id] <=
              work_frame_cursor_q[plan_work_id] + 1'b1;
        end

        if (plan_finishes) begin
          work_phase_result_q[plan_work_id].generation <=
              work_context_q[plan_work_id].generation;
          work_phase_result_q[plan_work_id].active <=
              work_active_q[plan_work_id] && !plan_current_done &&
              work_phase_advance_mask_q[plan_work_id][
                  work_frame_cursor_q[plan_work_id]
                      [BLOCK_FRAME_INDEX_WIDTH-1:0]] &&
              !(((work_frame_cursor_q[plan_work_id] + 1'b1) >=
                  work_frame_count_q[plan_work_id]) && plan_next_done);
          work_phase_result_q[plan_work_id].phase <=
              (work_active_q[plan_work_id] && !plan_current_done &&
               work_phase_advance_mask_q[plan_work_id][
                   work_frame_cursor_q[plan_work_id]
                       [BLOCK_FRAME_INDEX_WIDTH-1:0]]) ?
              plan_next_phase : work_phase_q[plan_work_id];
          work_phase_result_q[plan_work_id].frames_walked <=
              (work_active_q[plan_work_id] && !plan_current_done &&
               work_phase_advance_mask_q[plan_work_id][
                   work_frame_cursor_q[plan_work_id]
                       [BLOCK_FRAME_INDEX_WIDTH-1:0]]) ?
              work_frame_cursor_q[plan_work_id] + 1'b1 :
              work_frame_cursor_q[plan_work_id];
          work_state_q[plan_work_id] <=
              (work_job_count_q[plan_work_id] == '0 && !plan_store_job) ?
              WORK_COMPLETE : WORK_MEM_WAIT;
        end
      end

      if (!memory_active_q && memory_start_found) begin
        memory_active_q <= 1'b1;
        memory_work_id_q <= memory_start_work_id;
        memory_rr_q <= memory_start_work_id + 1'b1;
        memory_segment_base_q <= memory_start_segment_base;
        memory_segment_mask_q <= memory_start_segment_mask;
        memory_request_beat_q <= '0;
        memory_response_beat_q <= '0;
        work_state_q[memory_start_work_id] <= WORK_MEM_FETCH;
      end
      if (line_req_valid && line_req_ready)
        memory_request_beat_q <= memory_request_beat_q + 1'b1;

      if (line_rsp_valid && line_rsp_ready) begin
        for (endpoint = 0; endpoint < ENDPOINT_COUNT; endpoint = endpoint + 1) begin
          if (memory_segment_mask_q[endpoint] &&
              work_job_q[memory_work_id_q]
                  [endpoint / BLOCK_ENDPOINT_COUNT]
                  .endpoint_addr[endpoint % BLOCK_ENDPOINT_COUNT]
                  [ADDR_WIDTH-1:LINE_SHIFT] == memory_response_line_addr) begin
            work_endpoint_sample_q[memory_work_id_q][endpoint] <=
                line_rsp.words[work_job_q[memory_work_id_q]
                    [endpoint / BLOCK_ENDPOINT_COUNT]
                    .endpoint_addr[endpoint % BLOCK_ENDPOINT_COUNT]
                    [LINE_SHIFT-1:0]];
            work_endpoint_valid_q[memory_work_id_q][endpoint] <= 1'b1;
          end
        end
        memory_response_beat_q <= memory_response_beat_q + 1'b1;
        if (memory_response_beat_q == BEAT_COUNT_WIDTH'(SEGMENT_BEATS - 1)) begin
          memory_active_q <= 1'b0;
          work_state_q[memory_work_id_q] <=
              |(memory_current_remaining_mask & ~memory_segment_mask_q) ?
              WORK_MEM_WAIT : WORK_READY;
        end
      end

      if (dsp_token_valid && dsp_token_ready) begin
        work_issue_index_q[issue_work_id] <=
            work_issue_index_q[issue_work_id] + 1'b1;
        issue_rr_q <= issue_work_id + 1'b1;
        work_hazard_q[issue_work_id] <=
            work_context_q[issue_work_id].filter_enable;
        if (dsp_token.last)
          work_state_q[issue_work_id] <= WORK_DRAIN;
      end

      if (dsp_state_update_valid) begin
        work_z1_q[dsp_state_update.work_id] <= dsp_state_update.filter_z1;
        work_z2_q[dsp_state_update.work_id] <= dsp_state_update.filter_z2;
        work_hazard_q[dsp_state_update.work_id] <=
            dsp_token_valid && dsp_token_ready &&
            (issue_work_id == dsp_state_update.work_id) &&
            work_context_q[issue_work_id].filter_enable;
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
