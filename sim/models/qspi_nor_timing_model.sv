`timescale 1ns/1ps

module qspi_nor_timing_model #(
  parameter int ADDR_WIDTH = 32,
  parameter int LINE_WORDS = 8,
  parameter int REQUEST_QUEUE_DEPTH = 16,
  parameter int INIT_CYCLES = 8,
  parameter int COMMAND_BITS = 8,
  parameter int COMMAND_LANES = 1,
  parameter int ADDRESS_BITS = 32,
  parameter int ADDRESS_LANES = 4,
  parameter int MODE_BITS = 8,
  parameter int MODE_LANES = 4,
  parameter int DUMMY_CYCLES = 8,
  parameter int DATA_LANES = 4,
  parameter int CS_HIGH_CYCLES = 1,
  parameter bit CONTINUOUS_READ = 1'b1,
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
  output logic [63:0]                  stat_sequential_lines,
  output logic [63:0]                  stat_random_lines,
  output logic [63:0]                  stat_transactions,
  output logic [63:0]                  stat_overhead_cycles,
  output logic [63:0]                  stat_data_cycles
);
  import "DPI-C" function int ddr3_bin_open(input string path);
  import "DPI-C" function shortint unsigned ddr3_bin_read_word(
      input int handle, input longint unsigned word_address);
  import "DPI-C" function longint unsigned ddr3_bin_word_count(input int handle);
  import "DPI-C" function void ddr3_bin_close(input int handle);

  localparam int LINE_SHIFT = $clog2(LINE_WORDS);
  localparam int COMMAND_CYCLES =
      (COMMAND_BITS + COMMAND_LANES - 1) / COMMAND_LANES;
  localparam int ADDRESS_CYCLES =
      (ADDRESS_BITS + ADDRESS_LANES - 1) / ADDRESS_LANES;
  localparam int MODE_CYCLES =
      (MODE_BITS + MODE_LANES - 1) / MODE_LANES;
  localparam int OVERHEAD_CYCLES = COMMAND_CYCLES + ADDRESS_CYCLES +
                                   MODE_CYCLES + DUMMY_CYCLES +
                                   CS_HIGH_CYCLES;
  localparam int DATA_CYCLES =
      (LINE_WORDS * 16 + DATA_LANES - 1) / DATA_LANES;
  localparam int TIMER_WIDTH = $clog2(OVERHEAD_CYCLES + DATA_CYCLES + 1);
  localparam int QUEUE_INDEX_WIDTH =
      (REQUEST_QUEUE_DEPTH <= 1) ? 1 : $clog2(REQUEST_QUEUE_DEPTH);
  localparam int QUEUE_COUNT_WIDTH = $clog2(REQUEST_QUEUE_DEPTH + 1);

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
  logic following_is_sequential;
  logic [QUEUE_INDEX_WIDTH-1:0] following_index;

  function automatic logic [QUEUE_INDEX_WIDTH-1:0] increment_index(
      input logic [QUEUE_INDEX_WIDTH-1:0] index);
    if (index == QUEUE_INDEX_WIDTH'(REQUEST_QUEUE_DEPTH - 1))
      return '0;
    return index + 1'b1;
  endfunction

  initial begin
    if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
      $fatal(1, "qspi_nor_timing_model LINE_WORDS must be a power of two");
    if (REQUEST_QUEUE_DEPTH < 2)
      $fatal(1, "qspi_nor_timing_model queue depth must be at least two");
    if (COMMAND_BITS < 1 || COMMAND_LANES < 1 || ADDRESS_BITS < 1 ||
        ADDRESS_LANES < 1 || MODE_BITS < 0 || MODE_LANES < 1 ||
        DUMMY_CYCLES < 0 || DATA_LANES < 1 || CS_HIGH_CYCLES < 0)
      $fatal(1, "qspi_nor_timing_model has invalid protocol geometry");
    if (ADDR_WIDTH < LINE_SHIFT)
      $fatal(1, "qspi_nor_timing_model address width is too small");

    if (!$value$plusargs("QSPI_IMAGE=%s", selected_image_path))
      selected_image_path = IMAGE_PATH;
    image_handle = ddr3_bin_open(selected_image_path);
    if (image_handle < 0)
      $fatal(1, "qspi_nor_timing_model failed to load '%s'", selected_image_path);
    $display("QSPI_NOR_MODEL image=%s words=%0d overhead_cycles=%0d data_cycles=%0d",
             selected_image_path, ddr3_bin_word_count(image_handle),
             OVERHEAD_CYCLES, DATA_CYCLES);
  end

  final begin
    if (image_handle >= 0) ddr3_bin_close(image_handle);
  end

  assign following_index = increment_index(head_q);
  assign have_following_request = count_q > QUEUE_COUNT_WIDTH'(1);
  assign following_is_sequential = have_following_request &&
      request_addr[following_index] ==
          request_addr[head_q] + ADDR_WIDTH'(LINE_WORDS);
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
      stat_sequential_lines <= '0;
      stat_random_lines <= '0;
      stat_transactions <= '0;
      stat_overhead_cycles <= '0;
      stat_data_cycles <= '0;
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
          $fatal(1, "qspi_nor_timing_model accepted unaligned line address %0h",
                 req_addr);
        request_addr[tail_q] <= req_addr;
        tail_q <= increment_index(tail_q);
        stat_accepted <= stat_accepted + 1'b1;
      end

      if (!active_q && count_q != '0) begin
        active_q <= 1'b1;
        cycles_remaining_q <= TIMER_WIDTH'(OVERHEAD_CYCLES + DATA_CYCLES);
        stat_random_lines <= stat_random_lines + 1'b1;
        stat_transactions <= stat_transactions + 1'b1;
        stat_overhead_cycles <= stat_overhead_cycles + 64'(OVERHEAD_CYCLES);
        stat_data_cycles <= stat_data_cycles + 64'(DATA_CYCLES);
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

        if (CONTINUOUS_READ && following_is_sequential) begin
          active_q <= 1'b1;
          cycles_remaining_q <= TIMER_WIDTH'(DATA_CYCLES);
          stat_sequential_lines <= stat_sequential_lines + 1'b1;
          stat_data_cycles <= stat_data_cycles + 64'(DATA_CYCLES);
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
