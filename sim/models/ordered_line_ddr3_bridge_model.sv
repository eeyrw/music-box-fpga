`timescale 1ns/1ps

module ordered_line_ddr3_bridge_model #(
  parameter int ADDR_WIDTH = 32,
  parameter int LINE_WORDS = 8,
  parameter int DQ_WIDTH = 16,
  parameter int BURST_LENGTH = 8,
  parameter int CDC_QUEUE_DEPTH = 16,
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
  input  logic                         core_clk,
  input  logic                         core_rst,
  input  logic                         ddr_clk,
  input  logic                         ddr_rst,
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
  typedef logic [ADDR_WIDTH-1:0] address_t;
  typedef logic [LINE_WORDS*16-1:0] line_t;

  mailbox #(address_t) request_cdc;
  mailbox #(line_t) response_cdc;
  address_t next_request_addr;
  address_t discarded_request_addr;
  line_t next_response_data;
  line_t discarded_response_data;
  logic ddr_req_valid;
  logic ddr_req_ready;
  address_t ddr_req_addr;
  logic ddr_rsp_valid;
  logic ddr_rsp_ready;
  line_t ddr_rsp_data;

  initial begin
    request_cdc = new(CDC_QUEUE_DEPTH);
    response_cdc = new(CDC_QUEUE_DEPTH);
  end

  always_comb begin
    req_ready = !core_rst && (request_cdc.num() < CDC_QUEUE_DEPTH);
    ddr_rsp_ready = !ddr_rst && (response_cdc.num() < CDC_QUEUE_DEPTH);
  end

  always_ff @(posedge core_clk) begin
    if (core_rst) begin
      rsp_valid <= 1'b0;
      rsp_data <= '0;
      while (request_cdc.try_get(discarded_request_addr) != 0) begin end
      while (response_cdc.try_get(discarded_response_data) != 0) begin end
    end else begin
      if (req_valid && req_ready && request_cdc.try_put(req_addr) == 0)
        $fatal(1, "DDR3 request CDC queue overflow");

      if (!rsp_valid || rsp_ready) begin
        if (response_cdc.try_get(next_response_data) != 0) begin
          rsp_valid <= 1'b1;
          rsp_data <= next_response_data;
        end else begin
          rsp_valid <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge ddr_clk) begin
    if (ddr_rst) begin
      ddr_req_valid <= 1'b0;
      ddr_req_addr <= '0;
    end else begin
      if (ddr_req_valid && ddr_req_ready)
        ddr_req_valid <= 1'b0;
      if ((!ddr_req_valid || ddr_req_ready) &&
          request_cdc.try_get(next_request_addr) != 0) begin
        ddr_req_valid <= 1'b1;
        ddr_req_addr <= next_request_addr;
      end
      if (ddr_rsp_valid && ddr_rsp_ready &&
          response_cdc.try_put(ddr_rsp_data) == 0)
        $fatal(1, "DDR3 response CDC queue overflow");
    end
  end

  ddr3_timing_model #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .LINE_WORDS(LINE_WORDS),
    .DQ_WIDTH(DQ_WIDTH),
    .BURST_LENGTH(BURST_LENGTH),
    .BANK_COUNT(BANK_COUNT),
    .ROW_BITS(ROW_BITS),
    .COLUMN_BITS(COLUMN_BITS),
    .BANK_ROW_COLUMN(BANK_ROW_COLUMN),
    .REQUEST_QUEUE_DEPTH(REQUEST_QUEUE_DEPTH),
    .INIT_CYCLES(INIT_CYCLES),
    .T_RCD(T_RCD),
    .T_RP(T_RP),
    .T_CL(T_CL),
    .T_RAS(T_RAS),
    .T_RC(T_RC),
    .T_CCD(T_CCD),
    .T_RTP(T_RTP),
    .T_RRD(T_RRD),
    .T_FAW(T_FAW),
    .T_RFC(T_RFC),
    .T_REFI(T_REFI),
    .IMAGE_PATH(IMAGE_PATH)
  ) timing (
    .clk(ddr_clk),
    .rst(ddr_rst),
    .req_valid(ddr_req_valid),
    .req_ready(ddr_req_ready),
    .req_addr(ddr_req_addr),
    .rsp_valid(ddr_rsp_valid),
    .rsp_ready(ddr_rsp_ready),
    .rsp_data(ddr_rsp_data),
    .stat_accepted,
    .stat_returned,
    .stat_row_hits,
    .stat_row_misses,
    .stat_activates,
    .stat_precharges,
    .stat_refreshes
  );
endmodule
