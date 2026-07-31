// Archived experiment. This module is not part of the production RTL filelist.
module global_sample_line_cache #(
  parameter int WINDOW_WORDS = 32,
  parameter int TAG_COUNT = 8,
  parameter int TAG_WIDTH = $clog2(TAG_COUNT),
  parameter int CACHE_WORDS = synth_pkg::NUM_VOICES * WINDOW_WORDS
) (
  input  logic                                     clk,
  input  logic                                     rst,

  input  logic                                     client_req_valid,
  output logic                                     client_req_ready,
  input  logic [synth_pkg::ADDR_WIDTH-1:0]         client_req_addr,
  input  logic [TAG_WIDTH-1:0]                     client_req_tag,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]     client_req_voice,
  input  logic                                     client_req_refill,
  output logic                                     client_rsp_valid,
  input  logic                                     client_rsp_ready,
  output logic [synth_pkg::ADDR_WIDTH-1:0]         client_rsp_addr,
  output logic [TAG_WIDTH-1:0]                     client_rsp_tag,
  output synth_pkg::ordered_line_rsp_t             client_rsp,

  output logic                                     memory_req_valid,
  input  logic                                     memory_req_ready,
  output synth_pkg::ordered_line_req_t             memory_req,
  input  logic                                     memory_rsp_valid,
  output logic                                     memory_rsp_ready,
  input  synth_pkg::ordered_line_rsp_t             memory_rsp,

  output logic [31:0]                              stat_client_requests,
  output logic [31:0]                              stat_window_hits,
  output logic [31:0]                              stat_window_refills,
  output logic [31:0]                              stat_fallback_reads,
  output logic [31:0]                              stat_memory_reads,
  output logic [31:0]                              stat_evictions,
  output logic [31:0]                              stat_stall_cycles
);
  import synth_pkg::*;

  localparam int LINE_SHIFT = $clog2(BLOCK_LINE_WORDS);
  localparam int MACRO_SHIFT = $clog2(WINDOW_WORDS);
  localparam int MACRO_SUBLINES = WINDOW_WORDS / BLOCK_LINE_WORDS;
  localparam int SUBLINE_INDEX_WIDTH = $clog2(MACRO_SUBLINES);
  localparam int MACRO_ADDR_WIDTH = ADDR_WIDTH - MACRO_SHIFT;
  localparam int CACHE_MACROS = CACHE_WORDS / WINDOW_WORDS;
  localparam int SET_COUNT = CACHE_MACROS / 2;
  localparam int SET_INDEX_WIDTH = $clog2(SET_COUNT);
  localparam int CACHE_TAG_WIDTH = MACRO_ADDR_WIDTH - SET_INDEX_WIDTH;
  localparam int DATA_DEPTH = SET_COUNT * MACRO_SUBLINES;
  localparam int DATA_INDEX_WIDTH = $clog2(DATA_DEPTH);
  localparam int COUNT_WIDTH = $clog2(MACRO_SUBLINES + 1);

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_LOOKUP,
    STATE_HIT_WAIT,
    STATE_FILL
  } state_t;

  state_t state_q;

  (* ram_style = "block" *) logic [CACHE_TAG_WIDTH-1:0]
      cache_tag_way0 [0:SET_COUNT-1];
  (* ram_style = "block" *) logic [CACHE_TAG_WIDTH-1:0]
      cache_tag_way1 [0:SET_COUNT-1];
  (* ram_style = "distributed" *) logic cache_valid_way0 [0:SET_COUNT-1];
  (* ram_style = "distributed" *) logic cache_valid_way1 [0:SET_COUNT-1];
  (* ram_style = "distributed" *) logic [MACRO_SUBLINES-1:0]
      cache_sector_valid_way0 [0:SET_COUNT-1];
  (* ram_style = "distributed" *) logic [MACRO_SUBLINES-1:0]
      cache_sector_valid_way1 [0:SET_COUNT-1];
  (* ram_style = "distributed" *) logic cache_lru [0:SET_COUNT-1];
  (* ram_style = "block" *) logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0]
      cache_data_way0 [0:DATA_DEPTH-1];
  (* ram_style = "block" *) logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0]
      cache_data_way1 [0:DATA_DEPTH-1];

  logic metadata_init_active_q;
  logic [SET_INDEX_WIDTH-1:0] metadata_init_set_q;
  logic [CACHE_TAG_WIDTH-1:0] tag_read_way0_q;
  logic [CACHE_TAG_WIDTH-1:0] tag_read_way1_q;
  logic valid_read_way0_q;
  logic valid_read_way1_q;
  logic [MACRO_SUBLINES-1:0] sector_valid_read_way0_q;
  logic [MACRO_SUBLINES-1:0] sector_valid_read_way1_q;
  logic lru_read_q;
  logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0] data_read_way0_q;
  logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0] data_read_way1_q;

  logic [ADDR_WIDTH-1:0] request_addr_q;
  logic [MACRO_ADDR_WIDTH-1:0] request_macro_q;
  logic [SUBLINE_INDEX_WIDTH-1:0] request_subline_q;
  logic [TAG_WIDTH-1:0] request_tag_q;
  logic request_refill_q;

  logic [ADDR_WIDTH-1:0] fill_base_q;
  logic [SET_INDEX_WIDTH-1:0] fill_set_q;
  logic [CACHE_TAG_WIDTH-1:0] fill_cache_tag_q;
  logic [SUBLINE_INDEX_WIDTH-1:0] fill_critical_subline_q;
  logic [TAG_WIDTH-1:0] fill_client_tag_q;
  logic fill_way_q;
  logic [SUBLINE_INDEX_WIDTH-1:0] fill_start_subline_q;
  logic [COUNT_WIDTH-1:0] fill_line_count_q;
  logic [COUNT_WIDTH-1:0] fill_request_count_q;
  logic [COUNT_WIDTH-1:0] fill_response_count_q;

  logic rsp_valid_q;
  logic [ADDR_WIDTH-1:0] rsp_addr_q;
  logic [TAG_WIDTH-1:0] rsp_tag_q;
  ordered_line_rsp_t rsp_data_q;

  logic [SET_INDEX_WIDTH-1:0] request_set;
  logic [CACHE_TAG_WIDTH-1:0] request_cache_tag;
  logic [DATA_INDEX_WIDTH-1:0] request_data_index;
  logic [DATA_INDEX_WIDTH-1:0] fill_data_index;
  logic [SUBLINE_INDEX_WIDTH-1:0] fill_sector_index;
  logic tag_hit_way0;
  logic tag_hit_way1;
  logic hit_way0;
  logic hit_way1;
  logic replacement_way;
  logic rsp_slot_available;
  logic client_req_fire;
  logic memory_req_fire;
  logic memory_rsp_fire;
  logic response_is_critical;
  logic response_is_last;

  function automatic logic [31:0] sat_inc(input logic [31:0] value);
    sat_inc = (value == 32'hffff_ffff) ? value : value + 1'b1;
  endfunction

  always_comb begin
    request_set = request_macro_q[SET_INDEX_WIDTH-1:0];
    request_cache_tag = request_macro_q[
        MACRO_ADDR_WIDTH-1:SET_INDEX_WIDTH];
    request_data_index = {request_set, request_subline_q};
    fill_sector_index = fill_start_subline_q +
        fill_response_count_q[SUBLINE_INDEX_WIDTH-1:0];
    fill_data_index = {fill_set_q, fill_sector_index};

    tag_hit_way0 = valid_read_way0_q &&
        (tag_read_way0_q == request_cache_tag);
    tag_hit_way1 = valid_read_way1_q &&
        (tag_read_way1_q == request_cache_tag);
    hit_way0 = tag_hit_way0 && sector_valid_read_way0_q[request_subline_q];
    hit_way1 = tag_hit_way1 && sector_valid_read_way1_q[request_subline_q];

    if (tag_hit_way0)
      replacement_way = 1'b0;
    else if (tag_hit_way1)
      replacement_way = 1'b1;
    else if (!valid_read_way0_q)
      replacement_way = 1'b0;
    else if (!valid_read_way1_q)
      replacement_way = 1'b1;
    else
      replacement_way = lru_read_q;

    rsp_slot_available = !rsp_valid_q || client_rsp_ready;
    client_req_ready = !metadata_init_active_q &&
                       (state_q == STATE_IDLE) && rsp_slot_available;
    client_req_fire = client_req_valid && client_req_ready;

    memory_req_valid = (state_q == STATE_FILL) &&
                       (fill_request_count_q < fill_line_count_q);
    memory_req.aligned_line_addr = fill_base_q +
        (ADDR_WIDTH'(fill_request_count_q) << LINE_SHIFT);
    memory_req_fire = memory_req_valid && memory_req_ready;

    response_is_critical = fill_sector_index == fill_critical_subline_q;
    response_is_last =
        (fill_response_count_q + 1'b1) >= fill_line_count_q;
    memory_rsp_ready = (state_q == STATE_FILL) &&
                       (!response_is_critical || rsp_slot_available);
    memory_rsp_fire = memory_rsp_valid && memory_rsp_ready;

    client_rsp_valid = rsp_valid_q;
    client_rsp_addr = rsp_addr_q;
    client_rsp_tag = rsp_tag_q;
    client_rsp = rsp_data_q;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      metadata_init_active_q <= 1'b1;
      metadata_init_set_q <= '0;
    end else if (metadata_init_active_q) begin
      if (metadata_init_set_q == SET_INDEX_WIDTH'(SET_COUNT - 1))
        metadata_init_active_q <= 1'b0;
      else
        metadata_init_set_q <= metadata_init_set_q + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (client_req_fire) begin
      tag_read_way0_q <= cache_tag_way0[
          client_req_addr[MACRO_SHIFT +: SET_INDEX_WIDTH]];
      tag_read_way1_q <= cache_tag_way1[
          client_req_addr[MACRO_SHIFT +: SET_INDEX_WIDTH]];
      valid_read_way0_q <= cache_valid_way0[
          client_req_addr[MACRO_SHIFT +: SET_INDEX_WIDTH]];
      valid_read_way1_q <= cache_valid_way1[
          client_req_addr[MACRO_SHIFT +: SET_INDEX_WIDTH]];
      sector_valid_read_way0_q <= cache_sector_valid_way0[
          client_req_addr[MACRO_SHIFT +: SET_INDEX_WIDTH]];
      sector_valid_read_way1_q <= cache_sector_valid_way1[
          client_req_addr[MACRO_SHIFT +: SET_INDEX_WIDTH]];
      lru_read_q <= cache_lru[
          client_req_addr[MACRO_SHIFT +: SET_INDEX_WIDTH]];
    end
  end

  always_ff @(posedge clk) begin
    if (response_is_last && memory_rsp_fire && !fill_way_q)
      cache_tag_way0[fill_set_q] <= fill_cache_tag_q;
  end

  always_ff @(posedge clk) begin
    if (response_is_last && memory_rsp_fire && fill_way_q)
      cache_tag_way1[fill_set_q] <= fill_cache_tag_q;
  end

  always_ff @(posedge clk) begin
    if (metadata_init_active_q)
      cache_valid_way0[metadata_init_set_q] <= 1'b0;
    else if (response_is_last && memory_rsp_fire && !fill_way_q)
      cache_valid_way0[fill_set_q] <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (metadata_init_active_q)
      cache_valid_way1[metadata_init_set_q] <= 1'b0;
    else if (response_is_last && memory_rsp_fire && fill_way_q)
      cache_valid_way1[fill_set_q] <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (metadata_init_active_q)
      cache_sector_valid_way0[metadata_init_set_q] <= '0;
    else if ((state_q == STATE_LOOKUP) && !hit_way0 && !hit_way1 &&
             !replacement_way && !tag_hit_way0)
      cache_sector_valid_way0[request_set] <= '0;
    else if (memory_rsp_fire && !fill_way_q)
      cache_sector_valid_way0[fill_set_q][fill_sector_index] <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (metadata_init_active_q)
      cache_sector_valid_way1[metadata_init_set_q] <= '0;
    else if ((state_q == STATE_LOOKUP) && !hit_way0 && !hit_way1 &&
             replacement_way && !tag_hit_way1)
      cache_sector_valid_way1[request_set] <= '0;
    else if (memory_rsp_fire && fill_way_q)
      cache_sector_valid_way1[fill_set_q][fill_sector_index] <= 1'b1;
  end

  always_ff @(posedge clk) begin
    if (metadata_init_active_q)
      cache_lru[metadata_init_set_q] <= 1'b0;
    else if ((state_q == STATE_LOOKUP) && hit_way0)
      cache_lru[request_set] <= 1'b1;
    else if ((state_q == STATE_LOOKUP) && hit_way1)
      cache_lru[request_set] <= 1'b0;
    else if (response_is_last && memory_rsp_fire)
      cache_lru[fill_set_q] <= !fill_way_q;
  end

  always_ff @(posedge clk) begin
    if ((state_q == STATE_LOOKUP) && hit_way0)
      data_read_way0_q <= cache_data_way0[request_data_index];
  end

  always_ff @(posedge clk) begin
    if ((state_q == STATE_LOOKUP) && hit_way1)
      data_read_way1_q <= cache_data_way1[request_data_index];
  end

  always_ff @(posedge clk) begin
    if (memory_rsp_fire && !fill_way_q)
      cache_data_way0[fill_data_index] <= memory_rsp.words;
  end

  always_ff @(posedge clk) begin
    if (memory_rsp_fire && fill_way_q)
      cache_data_way1[fill_data_index] <= memory_rsp.words;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= STATE_IDLE;
      rsp_valid_q <= 1'b0;
      fill_request_count_q <= '0;
      fill_response_count_q <= '0;
      fill_line_count_q <= '0;
      fill_start_subline_q <= '0;
      stat_client_requests <= '0;
      stat_window_hits <= '0;
      stat_window_refills <= '0;
      stat_fallback_reads <= '0;
      stat_memory_reads <= '0;
      stat_evictions <= '0;
      stat_stall_cycles <= '0;
    end else begin
      if (rsp_valid_q && client_rsp_ready)
        rsp_valid_q <= 1'b0;

      if (client_req_valid && !client_req_ready && !metadata_init_active_q)
        stat_stall_cycles <= sat_inc(stat_stall_cycles);

      if (client_req_fire) begin
        stat_client_requests <= sat_inc(stat_client_requests);
        request_addr_q <= client_req_addr;
        request_macro_q <= client_req_addr[ADDR_WIDTH-1:MACRO_SHIFT];
        request_subline_q <= client_req_addr[
            LINE_SHIFT +: SUBLINE_INDEX_WIDTH];
        request_tag_q <= client_req_tag;
        request_refill_q <= client_req_refill;
        state_q <= STATE_LOOKUP;
      end

      if (state_q == STATE_LOOKUP) begin
        rsp_addr_q <= request_addr_q;
        rsp_tag_q <= request_tag_q;
        if (hit_way0 || hit_way1) begin
          stat_window_hits <= sat_inc(stat_window_hits);
          state_q <= STATE_HIT_WAIT;
        end else begin
          if (request_refill_q) begin
            fill_base_q <= {
                request_macro_q, {MACRO_SHIFT{1'b0}}};
            fill_start_subline_q <= '0;
            fill_line_count_q <= COUNT_WIDTH'(MACRO_SUBLINES);
          end else begin
            fill_base_q <= {
                request_addr_q[ADDR_WIDTH-1:LINE_SHIFT],
                {LINE_SHIFT{1'b0}}};
            fill_start_subline_q <= request_subline_q;
            fill_line_count_q <= COUNT_WIDTH'(1);
          end
          fill_set_q <= request_set;
          fill_cache_tag_q <= request_cache_tag;
          fill_critical_subline_q <= request_subline_q;
          fill_client_tag_q <= request_tag_q;
          fill_way_q <= replacement_way;
          fill_request_count_q <= '0;
          fill_response_count_q <= '0;
          if (request_refill_q)
            stat_window_refills <= sat_inc(stat_window_refills);
          else
            stat_fallback_reads <= sat_inc(stat_fallback_reads);
          if (!tag_hit_way0 && !tag_hit_way1 &&
              (replacement_way ? valid_read_way1_q : valid_read_way0_q))
            stat_evictions <= sat_inc(stat_evictions);
          state_q <= STATE_FILL;
        end
      end

      if (state_q == STATE_HIT_WAIT) begin
        rsp_valid_q <= 1'b1;
        if (hit_way0)
          rsp_data_q.words <= data_read_way0_q;
        else
          rsp_data_q.words <= data_read_way1_q;
        state_q <= STATE_IDLE;
      end

      if (memory_req_fire) begin
        fill_request_count_q <= fill_request_count_q + 1'b1;
        stat_memory_reads <= sat_inc(stat_memory_reads);
      end

      if (memory_rsp_fire) begin
        fill_response_count_q <= fill_response_count_q + 1'b1;
        if (response_is_critical) begin
          rsp_valid_q <= 1'b1;
          rsp_addr_q <= request_addr_q;
          rsp_tag_q <= fill_client_tag_q;
          rsp_data_q <= memory_rsp;
        end
        if (response_is_last)
          state_q <= STATE_IDLE;
      end
    end
  end

  // Cache contents are global; the voice ID is intentionally not part of a tag.
  logic unused_client_voice;
  assign unused_client_voice = ^client_req_voice;
endmodule
