module voice_sample_window #(
  parameter int WINDOW_WORDS = 32,
  parameter int TAG_COUNT = 8,
  parameter int TAG_WIDTH = $clog2(TAG_COUNT)
) (
  input  logic                                     clk,
  input  logic                                     rst,
  input  logic                                     diagnostics_clear,

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
  localparam int LINE_ADDR_WIDTH = ADDR_WIDTH - LINE_SHIFT;
  localparam int WINDOW_LINES = WINDOW_WORDS / BLOCK_LINE_WORDS;
  localparam int WINDOW_LINE_INDEX_WIDTH = $clog2(WINDOW_LINES);
  localparam int COUNT_WIDTH = $clog2(WINDOW_LINES + 1);
  localparam int RAM_DEPTH = NUM_VOICES * WINDOW_LINES;
  localparam int RAM_ADDR_WIDTH = $clog2(RAM_DEPTH);
  localparam int META_WIDTH = LINE_ADDR_WIDTH + 1;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_LOOKUP,
    STATE_HIT_WAIT,
    STATE_MISS
  } state_t;

  state_t state_q;
  (* ram_style = "block" *) logic [META_WIDTH-1:0]
      window_meta_q [0:NUM_VOICES-1];
  logic [META_WIDTH-1:0] window_meta_read_q;
  logic metadata_init_active_q;
  logic [VOICE_ID_WIDTH-1:0] metadata_init_voice_q;
  logic metadata_write_enable;
  logic [VOICE_ID_WIDTH-1:0] metadata_write_voice;
  logic [META_WIDTH-1:0] metadata_write_data;
  (* ram_style = "block" *) logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0]
      window_data [0:RAM_DEPTH-1];
  logic [BLOCK_LINE_WORDS*PCM_WIDTH-1:0] window_read_data_q;

  logic rsp_valid_q;
  logic [ADDR_WIDTH-1:0] rsp_addr_q;
  logic [TAG_WIDTH-1:0] rsp_tag_q;
  ordered_line_rsp_t rsp_data_q;

  logic [ADDR_WIDTH-1:0] request_addr_q;
  logic [LINE_ADDR_WIDTH-1:0] request_line_q;
  logic [TAG_WIDTH-1:0] request_tag_q;
  logic [VOICE_ID_WIDTH-1:0] request_voice_q;
  logic request_refill_q;
  logic refill_q;
  logic [VOICE_ID_WIDTH-1:0] miss_voice_q;
  logic [LINE_ADDR_WIDTH-1:0] miss_base_q;
  logic [TAG_WIDTH-1:0] miss_tag_q;
  logic [COUNT_WIDTH-1:0] request_count_q;
  logic [COUNT_WIDTH-1:0] response_count_q;

  logic [LINE_ADDR_WIDTH-1:0] request_window_offset;
  logic request_window_hit;
  logic [RAM_ADDR_WIDTH-1:0] request_window_index;
  logic [COUNT_WIDTH-1:0] transaction_line_count;
  logic client_req_fire;
  logic memory_req_fire;
  logic memory_rsp_fire;
  logic rsp_slot_available;

  function automatic logic [31:0] sat_inc(input logic [31:0] value);
    sat_inc = (value == 32'hffff_ffff) ? value : value + 1'b1;
  endfunction

  always_comb begin
    request_window_offset = request_line_q -
                            window_meta_read_q[LINE_ADDR_WIDTH-1:0];
    request_window_hit = window_meta_read_q[META_WIDTH-1] &&
        (request_line_q >= window_meta_read_q[LINE_ADDR_WIDTH-1:0]) &&
        (request_window_offset < LINE_ADDR_WIDTH'(WINDOW_LINES));
    request_window_index = RAM_ADDR_WIDTH'(
        (int'(request_voice_q) * WINDOW_LINES) +
        int'(request_window_offset[WINDOW_LINE_INDEX_WIDTH-1:0]));

    rsp_slot_available = !rsp_valid_q || client_rsp_ready;
    client_req_ready = !metadata_init_active_q &&
                       (state_q == STATE_IDLE) && rsp_slot_available;
    client_req_fire = client_req_valid && client_req_ready;

    transaction_line_count = refill_q ? COUNT_WIDTH'(WINDOW_LINES) :
                                        COUNT_WIDTH'(1);
    memory_req_valid = (state_q == STATE_MISS) &&
                       (request_count_q < transaction_line_count);
    memory_req.aligned_line_addr = {
        miss_base_q + LINE_ADDR_WIDTH'(request_count_q),
        {LINE_SHIFT{1'b0}}};
    memory_req_fire = memory_req_valid && memory_req_ready;

    memory_rsp_ready = (state_q == STATE_MISS) &&
        (refill_q ? ((response_count_q != '0) || rsp_slot_available) :
                    rsp_slot_available);
    memory_rsp_fire = memory_rsp_valid && memory_rsp_ready;

    client_rsp_valid = rsp_valid_q;
    client_rsp_addr = rsp_addr_q;
    client_rsp_tag = rsp_tag_q;
    client_rsp = rsp_data_q;
  end

  always_comb begin
    metadata_write_enable = 1'b0;
    metadata_write_voice = '0;
    metadata_write_data = '0;
    if (!rst && metadata_init_active_q) begin
      metadata_write_enable = 1'b1;
      metadata_write_voice = metadata_init_voice_q;
    end else if ((state_q == STATE_LOOKUP) && !request_window_hit &&
                 request_refill_q) begin
      metadata_write_enable = 1'b1;
      metadata_write_voice = request_voice_q;
      metadata_write_data = {1'b0, request_line_q};
    end else if (memory_rsp_fire && refill_q &&
                 ((response_count_q + 1'b1) >= transaction_line_count)) begin
      metadata_write_enable = 1'b1;
      metadata_write_voice = miss_voice_q;
      metadata_write_data = {1'b1, miss_base_q};
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      metadata_init_active_q <= 1'b1;
      metadata_init_voice_q <= '0;
    end else if (metadata_init_active_q) begin
      if (metadata_init_voice_q == VOICE_ID_WIDTH'(NUM_VOICES - 1)) begin
        metadata_init_active_q <= 1'b0;
      end else begin
        metadata_init_voice_q <= metadata_init_voice_q + 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (client_req_fire)
      window_meta_read_q <= window_meta_q[client_req_voice];
    if (metadata_write_enable)
      window_meta_q[metadata_write_voice] <= metadata_write_data;

    if ((state_q == STATE_LOOKUP) && request_window_hit)
      window_read_data_q <= window_data[request_window_index];

    if (memory_rsp_fire && refill_q)
      window_data[RAM_ADDR_WIDTH'(
          (int'(miss_voice_q) * WINDOW_LINES) + int'(response_count_q))] <=
          memory_rsp.words;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= STATE_IDLE;
      rsp_valid_q <= 1'b0;
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
        request_line_q <= client_req_addr[ADDR_WIDTH-1:LINE_SHIFT];
        request_tag_q <= client_req_tag;
        request_voice_q <= client_req_voice;
        request_refill_q <= client_req_refill;
        state_q <= STATE_LOOKUP;
      end

      if (state_q == STATE_LOOKUP) begin
        rsp_addr_q <= request_addr_q;
        rsp_tag_q <= request_tag_q;
        if (request_window_hit) begin
          state_q <= STATE_HIT_WAIT;
          stat_window_hits <= sat_inc(stat_window_hits);
        end else begin
          state_q <= STATE_MISS;
          refill_q <= request_refill_q;
          miss_voice_q <= request_voice_q;
          miss_base_q <= request_line_q;
          miss_tag_q <= request_tag_q;
          request_count_q <= '0;
          response_count_q <= '0;
          if (request_refill_q) begin
            stat_window_refills <= sat_inc(stat_window_refills);
            if (window_meta_read_q[META_WIDTH-1])
              stat_evictions <= sat_inc(stat_evictions);
          end else begin
            stat_fallback_reads <= sat_inc(stat_fallback_reads);
          end
        end
      end

      if (state_q == STATE_HIT_WAIT) begin
        rsp_valid_q <= 1'b1;
        rsp_data_q.words <= window_read_data_q;
        state_q <= STATE_IDLE;
      end

      if (memory_req_fire) begin
        request_count_q <= request_count_q + 1'b1;
        stat_memory_reads <= sat_inc(stat_memory_reads);
      end

      if (memory_rsp_fire) begin
        response_count_q <= response_count_q + 1'b1;
        if (response_count_q == '0) begin
          rsp_valid_q <= 1'b1;
          rsp_addr_q <= {miss_base_q, {LINE_SHIFT{1'b0}}};
          rsp_tag_q <= miss_tag_q;
          rsp_data_q <= memory_rsp;
        end
        if ((response_count_q + 1'b1) >= transaction_line_count) begin
          state_q <= STATE_IDLE;
        end
      end

      if (diagnostics_clear) begin
        stat_client_requests <= '0;
        stat_window_hits <= '0;
        stat_window_refills <= '0;
        stat_fallback_reads <= '0;
        stat_memory_reads <= '0;
        stat_evictions <= '0;
        stat_stall_cycles <= '0;
      end
    end
  end
endmodule
