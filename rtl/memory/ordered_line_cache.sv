module ordered_line_cache #(
  parameter int CACHE_SET_COUNT = 512,
  parameter int MSHR_DEPTH = 8,
  parameter int TAG_COUNT = synth_pkg::BLOCK_WORK_ENTRY_COUNT,
  parameter int TAG_WIDTH = $clog2(TAG_COUNT)
) (
  input  logic                                 clk,
  input  logic                                 rst,

  input  logic                                 client_req_valid,
  output logic                                 client_req_ready,
  input  logic [synth_pkg::ADDR_WIDTH-1:0]     client_req_addr,
  input  logic [TAG_WIDTH-1:0]                 client_req_tag,
  output logic                                 client_rsp_valid,
  input  logic                                 client_rsp_ready,
  output logic [synth_pkg::ADDR_WIDTH-1:0]     client_rsp_addr,
  output logic [TAG_WIDTH-1:0]                 client_rsp_tag,
  output synth_pkg::ordered_line_rsp_t         client_rsp,

  output logic                                 memory_req_valid,
  input  logic                                 memory_req_ready,
  output synth_pkg::ordered_line_req_t         memory_req,
  input  logic                                 memory_rsp_valid,
  output logic                                 memory_rsp_ready,
  input  synth_pkg::ordered_line_rsp_t         memory_rsp,

  output logic [63:0]                          stat_client_requests,
  output logic [63:0]                          stat_cache_hits,
  output logic [63:0]                          stat_mshr_merges,
  output logic [63:0]                          stat_memory_misses,
  output logic [63:0]                          stat_evictions,
  output logic [63:0]                          stat_miss_stall_cycles
);
  import synth_pkg::*;

  localparam int LINE_SHIFT = $clog2(BLOCK_LINE_WORDS);
  localparam int LINE_ADDR_WIDTH = ADDR_WIDTH - LINE_SHIFT;
  localparam int CACHE_SET_WIDTH = $clog2(CACHE_SET_COUNT);
  localparam int MSHR_INDEX_WIDTH = $clog2(MSHR_DEPTH);
  localparam int ISSUE_COUNT_WIDTH = $clog2(MSHR_DEPTH + 1);

  logic [CACHE_SET_COUNT-1:0][1:0] cache_valid_q;
  logic [LINE_ADDR_WIDTH-1:0] cache_tag_q
      [0:CACHE_SET_COUNT-1][0:1];
  ordered_line_rsp_t cache_data_q [0:CACHE_SET_COUNT-1][0:1];
  logic [CACHE_SET_COUNT-1:0] cache_victim_q;

  logic mshr_valid_q [0:MSHR_DEPTH-1];
  logic mshr_filled_q [0:MSHR_DEPTH-1];
  logic [LINE_ADDR_WIDTH-1:0] mshr_line_addr_q [0:MSHR_DEPTH-1];
  logic [TAG_COUNT-1:0] mshr_waiters_q [0:MSHR_DEPTH-1];
  ordered_line_rsp_t mshr_data_q [0:MSHR_DEPTH-1];

  logic [MSHR_INDEX_WIDTH-1:0] issue_fifo_q [0:MSHR_DEPTH-1];
  logic [MSHR_INDEX_WIDTH-1:0] issue_head_q;
  logic [MSHR_INDEX_WIDTH-1:0] issue_tail_q;
  logic [ISSUE_COUNT_WIDTH-1:0] issue_count_q;

  logic rsp_valid_q;
  logic [ADDR_WIDTH-1:0] rsp_addr_q;
  logic [TAG_WIDTH-1:0] rsp_tag_q;
  ordered_line_rsp_t rsp_data_q;

  logic [LINE_ADDR_WIDTH-1:0] request_line_addr;
  logic [CACHE_SET_WIDTH-1:0] request_set;
  logic request_cache_hit;
  logic request_cache_way;
  ordered_line_rsp_t request_cache_data;
  logic request_mshr_hit;
  logic [MSHR_INDEX_WIDTH-1:0] request_mshr_index;
  logic free_mshr_found;
  logic [MSHR_INDEX_WIDTH-1:0] free_mshr_index;
  logic service_found;
  logic [MSHR_INDEX_WIDTH-1:0] service_mshr_index;
  logic [TAG_WIDTH-1:0] service_tag;
  logic output_slot_available;
  logic client_req_fire;
  logic new_miss_fire;

  always_comb begin
    request_line_addr = client_req_addr[ADDR_WIDTH-1:LINE_SHIFT];
    request_set = request_line_addr[CACHE_SET_WIDTH-1:0];
    request_cache_hit = 1'b0;
    request_cache_way = 1'b0;
    request_cache_data = '0;
    for (int way = 0; way < 2; way++) begin
      if (!request_cache_hit && cache_valid_q[request_set][way] &&
          (cache_tag_q[request_set][way] == request_line_addr)) begin
        request_cache_hit = 1'b1;
        request_cache_way = way[0];
        request_cache_data = cache_data_q[request_set][way];
      end
    end

    request_mshr_hit = 1'b0;
    request_mshr_index = '0;
    free_mshr_found = 1'b0;
    free_mshr_index = '0;
    for (int mshr = 0; mshr < MSHR_DEPTH; mshr++) begin
      if (!request_mshr_hit && mshr_valid_q[mshr] &&
          (mshr_line_addr_q[mshr] == request_line_addr)) begin
        request_mshr_hit = 1'b1;
        request_mshr_index = MSHR_INDEX_WIDTH'(mshr);
      end
      if (!free_mshr_found && !mshr_valid_q[mshr]) begin
        free_mshr_found = 1'b1;
        free_mshr_index = MSHR_INDEX_WIDTH'(mshr);
      end
    end

    service_found = 1'b0;
    service_mshr_index = '0;
    service_tag = '0;
    for (int mshr = 0; mshr < MSHR_DEPTH; mshr++) begin
      for (int tag = 0; tag < TAG_COUNT; tag++) begin
        if (!service_found && mshr_valid_q[mshr] && mshr_filled_q[mshr] &&
            mshr_waiters_q[mshr][tag]) begin
          service_found = 1'b1;
          service_mshr_index = MSHR_INDEX_WIDTH'(mshr);
          service_tag = TAG_WIDTH'(tag);
        end
      end
    end

    output_slot_available = !rsp_valid_q || client_rsp_ready;
    if (request_cache_hit)
      client_req_ready = output_slot_available && !service_found;
    else if (request_mshr_hit)
      client_req_ready = 1'b1;
    else
      client_req_ready = free_mshr_found && memory_req_ready &&
          (issue_count_q < ISSUE_COUNT_WIDTH'(MSHR_DEPTH));

    memory_req_valid = client_req_valid && !request_cache_hit &&
        !request_mshr_hit && free_mshr_found &&
        (issue_count_q < ISSUE_COUNT_WIDTH'(MSHR_DEPTH));
    memory_req.aligned_line_addr =
        {request_line_addr, {LINE_SHIFT{1'b0}}};
    memory_rsp_ready = (issue_count_q != '0);

    client_req_fire = client_req_valid && client_req_ready;
    new_miss_fire = memory_req_valid && memory_req_ready;
    client_rsp_valid = rsp_valid_q;
    client_rsp_addr = rsp_addr_q;
    client_rsp_tag = rsp_tag_q;
    client_rsp = rsp_data_q;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      issue_head_q <= '0;
      issue_tail_q <= '0;
      issue_count_q <= '0;
      rsp_valid_q <= 1'b0;
      rsp_addr_q <= '0;
      rsp_tag_q <= '0;
      rsp_data_q <= '0;
      stat_client_requests <= '0;
      stat_cache_hits <= '0;
      stat_mshr_merges <= '0;
      stat_memory_misses <= '0;
      stat_evictions <= '0;
      stat_miss_stall_cycles <= '0;
      cache_valid_q <= '0;
      cache_victim_q <= '0;
      for (int mshr = 0; mshr < MSHR_DEPTH; mshr++) begin
        mshr_valid_q[mshr] <= 1'b0;
        mshr_filled_q[mshr] <= 1'b0;
        mshr_line_addr_q[mshr] <= '0;
        mshr_waiters_q[mshr] <= '0;
        mshr_data_q[mshr] <= '0;
      end
    end else begin
      if (client_req_valid && !client_req_ready && !request_cache_hit &&
          !request_mshr_hit)
        stat_miss_stall_cycles <= stat_miss_stall_cycles + 1'b1;

      if (client_req_fire) begin
        stat_client_requests <= stat_client_requests + 1'b1;
        if (request_cache_hit)
          stat_cache_hits <= stat_cache_hits + 1'b1;
        else if (request_mshr_hit)
          stat_mshr_merges <= stat_mshr_merges + 1'b1;
        else
          stat_memory_misses <= stat_memory_misses + 1'b1;
      end

      if (output_slot_available) begin
        rsp_valid_q <= 1'b0;
        if (service_found) begin
          rsp_valid_q <= 1'b1;
          rsp_addr_q <= {mshr_line_addr_q[service_mshr_index],
                         {LINE_SHIFT{1'b0}}};
          rsp_tag_q <= service_tag;
          rsp_data_q <= mshr_data_q[service_mshr_index];
          mshr_waiters_q[service_mshr_index][service_tag] <= 1'b0;
          if ((mshr_waiters_q[service_mshr_index] &
               ~(TAG_COUNT'(1'b1) << service_tag)) == '0) begin
            mshr_valid_q[service_mshr_index] <= 1'b0;
            mshr_filled_q[service_mshr_index] <= 1'b0;
          end
        end else if (client_req_fire && request_cache_hit) begin
          rsp_valid_q <= 1'b1;
          rsp_addr_q <= {request_line_addr, {LINE_SHIFT{1'b0}}};
          rsp_tag_q <= client_req_tag;
          rsp_data_q <= request_cache_data;
          cache_victim_q[request_set] <= ~request_cache_way;
        end
      end

      if (client_req_fire && request_mshr_hit)
        mshr_waiters_q[request_mshr_index][client_req_tag] <= 1'b1;

      if (new_miss_fire) begin
        mshr_valid_q[free_mshr_index] <= 1'b1;
        mshr_filled_q[free_mshr_index] <= 1'b0;
        mshr_line_addr_q[free_mshr_index] <= request_line_addr;
        mshr_waiters_q[free_mshr_index] <=
            TAG_COUNT'(1'b1) << client_req_tag;
        issue_fifo_q[issue_tail_q] <= free_mshr_index;
        issue_tail_q <= issue_tail_q + 1'b1;
      end

      if (memory_rsp_valid && memory_rsp_ready) begin
        logic fill_way;
        logic [MSHR_INDEX_WIDTH-1:0] fill_mshr;
        logic [CACHE_SET_WIDTH-1:0] fill_set;
        fill_mshr = issue_fifo_q[issue_head_q];
        fill_set = mshr_line_addr_q[fill_mshr][CACHE_SET_WIDTH-1:0];
        mshr_filled_q[fill_mshr] <= 1'b1;
        mshr_data_q[fill_mshr] <= memory_rsp;
        if (!cache_valid_q[fill_set][0])
          fill_way = 1'b0;
        else if (!cache_valid_q[fill_set][1])
          fill_way = 1'b1;
        else
          fill_way = cache_victim_q[fill_set];
        if (cache_valid_q[fill_set][0] && cache_valid_q[fill_set][1])
          stat_evictions <= stat_evictions + 1'b1;
        cache_valid_q[fill_set][fill_way] <= 1'b1;
        cache_tag_q[fill_set][fill_way] <= mshr_line_addr_q[fill_mshr];
        cache_data_q[fill_set][fill_way] <= memory_rsp;
        cache_victim_q[fill_set] <= ~fill_way;
        issue_head_q <= issue_head_q + 1'b1;
      end

      unique case ({new_miss_fire, memory_rsp_valid && memory_rsp_ready})
        2'b10: issue_count_q <= issue_count_q + 1'b1;
        2'b01: issue_count_q <= issue_count_q - 1'b1;
        default: issue_count_q <= issue_count_q;
      endcase
    end
  end
endmodule
