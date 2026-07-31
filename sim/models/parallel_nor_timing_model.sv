`timescale 1ns/1ps

module parallel_nor_timing_model #(
  parameter int ADDR_WIDTH = 32,
  parameter int LINE_WORDS = 8,
  parameter int REQUEST_QUEUE_DEPTH = 16,
  parameter int INIT_CYCLES = 8,
  parameter int PAGE_WORDS = 16,
  parameter int CLOCK_PERIOD_NS = 10,
  parameter int RANDOM_ACCESS_NS = 100,
  parameter int PAGE_ACCESS_NS = 15,
  parameter longint unsigned DEVICE_WORDS = 64'd64 * 1024 * 1024,
  parameter int DEVICE_COUNT = 3,
  parameter string IMAGE_PATH = ""
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         req_valid,
  output logic                         req_ready,
  input  logic [ADDR_WIDTH-1:0]        req_addr,
  output logic                         rsp_valid,
  input  logic                         rsp_ready,
  output logic [LINE_WORDS*16-1:0]     rsp_data,
  output logic [63:0]                  stat_accepted,
  output logic [63:0]                  stat_returned,
  output logic [63:0]                  stat_page_lines,
  output logic [63:0]                  stat_random_lines,
  output logic [63:0]                  stat_transactions,
  output logic [63:0]                  stat_random_access_cycles,
  output logic [63:0]                  stat_page_access_cycles
);
  import "DPI-C" function int ddr3_bin_open(input string path);
  import "DPI-C" function shortint unsigned ddr3_bin_read_word(
      input int handle, input longint unsigned word_address);
  import "DPI-C" function longint unsigned ddr3_bin_word_count(input int handle);
  import "DPI-C" function void ddr3_bin_close(input int handle);

  localparam int LINE_SHIFT = $clog2(LINE_WORDS);
  localparam int PAGE_SHIFT = $clog2(PAGE_WORDS);
  localparam int RANDOM_CYCLES =
      (RANDOM_ACCESS_NS + CLOCK_PERIOD_NS - 1) / CLOCK_PERIOD_NS;
  localparam int PAGE_CYCLES =
      (PAGE_ACCESS_NS + CLOCK_PERIOD_NS - 1) / CLOCK_PERIOD_NS;
  localparam int RANDOM_LINE_CYCLES =
      RANDOM_CYCLES + (LINE_WORDS - 1) * PAGE_CYCLES;
  localparam int PAGE_LINE_CYCLES = LINE_WORDS * PAGE_CYCLES;
  localparam int PAGE_TAIL_CYCLES = (LINE_WORDS - 1) * PAGE_CYCLES;
  localparam int MAX_LINE_CYCLES =
      (RANDOM_LINE_CYCLES > PAGE_LINE_CYCLES) ?
      RANDOM_LINE_CYCLES : PAGE_LINE_CYCLES;
  localparam int TIMER_WIDTH = $clog2(MAX_LINE_CYCLES + 1);
  localparam int QUEUE_INDEX_WIDTH =
      (REQUEST_QUEUE_DEPTH <= 1) ? 1 : $clog2(REQUEST_QUEUE_DEPTH);
  localparam int QUEUE_COUNT_WIDTH = $clog2(REQUEST_QUEUE_DEPTH + 1);
  localparam longint unsigned TOTAL_WORDS = DEVICE_WORDS * DEVICE_COUNT;

  logic [ADDR_WIDTH-1:0] request_addr [0:REQUEST_QUEUE_DEPTH-1];
  logic [QUEUE_INDEX_WIDTH-1:0] head_q;
  logic [QUEUE_INDEX_WIDTH-1:0] tail_q;
  logic [QUEUE_COUNT_WIDTH-1:0] count_q;
  logic [TIMER_WIDTH-1:0] cycles_remaining_q;
  logic active_q;
  logic [63:0] cycle_q;
  int image_handle;
  string selected_image_path;

  logic accept_request;
  logic complete_line;
  logic have_following_request;
  logic following_is_same_page;
  logic [QUEUE_INDEX_WIDTH-1:0] following_index;

  function automatic logic [QUEUE_INDEX_WIDTH-1:0] increment_index(
      input logic [QUEUE_INDEX_WIDTH-1:0] index);
    if (index == QUEUE_INDEX_WIDTH'(REQUEST_QUEUE_DEPTH - 1))
      return '0;
    return index + 1'b1;
  endfunction

  initial begin
    if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
      $fatal(1, "parallel_nor_timing_model LINE_WORDS must be a power of two");
    if (PAGE_WORDS < LINE_WORDS ||
        (PAGE_WORDS & (PAGE_WORDS - 1)) != 0 ||
        (PAGE_WORDS % LINE_WORDS) != 0)
      $fatal(1, "parallel_nor_timing_model has invalid page geometry");
    if (REQUEST_QUEUE_DEPTH < 2 || CLOCK_PERIOD_NS < 1 ||
        RANDOM_ACCESS_NS < 1 || PAGE_ACCESS_NS < 1 ||
        DEVICE_WORDS < 64'(PAGE_WORDS) || DEVICE_COUNT < 1)
      $fatal(1, "parallel_nor_timing_model has invalid parameters");
    if (ADDR_WIDTH < PAGE_SHIFT)
      $fatal(1, "parallel_nor_timing_model address width is too small");

    if (!$value$plusargs("PARALLEL_NOR_IMAGE=%s", selected_image_path))
      selected_image_path = IMAGE_PATH;
    image_handle = ddr3_bin_open(selected_image_path);
    if (image_handle < 0)
      $fatal(1, "parallel_nor_timing_model failed to load '%s'",
             selected_image_path);
    if (ddr3_bin_word_count(image_handle) > TOTAL_WORDS)
      $fatal(1, "parallel NOR image has %0d words but %0d devices hold %0d",
             ddr3_bin_word_count(image_handle), DEVICE_COUNT, TOTAL_WORDS);
    $display("PARALLEL_NOR_MODEL image=%s words=%0d devices=%0d random_cycles=%0d page_cycles=%0d page_words=%0d",
             selected_image_path, ddr3_bin_word_count(image_handle),
             DEVICE_COUNT, RANDOM_CYCLES, PAGE_CYCLES, PAGE_WORDS);
  end

  final begin
    if (image_handle >= 0) ddr3_bin_close(image_handle);
  end

  assign following_index = increment_index(head_q);
  assign have_following_request = count_q > QUEUE_COUNT_WIDTH'(1);
  assign following_is_same_page = have_following_request &&
      request_addr[following_index][ADDR_WIDTH-1:PAGE_SHIFT] ==
          request_addr[head_q][ADDR_WIDTH-1:PAGE_SHIFT];
  assign req_ready = cycle_q >= 64'(INIT_CYCLES) &&
                     count_q < QUEUE_COUNT_WIDTH'(REQUEST_QUEUE_DEPTH);
  assign accept_request = req_valid && req_ready;
  assign complete_line = active_q &&
                         cycles_remaining_q == TIMER_WIDTH'(1) &&
                         (!rsp_valid || rsp_ready);

  always_ff @(posedge clk) begin
    if (rst) begin
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
      cycles_remaining_q <= '0;
      active_q <= 1'b0;
      cycle_q <= '0;
      rsp_valid <= 1'b0;
      rsp_data <= '0;
      stat_accepted <= '0;
      stat_returned <= '0;
      stat_page_lines <= '0;
      stat_random_lines <= '0;
      stat_transactions <= '0;
      stat_random_access_cycles <= '0;
      stat_page_access_cycles <= '0;
      for (int index = 0; index < REQUEST_QUEUE_DEPTH; index++)
        request_addr[index] <= '0;
    end else begin
      cycle_q <= cycle_q + 1'b1;

      if (rsp_valid && rsp_ready) begin
        rsp_valid <= 1'b0;
        stat_returned <= stat_returned + 1'b1;
      end

      if (accept_request) begin
        if (req_addr[LINE_SHIFT-1:0] != '0)
          $fatal(1, "parallel_nor_timing_model accepted unaligned address %0h",
                 req_addr);
        if (64'(req_addr) + 64'(LINE_WORDS) > TOTAL_WORDS)
          $fatal(1, "parallel_nor_timing_model address %0h exceeds capacity",
                 req_addr);
        request_addr[tail_q] <= req_addr;
        tail_q <= increment_index(tail_q);
        stat_accepted <= stat_accepted + 1'b1;
      end

      if (!active_q && count_q != '0) begin
        active_q <= 1'b1;
        cycles_remaining_q <= TIMER_WIDTH'(RANDOM_LINE_CYCLES);
        stat_random_lines <= stat_random_lines + 1'b1;
        stat_transactions <= stat_transactions + 1'b1;
        stat_random_access_cycles <=
            stat_random_access_cycles + 64'(RANDOM_CYCLES);
        stat_page_access_cycles <= stat_page_access_cycles +
            64'(PAGE_TAIL_CYCLES);
      end else if (active_q && cycles_remaining_q > TIMER_WIDTH'(1)) begin
        cycles_remaining_q <= cycles_remaining_q - 1'b1;
      end

      if (complete_line) begin
        for (int word = 0; word < LINE_WORDS; word++) begin
          rsp_data[word*16 +: 16] <= ddr3_bin_read_word(
              image_handle, 64'(request_addr[head_q]) + 64'(word));
        end
        rsp_valid <= 1'b1;
        head_q <= increment_index(head_q);

        if (following_is_same_page) begin
          active_q <= 1'b1;
          cycles_remaining_q <= TIMER_WIDTH'(PAGE_LINE_CYCLES);
          stat_page_lines <= stat_page_lines + 1'b1;
          stat_page_access_cycles <=
              stat_page_access_cycles + 64'(PAGE_LINE_CYCLES);
        end else if (have_following_request) begin
          active_q <= 1'b1;
          cycles_remaining_q <= TIMER_WIDTH'(RANDOM_LINE_CYCLES);
          stat_random_lines <= stat_random_lines + 1'b1;
          stat_transactions <= stat_transactions + 1'b1;
          stat_random_access_cycles <=
              stat_random_access_cycles + 64'(RANDOM_CYCLES);
          stat_page_access_cycles <= stat_page_access_cycles +
              64'(PAGE_TAIL_CYCLES);
        end else begin
          active_q <= 1'b0;
          cycles_remaining_q <= '0;
        end
      end

      unique case ({accept_request, complete_line})
        2'b10: count_q <= count_q + 1'b1;
        2'b01: count_q <= count_q - 1'b1;
        default: count_q <= count_q;
      endcase
    end
  end
endmodule
