module voice_line_cache #(
  parameter int LINE_WORDS = 32,
  parameter int LINES_PER_VOICE = 2
) (
  input  logic                            clk,
  input  logic                            rst,
  input  synth_pkg::wave_word_req_t       req,
  output logic                            req_ready,
  output synth_pkg::wave_word_rsp_t       rsp,
  output logic                            ext_req_valid,
  input  logic                            ext_req_ready,
  output logic [synth_pkg::ADDR_WIDTH-1:0] ext_req_addr,
  input  logic                            ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0]        ext_rsp_data,
  output logic                            response_trace_pulse,
  output logic [15:0]                     response_trace_latency,
  output logic                            demand_hit_pulse,
  output logic                            demand_miss_pulse,
  output logic                            line_fill_pulse,
  output logic                            same_line_endpoint_hit_pulse,
  output logic                            replacement_pulse,
  output logic                            prefetch_issued_pulse,
  output logic                            prefetch_filled_pulse,
  output logic                            prefetch_used_pulse,
  output logic                            prefetch_dropped_pulse,
  output logic                            prefetch_late_pulse
);
  import synth_pkg::*;

  localparam int INDEX_WIDTH = $clog2(LINE_WORDS);
  localparam int TAG_WIDTH = ADDR_WIDTH - INDEX_WIDTH;
  localparam int WAY_WIDTH = (LINES_PER_VOICE <= 1) ? 1 : $clog2(LINES_PER_VOICE);
  localparam int STREAM_COUNT = 1 << STREAM_ID_WIDTH;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_EXT_REQ,
    STATE_EXT_WAIT,
    STATE_RESPOND
  } state_t;

  state_t state;
  logic [NUM_VOICES-1:0][STREAM_COUNT-1:0][LINES_PER_VOICE-1:0] cache_valid;
  logic [NUM_VOICES-1:0][STREAM_COUNT-1:0][LINES_PER_VOICE-1:0] cache_prefetched;
  logic [NUM_VOICES-1:0][STREAM_COUNT-1:0][LINES_PER_VOICE-1:0][TAG_WIDTH-1:0] cache_tag;
  logic [NUM_VOICES-1:0][STREAM_COUNT-1:0][LINES_PER_VOICE-1:0][LINE_WORDS*PCM_WIDTH-1:0] cache_line;
  logic [NUM_VOICES-1:0][STREAM_COUNT-1:0][WAY_WIDTH-1:0] replace_way;

  logic [VOICE_ID_WIDTH-1:0] pending_voice;
  logic [STREAM_ID_WIDTH-1:0] pending_stream_id;
  logic [TAG_WIDTH-1:0] pending_tag;
  logic [INDEX_WIDTH-1:0] pending_index;
  logic [WAY_WIDTH-1:0] pending_way;
  logic [ADDR_WIDTH-1:0] pending_line_addr;
  logic [15:0] latency_counter;

  logic hit;
  logic [WAY_WIDTH-1:0] hit_way;
  logic [WAY_WIDTH-1:0] fill_way;
  logic fill_replaces_valid;
  pcm_t hit_data;
  logic previous_accept_valid;
  logic [VOICE_ID_WIDTH-1:0] previous_accept_voice;
  logic [STREAM_ID_WIDTH-1:0] previous_accept_stream_id;
  logic [TAG_WIDTH-1:0] previous_accept_tag;
  logic prefetch_valid;
  logic prefetch_inflight;
  logic prefetch_req_active;
  logic [VOICE_ID_WIDTH-1:0] prefetch_voice;
  logic [STREAM_ID_WIDTH-1:0] prefetch_stream_id;
  logic [TAG_WIDTH-1:0] prefetch_tag;
  logic [WAY_WIDTH-1:0] prefetch_way;
  logic [ADDR_WIDTH-1:0] prefetch_addr_aligned;
  logic prefetch_line_hit;
  logic [WAY_WIDTH-1:0] prefetch_fill_way;
  logic prefetch_fill_replaces_valid;
  logic prefetch_fill_replaces_prefetched;
  logic [TAG_WIDTH-1:0] next_prefetch_tag;
  logic [ADDR_WIDTH-1:0] next_prefetch_addr_aligned;
  logic prefetch_candidate;
  logic pending_matches_inflight_prefetch;
  logic same_cycle_prefetch_demand;

  assign req_ready = (state == STATE_IDLE);
  assign ext_req_valid = (state == STATE_EXT_REQ) || prefetch_req_active;
  assign ext_req_addr = (state == STATE_EXT_REQ) ? pending_line_addr : prefetch_addr_aligned;
  assign next_prefetch_addr_aligned =
    {req.addr[ADDR_WIDTH-1:INDEX_WIDTH], {INDEX_WIDTH{1'b0}}} + ADDR_WIDTH'(LINE_WORDS);
  assign next_prefetch_tag = next_prefetch_addr_aligned[ADDR_WIDTH-1:INDEX_WIDTH];
  assign pending_matches_inflight_prefetch = prefetch_inflight &&
                                             pending_voice == prefetch_voice &&
                                             pending_stream_id == prefetch_stream_id &&
                                             pending_tag == prefetch_tag;
  assign same_cycle_prefetch_demand = (state == STATE_IDLE) && prefetch_inflight &&
                                      ext_rsp_valid && req.valid && !hit &&
                                      req.voice == prefetch_voice &&
                                      req.stream_id == prefetch_stream_id &&
                                      req.addr[ADDR_WIDTH-1:INDEX_WIDTH] == prefetch_tag;

  always_comb begin
    hit = 1'b0;
    hit_way = '0;
    hit_data = '0;
    fill_way = replace_way[req.voice][req.stream_id];
    fill_replaces_valid = cache_valid[req.voice][req.stream_id][replace_way[req.voice][req.stream_id]];
    prefetch_line_hit = 1'b0;
    prefetch_fill_way = replace_way[req.voice][req.stream_id];
    prefetch_fill_replaces_valid =
      cache_valid[req.voice][req.stream_id][replace_way[req.voice][req.stream_id]];
    prefetch_fill_replaces_prefetched =
      cache_prefetched[req.voice][req.stream_id][replace_way[req.voice][req.stream_id]];

    for (int w = 0; w < LINES_PER_VOICE; w++) begin
      if (cache_valid[req.voice][req.stream_id][w] &&
          cache_tag[req.voice][req.stream_id][w] == req.addr[ADDR_WIDTH-1:INDEX_WIDTH]) begin
        hit = 1'b1;
        hit_way = WAY_WIDTH'(w);
        hit_data = cache_line[req.voice][req.stream_id][w][req.addr[INDEX_WIDTH-1:0] * PCM_WIDTH +: PCM_WIDTH];
      end
      if (!cache_valid[req.voice][req.stream_id][w]) begin
        fill_way = WAY_WIDTH'(w);
        fill_replaces_valid = 1'b0;
      end
      if (cache_valid[req.voice][req.stream_id][w] &&
          cache_tag[req.voice][req.stream_id][w] == next_prefetch_tag)
        prefetch_line_hit = 1'b1;
      if (!cache_valid[req.voice][req.stream_id][w]) begin
        prefetch_fill_way = WAY_WIDTH'(w);
        prefetch_fill_replaces_valid = 1'b0;
        prefetch_fill_replaces_prefetched = 1'b0;
      end
    end

    prefetch_candidate = req.valid && hit &&
                         (req.addr[INDEX_WIDTH-1:0] >= INDEX_WIDTH'(LINE_WORDS / 2)) &&
                         !prefetch_line_hit && !prefetch_valid && !prefetch_inflight &&
                         !prefetch_req_active;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      cache_valid <= '0;
      cache_prefetched <= '0;
      replace_way <= '0;
      pending_voice <= '0;
      pending_stream_id <= '0;
      pending_tag <= '0;
      pending_index <= '0;
      pending_way <= '0;
      pending_line_addr <= '0;
      latency_counter <= '0;
      rsp <= '0;
      response_trace_pulse <= 1'b0;
      response_trace_latency <= '0;
      demand_hit_pulse <= 1'b0;
      demand_miss_pulse <= 1'b0;
      line_fill_pulse <= 1'b0;
      same_line_endpoint_hit_pulse <= 1'b0;
      replacement_pulse <= 1'b0;
      prefetch_issued_pulse <= 1'b0;
      prefetch_filled_pulse <= 1'b0;
      prefetch_used_pulse <= 1'b0;
      prefetch_dropped_pulse <= 1'b0;
      prefetch_late_pulse <= 1'b0;
      previous_accept_valid <= 1'b0;
      previous_accept_voice <= '0;
      previous_accept_stream_id <= '0;
      previous_accept_tag <= '0;
      prefetch_valid <= 1'b0;
      prefetch_inflight <= 1'b0;
      prefetch_req_active <= 1'b0;
      prefetch_voice <= '0;
      prefetch_stream_id <= '0;
      prefetch_tag <= '0;
      prefetch_way <= '0;
      prefetch_addr_aligned <= '0;
    end else begin
      rsp.valid <= 1'b0;
      response_trace_pulse <= 1'b0;
      demand_hit_pulse <= 1'b0;
      demand_miss_pulse <= 1'b0;
      line_fill_pulse <= 1'b0;
      same_line_endpoint_hit_pulse <= 1'b0;
      replacement_pulse <= 1'b0;
      prefetch_issued_pulse <= 1'b0;
      prefetch_filled_pulse <= 1'b0;
      prefetch_used_pulse <= 1'b0;
      prefetch_dropped_pulse <= 1'b0;
      prefetch_late_pulse <= 1'b0;

      if ((state == STATE_IDLE) && prefetch_req_active) begin
        if (req.valid) begin
          prefetch_req_active <= 1'b0;
        end else if (ext_req_ready) begin
          prefetch_req_active <= 1'b0;
          prefetch_valid <= 1'b0;
          prefetch_inflight <= 1'b1;
          prefetch_issued_pulse <= 1'b1;
        end
      end else if ((state == STATE_IDLE) && !req.valid && prefetch_valid && !prefetch_inflight) begin
        prefetch_req_active <= 1'b1;
      end

      if ((state == STATE_IDLE) && prefetch_inflight && ext_rsp_valid && !same_cycle_prefetch_demand) begin
        prefetch_inflight <= 1'b0;
        cache_valid[prefetch_voice][prefetch_stream_id][prefetch_way] <= 1'b1;
        cache_prefetched[prefetch_voice][prefetch_stream_id][prefetch_way] <= 1'b1;
        cache_tag[prefetch_voice][prefetch_stream_id][prefetch_way] <= prefetch_tag;
        cache_line[prefetch_voice][prefetch_stream_id][prefetch_way] <= ext_rsp_data;
        replace_way[prefetch_voice][prefetch_stream_id] <=
          (prefetch_way == WAY_WIDTH'(LINES_PER_VOICE - 1)) ? '0 : prefetch_way + 1'b1;
        prefetch_filled_pulse <= 1'b1;
      end

      unique case (state)
        STATE_IDLE: begin
          if (req.valid) begin
            pending_voice <= req.voice;
            pending_stream_id <= req.stream_id;
            pending_tag <= req.addr[ADDR_WIDTH-1:INDEX_WIDTH];
            pending_index <= req.addr[INDEX_WIDTH-1:0];
            pending_way <= fill_way;
            pending_line_addr <= {req.addr[ADDR_WIDTH-1:INDEX_WIDTH], {INDEX_WIDTH{1'b0}}};
            latency_counter <= 16'd0;
            previous_accept_valid <= 1'b1;
            previous_accept_voice <= req.voice;
            previous_accept_stream_id <= req.stream_id;
            previous_accept_tag <= req.addr[ADDR_WIDTH-1:INDEX_WIDTH];
            if (hit) begin
              rsp.data <= hit_data;
              demand_hit_pulse <= 1'b1;
              if (cache_prefetched[req.voice][req.stream_id][hit_way]) begin
                cache_prefetched[req.voice][req.stream_id][hit_way] <= 1'b0;
                prefetch_used_pulse <= 1'b1;
              end
              same_line_endpoint_hit_pulse <= previous_accept_valid &&
                                              previous_accept_voice == req.voice &&
                                              previous_accept_stream_id == req.stream_id &&
                                              previous_accept_tag == req.addr[ADDR_WIDTH-1:INDEX_WIDTH];
              if (prefetch_candidate) begin
                prefetch_valid <= 1'b1;
                prefetch_voice <= req.voice;
                prefetch_stream_id <= req.stream_id;
                prefetch_tag <= next_prefetch_tag;
                prefetch_way <= prefetch_fill_way;
                prefetch_addr_aligned <= next_prefetch_addr_aligned;
                if (prefetch_fill_replaces_valid && prefetch_fill_replaces_prefetched)
                  prefetch_dropped_pulse <= 1'b1;
              end
              state <= STATE_RESPOND;
            end else begin
              demand_miss_pulse <= 1'b1;
              replacement_pulse <= fill_replaces_valid;
              if (same_cycle_prefetch_demand) begin
                cache_valid[prefetch_voice][prefetch_stream_id][prefetch_way] <= 1'b1;
                cache_prefetched[prefetch_voice][prefetch_stream_id][prefetch_way] <= 1'b0;
                cache_tag[prefetch_voice][prefetch_stream_id][prefetch_way] <= prefetch_tag;
                cache_line[prefetch_voice][prefetch_stream_id][prefetch_way] <= ext_rsp_data;
                replace_way[prefetch_voice][prefetch_stream_id] <=
                  (prefetch_way == WAY_WIDTH'(LINES_PER_VOICE - 1)) ? '0 : prefetch_way + 1'b1;
                rsp.data <= ext_rsp_data[req.addr[INDEX_WIDTH-1:0] * PCM_WIDTH +: PCM_WIDTH];
                line_fill_pulse <= 1'b1;
                prefetch_inflight <= 1'b0;
                prefetch_late_pulse <= 1'b1;
                state <= STATE_RESPOND;
              end else if (prefetch_valid &&
                  prefetch_voice == req.voice &&
                  prefetch_stream_id == req.stream_id &&
                  prefetch_tag == req.addr[ADDR_WIDTH-1:INDEX_WIDTH]) begin
                prefetch_valid <= 1'b0;
                prefetch_late_pulse <= 1'b1;
                prefetch_dropped_pulse <= 1'b1;
                state <= STATE_EXT_REQ;
              end else if (prefetch_inflight &&
                           prefetch_voice == req.voice &&
                           prefetch_stream_id == req.stream_id &&
                           prefetch_tag == req.addr[ADDR_WIDTH-1:INDEX_WIDTH]) begin
                pending_way <= prefetch_way;
                prefetch_late_pulse <= 1'b1;
                if (ext_req_ready && !ext_rsp_valid) begin
                  prefetch_inflight <= 1'b0;
                  prefetch_dropped_pulse <= 1'b1;
                  state <= STATE_EXT_REQ;
                end else begin
                  state <= STATE_EXT_WAIT;
                end
              end else begin
                if (prefetch_inflight && !ext_rsp_valid && !ext_req_ready) begin
                  state <= STATE_EXT_WAIT;
                end else begin
                  if (prefetch_inflight && !ext_rsp_valid && ext_req_ready) begin
                    prefetch_inflight <= 1'b0;
                    prefetch_dropped_pulse <= 1'b1;
                  end
                  state <= STATE_EXT_REQ;
                end
              end
            end
          end
        end

        STATE_EXT_REQ: begin
          if (ext_req_ready)
            state <= STATE_EXT_WAIT;
        end

        STATE_EXT_WAIT: begin
          if (ext_rsp_valid) begin
            if (prefetch_inflight) begin
              prefetch_inflight <= 1'b0;
              if (!pending_matches_inflight_prefetch) begin
                cache_valid[prefetch_voice][prefetch_stream_id][prefetch_way] <= 1'b1;
                cache_prefetched[prefetch_voice][prefetch_stream_id][prefetch_way] <= 1'b1;
                cache_tag[prefetch_voice][prefetch_stream_id][prefetch_way] <= prefetch_tag;
                cache_line[prefetch_voice][prefetch_stream_id][prefetch_way] <= ext_rsp_data;
                replace_way[prefetch_voice][prefetch_stream_id] <=
                  (prefetch_way == WAY_WIDTH'(LINES_PER_VOICE - 1)) ? '0 : prefetch_way + 1'b1;
                prefetch_filled_pulse <= 1'b1;
                state <= STATE_EXT_REQ;
              end else begin
                cache_valid[pending_voice][pending_stream_id][pending_way] <= 1'b1;
                cache_prefetched[pending_voice][pending_stream_id][pending_way] <= 1'b0;
                cache_tag[pending_voice][pending_stream_id][pending_way] <= pending_tag;
                cache_line[pending_voice][pending_stream_id][pending_way] <= ext_rsp_data;
                replace_way[pending_voice][pending_stream_id] <=
                  (pending_way == WAY_WIDTH'(LINES_PER_VOICE - 1)) ? '0 : pending_way + 1'b1;
                rsp.data <= ext_rsp_data[pending_index * PCM_WIDTH +: PCM_WIDTH];
                line_fill_pulse <= 1'b1;
                state <= STATE_RESPOND;
              end
            end else begin
              cache_valid[pending_voice][pending_stream_id][pending_way] <= 1'b1;
              cache_prefetched[pending_voice][pending_stream_id][pending_way] <= 1'b0;
              cache_tag[pending_voice][pending_stream_id][pending_way] <= pending_tag;
              cache_line[pending_voice][pending_stream_id][pending_way] <= ext_rsp_data;
              replace_way[pending_voice][pending_stream_id] <=
                (pending_way == WAY_WIDTH'(LINES_PER_VOICE - 1)) ? '0 : pending_way + 1'b1;
              rsp.data <= ext_rsp_data[pending_index * PCM_WIDTH +: PCM_WIDTH];
              line_fill_pulse <= 1'b1;
              state <= STATE_RESPOND;
            end
          end
        end

        STATE_RESPOND: begin
          rsp.valid <= 1'b1;
          response_trace_pulse <= 1'b1;
          response_trace_latency <= latency_counter;
          state <= STATE_IDLE;
        end

        default: state <= STATE_IDLE;
      endcase

      if (state != STATE_IDLE && state != STATE_RESPOND && latency_counter != 16'hffff)
        latency_counter <= latency_counter + 16'd1;
    end
  end
endmodule
