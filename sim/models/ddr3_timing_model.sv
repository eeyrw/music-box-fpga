`timescale 1ns/1ps

module ddr3_timing_model #(
  parameter int ADDR_WIDTH = 32,
  parameter int LINE_WORDS = 8,
  parameter int DQ_WIDTH = 16,
  parameter int BURST_LENGTH = 8,
  parameter int BANK_COUNT = 8,
  parameter int ROW_BITS = 15,
  parameter int COLUMN_BITS = 7,
  parameter bit BANK_ROW_COLUMN = 1'b1,
  parameter int REQUEST_QUEUE_DEPTH = 32,
  parameter int INIT_CYCLES = 40,
  parameter int T_RCD = 6,
  parameter int T_RP = 6,
  parameter int T_CL = 6,
  parameter int T_RAS = 14,
  parameter int T_RC = 20,
  parameter int T_CCD = 4,
  parameter int T_RTP = 3,
  parameter int T_RRD = 4,
  parameter int T_FAW = 20,
  parameter int T_RFC = 104,
  parameter int T_REFI = 3120,
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
  output logic [63:0]                  stat_row_hits,
  output logic [63:0]                  stat_row_misses,
  output logic [63:0]                  stat_activates,
  output logic [63:0]                  stat_precharges,
  output logic [63:0]                  stat_refreshes
);
  import "DPI-C" function int ddr3_bin_open(input string path);
  import "DPI-C" function shortint unsigned ddr3_bin_read_word(
      input int handle, input longint unsigned word_address);
  import "DPI-C" function longint unsigned ddr3_bin_word_count(input int handle);
  import "DPI-C" function void ddr3_bin_close(input int handle);

  localparam int LINE_SHIFT = $clog2(LINE_WORDS);
  localparam int BANK_BITS = $clog2(BANK_COUNT);
  localparam int BURST_CYCLES = BURST_LENGTH / 2;
  localparam int READ_SPACING = (T_CCD > BURST_CYCLES) ? T_CCD : BURST_CYCLES;

  typedef enum logic [1:0] {
    REQ_WAIT,
    REQ_READ_ISSUED,
    REQ_COMPLETE
  } request_state_t;

  request_state_t request_state [0:REQUEST_QUEUE_DEPTH-1];
  logic request_valid [0:REQUEST_QUEUE_DEPTH-1];
  logic [63:0] request_sequence [0:REQUEST_QUEUE_DEPTH-1];
  logic [ADDR_WIDTH-1:0] request_addr [0:REQUEST_QUEUE_DEPTH-1];
  logic [BANK_BITS-1:0] request_bank [0:REQUEST_QUEUE_DEPTH-1];
  logic [63:0] request_row [0:REQUEST_QUEUE_DEPTH-1];
  logic [63:0] request_complete_cycle [0:REQUEST_QUEUE_DEPTH-1];
  logic request_had_activate [0:REQUEST_QUEUE_DEPTH-1];

  logic bank_open [0:BANK_COUNT-1];
  logic [63:0] bank_row [0:BANK_COUNT-1];
  logic [63:0] bank_next_activate [0:BANK_COUNT-1];
  logic [63:0] bank_next_precharge [0:BANK_COUNT-1];
  logic [63:0] bank_next_read [0:BANK_COUNT-1];

  logic [63:0] cycle_q;
  logic [63:0] next_sequence_q;
  logic [63:0] response_sequence_q;
  logic [63:0] next_read_cycle_q;
  logic [63:0] next_activate_cycle_q;
  logic [63:0] activate_history_q [0:3];
  logic [2:0] activate_history_count_q;
  logic [63:0] data_bus_busy_until_q;
  logic [63:0] next_refresh_cycle_q;
  logic [63:0] refresh_block_until_q;
  logic refresh_pending_q;
  int image_handle;
  string selected_image_path;

  int free_index;
  int completed_index;
  int row_hit_index;
  int activate_index;
  int precharge_index;
  int refresh_precharge_bank;
  logic all_banks_closed;
  logic all_banks_refresh_ready;
  logic rank_activate_ready;
  logic initialized;

  function automatic logic [BANK_BITS-1:0] decode_bank(
      input logic [ADDR_WIDTH-1:0] address);
    logic [63:0] line_index;
    line_index = 64'(address) >> LINE_SHIFT;
    if (BANK_ROW_COLUMN)
      return BANK_BITS'(line_index >> (COLUMN_BITS + ROW_BITS));
    return BANK_BITS'(line_index >> COLUMN_BITS);
  endfunction

  function automatic logic [63:0] decode_row(
      input logic [ADDR_WIDTH-1:0] address);
    logic [63:0] line_index;
    line_index = 64'(address) >> LINE_SHIFT;
    if (BANK_ROW_COLUMN)
      return (line_index >> COLUMN_BITS) & ((64'd1 << ROW_BITS) - 1'b1);
    return line_index >> (COLUMN_BITS + BANK_BITS);
  endfunction

  initial begin
    if (LINE_WORDS < 1 || (LINE_WORDS & (LINE_WORDS - 1)) != 0)
      $fatal(1, "ddr3_timing_model LINE_WORDS must be a power of two");
    if (BANK_COUNT < 1 || (BANK_COUNT & (BANK_COUNT - 1)) != 0)
      $fatal(1, "ddr3_timing_model BANK_COUNT must be a power of two");
    if (ROW_BITS < 1 || COLUMN_BITS < 1 ||
        (ROW_BITS + COLUMN_BITS + BANK_BITS) > (ADDR_WIDTH - LINE_SHIFT))
      $fatal(1, "ddr3_timing_model address geometry is invalid");
    if (REQUEST_QUEUE_DEPTH < 1)
      $fatal(1, "ddr3_timing_model REQUEST_QUEUE_DEPTH must be positive");
    if (DQ_WIDTH < 1 || BURST_LENGTH < 2 || (BURST_LENGTH & 1) != 0)
      $fatal(1, "ddr3_timing_model requires positive DQ width and even burst length");
    if (LINE_WORDS * 16 != DQ_WIDTH * BURST_LENGTH)
      $fatal(1, "ddr3_timing_model line must equal one physical DDR burst");
    if (T_REFI <= T_RFC)
      $fatal(1, "ddr3_timing_model T_REFI must exceed T_RFC");
    if (T_RRD < 1 || T_FAW < 4)
      $fatal(1, "ddr3_timing_model requires positive ACT timing constraints");

    if (!$value$plusargs("DDR3_IMAGE=%s", selected_image_path))
      selected_image_path = IMAGE_PATH;
    image_handle = ddr3_bin_open(selected_image_path);
    if (image_handle < 0)
      $fatal(1, "ddr3_timing_model failed to load '%s'", selected_image_path);
    $display("DDR3_MODEL image=%s words=%0d", selected_image_path,
             ddr3_bin_word_count(image_handle));
  end

  final begin
    if (image_handle >= 0) ddr3_bin_close(image_handle);
  end

  always_comb begin
    free_index = -1;
    completed_index = -1;
    row_hit_index = -1;
    activate_index = -1;
    precharge_index = -1;
    refresh_precharge_bank = -1;
    all_banks_closed = 1'b1;
    all_banks_refresh_ready = 1'b1;
    initialized = cycle_q >= 64'(INIT_CYCLES);
    rank_activate_ready = cycle_q >= next_activate_cycle_q &&
                          (activate_history_count_q < 3'd4 ||
                           cycle_q >= activate_history_q[0] + 64'(T_FAW));
    if (cycle_q < data_bus_busy_until_q)
      all_banks_refresh_ready = 1'b0;

    for (int bank = 0; bank < BANK_COUNT; bank++) begin
      if (bank_open[bank]) begin
        all_banks_closed = 1'b0;
        if (refresh_precharge_bank < 0 &&
            cycle_q >= bank_next_precharge[bank])
          refresh_precharge_bank = bank;
      end
      if (cycle_q < bank_next_activate[bank])
        all_banks_refresh_ready = 1'b0;
    end

    for (int index = 0; index < REQUEST_QUEUE_DEPTH; index++) begin
      if (!request_valid[index] && free_index < 0)
        free_index = index;
      if (request_valid[index] && request_state[index] == REQ_COMPLETE &&
          request_sequence[index] == response_sequence_q)
        completed_index = index;

      if (request_valid[index] && request_state[index] == REQ_WAIT) begin
        if (bank_open[request_bank[index]] &&
            bank_row[request_bank[index]] == request_row[index] &&
            cycle_q >= bank_next_read[request_bank[index]] &&
            cycle_q >= next_read_cycle_q &&
            (row_hit_index < 0 ||
             request_sequence[index] < request_sequence[row_hit_index]))
          row_hit_index = index;
        if (!bank_open[request_bank[index]] &&
            cycle_q >= bank_next_activate[request_bank[index]] &&
            rank_activate_ready &&
            (activate_index < 0 ||
             request_sequence[index] < request_sequence[activate_index]))
          activate_index = index;
        if (bank_open[request_bank[index]] &&
            bank_row[request_bank[index]] != request_row[index] &&
            cycle_q >= bank_next_precharge[request_bank[index]] &&
            (precharge_index < 0 ||
             request_sequence[index] < request_sequence[precharge_index]))
          precharge_index = index;
      end
    end

    req_ready = initialized && !refresh_pending_q &&
                cycle_q >= refresh_block_until_q && free_index >= 0;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      cycle_q <= '0;
      next_sequence_q <= '0;
      response_sequence_q <= '0;
      next_read_cycle_q <= '0;
      next_activate_cycle_q <= '0;
      activate_history_count_q <= '0;
      data_bus_busy_until_q <= '0;
      next_refresh_cycle_q <= 64'(INIT_CYCLES) + 64'(T_REFI);
      refresh_block_until_q <= '0;
      refresh_pending_q <= 1'b0;
      rsp_valid <= 1'b0;
      rsp_data <= '0;
      stat_accepted <= '0;
      stat_returned <= '0;
      stat_row_hits <= '0;
      stat_row_misses <= '0;
      stat_activates <= '0;
      stat_precharges <= '0;
      stat_refreshes <= '0;
      for (int history = 0; history < 4; history++)
        activate_history_q[history] <= '0;
      for (int index = 0; index < REQUEST_QUEUE_DEPTH; index++) begin
        request_valid[index] <= 1'b0;
        request_state[index] <= REQ_WAIT;
        request_sequence[index] <= '0;
        request_addr[index] <= '0;
        request_bank[index] <= '0;
        request_row[index] <= '0;
        request_complete_cycle[index] <= '0;
        request_had_activate[index] <= 1'b0;
      end
      for (int bank = 0; bank < BANK_COUNT; bank++) begin
        bank_open[bank] <= 1'b0;
        bank_row[bank] <= '0;
        bank_next_activate[bank] <= '0;
        bank_next_precharge[bank] <= '0;
        bank_next_read[bank] <= '0;
      end
    end else begin
      cycle_q <= cycle_q + 1'b1;

      for (int index = 0; index < REQUEST_QUEUE_DEPTH; index++) begin
        if (request_valid[index] && request_state[index] == REQ_READ_ISSUED &&
            cycle_q >= request_complete_cycle[index])
          request_state[index] <= REQ_COMPLETE;
      end

      if (rsp_valid && rsp_ready) begin
        rsp_valid <= 1'b0;
        stat_returned <= stat_returned + 1'b1;
      end
      if ((!rsp_valid || rsp_ready) && completed_index >= 0) begin
        for (int word = 0; word < LINE_WORDS; word++) begin
          rsp_data[word*16 +: 16] <= ddr3_bin_read_word(
              image_handle, 64'(request_addr[completed_index]) + 64'(word));
        end
        rsp_valid <= 1'b1;
        request_valid[completed_index] <= 1'b0;
        response_sequence_q <= response_sequence_q + 1'b1;
      end

      if (req_valid && req_ready) begin
        if (req_addr[LINE_SHIFT-1:0] != '0)
          $fatal(1, "ddr3_timing_model accepted unaligned line address %0h", req_addr);
        request_valid[free_index] <= 1'b1;
        request_state[free_index] <= REQ_WAIT;
        request_sequence[free_index] <= next_sequence_q;
        request_addr[free_index] <= req_addr;
        request_bank[free_index] <= decode_bank(req_addr);
        request_row[free_index] <= decode_row(req_addr);
        request_had_activate[free_index] <= 1'b0;
        next_sequence_q <= next_sequence_q + 1'b1;
        stat_accepted <= stat_accepted + 1'b1;
      end

      if (!refresh_pending_q && initialized &&
          cycle_q >= next_refresh_cycle_q)
        refresh_pending_q <= 1'b1;

      if (refresh_pending_q) begin
        if (refresh_precharge_bank >= 0) begin
          bank_open[refresh_precharge_bank] <= 1'b0;
          if (bank_next_activate[refresh_precharge_bank] < cycle_q + 64'(T_RP))
            bank_next_activate[refresh_precharge_bank] <= cycle_q + 64'(T_RP);
          stat_precharges <= stat_precharges + 1'b1;
        end else if (all_banks_closed && all_banks_refresh_ready) begin
          refresh_pending_q <= 1'b0;
          refresh_block_until_q <= cycle_q + 64'(T_RFC);
          // Keep refreshes on the original average-tREFI timeline. Delaying a
          // refresh therefore creates debt instead of silently lowering rate.
          next_refresh_cycle_q <= next_refresh_cycle_q + 64'(T_REFI);
          stat_refreshes <= stat_refreshes + 1'b1;
          for (int bank = 0; bank < BANK_COUNT; bank++)
            bank_next_activate[bank] <= cycle_q + 64'(T_RFC);
        end
      end else if (cycle_q >= refresh_block_until_q) begin
        if (row_hit_index >= 0) begin
          request_state[row_hit_index] <= REQ_READ_ISSUED;
          // DDR transfers on both CK edges. Publish only after the complete
          // physical burst has been aggregated into one ordered line.
          request_complete_cycle[row_hit_index] <=
              cycle_q + 64'(T_CL) + 64'(BURST_CYCLES);
          data_bus_busy_until_q <=
              cycle_q + 64'(T_CL) + 64'(BURST_CYCLES);
          bank_next_read[request_bank[row_hit_index]] <=
              cycle_q + 64'(READ_SPACING);
          if (bank_next_precharge[request_bank[row_hit_index]] <
              cycle_q + 64'(T_RTP))
            bank_next_precharge[request_bank[row_hit_index]] <=
                cycle_q + 64'(T_RTP);
          next_read_cycle_q <= cycle_q + 64'(READ_SPACING);
          if (!request_had_activate[row_hit_index])
            stat_row_hits <= stat_row_hits + 1'b1;
        end else if (precharge_index >= 0) begin
          bank_open[request_bank[precharge_index]] <= 1'b0;
          if (bank_next_activate[request_bank[precharge_index]] <
              cycle_q + 64'(T_RP))
            bank_next_activate[request_bank[precharge_index]] <=
                cycle_q + 64'(T_RP);
          stat_precharges <= stat_precharges + 1'b1;
        end else if (activate_index >= 0) begin
          bank_open[request_bank[activate_index]] <= 1'b1;
          bank_row[request_bank[activate_index]] <= request_row[activate_index];
          bank_next_read[request_bank[activate_index]] <= cycle_q + 64'(T_RCD);
          bank_next_precharge[request_bank[activate_index]] <= cycle_q + 64'(T_RAS);
          bank_next_activate[request_bank[activate_index]] <= cycle_q + 64'(T_RC);
          next_activate_cycle_q <= cycle_q + 64'(T_RRD);
          activate_history_q[0] <= activate_history_q[1];
          activate_history_q[1] <= activate_history_q[2];
          activate_history_q[2] <= activate_history_q[3];
          activate_history_q[3] <= cycle_q;
          if (activate_history_count_q < 3'd4)
            activate_history_count_q <= activate_history_count_q + 1'b1;
          if (!request_had_activate[activate_index])
            stat_row_misses <= stat_row_misses + 1'b1;
          request_had_activate[activate_index] <= 1'b1;
          stat_activates <= stat_activates + 1'b1;
        end
      end
    end
  end
endmodule
