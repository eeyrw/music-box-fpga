module sd_native_block_reader #(
  parameter int unsigned LBA_WIDTH = 32,
  parameter int unsigned CLK_HZ = 100_000_000,
  parameter int unsigned INIT_TIMEOUT_MS = 1_100,
  parameter int unsigned READ_RETRY_LIMIT = 2,
  parameter bit ENABLE_HIGH_SPEED = 1'b1
) (
  input  logic clk,
  input  logic rst,
  input  logic init_start,
  output logic initialized,
  output logic high_speed_active,
  output logic busy,
  output logic [7:0] error_code,
  output logic [7:0] retry_count,
  output logic [3:0] recovery_error_code,

  input  logic block_req_valid,
  output logic block_req_ready,
  input  logic [LBA_WIDTH-1:0] block_req_lba,
  input  logic [15:0] block_req_block_count,

  output logic block_byte_valid,
  input  logic block_byte_ready,
  output logic [7:0] block_byte_data,
  output logic block_byte_last,

  output logic phy_cmd_valid,
  input  logic phy_cmd_ready,
  output logic [5:0] phy_cmd_index,
  output logic [31:0] phy_cmd_arg,
  output sd_native_pkg::sd_response_type_t phy_cmd_resp_type,
  output logic phy_cmd_data_read,
  output logic [15:0] phy_cmd_block_len,
  output logic [15:0] phy_cmd_block_count,
  output logic phy_rsp_data_proceed,
  output logic phy_rsp_data_cancel,
  output logic phy_abort_request,
  input  logic phy_rsp_valid,
  input  sd_native_pkg::sd_transport_status_t phy_rsp_status,
  input  logic [119:0] phy_rsp_data,
  input  logic phy_transaction_done,

  input  logic phy_data_valid,
  output logic phy_data_ready,
  input  logic [7:0] phy_data,
  input  logic phy_data_last,
  input  sd_native_pkg::sd_transport_status_t phy_data_status
);
  import sd_native_pkg::*;

  localparam longint unsigned INIT_TIMEOUT_CYCLES_RAW =
      (longint'(CLK_HZ) * INIT_TIMEOUT_MS + 999) / 1_000;
  localparam int unsigned INIT_TIMEOUT_CYCLES =
      INIT_TIMEOUT_CYCLES_RAW < 1 ? 1 : int'(INIT_TIMEOUT_CYCLES_RAW);
  localparam int unsigned INIT_TIMEOUT_WIDTH =
      INIT_TIMEOUT_CYCLES <= 1 ? 1 : $clog2(INIT_TIMEOUT_CYCLES);

  localparam logic [7:0] ERROR_NONE = 8'd0;
  localparam logic [7:0] ERROR_CMD8 = 8'd1;
  localparam logic [7:0] ERROR_ACMD41 = 8'd2;
  localparam logic [7:0] ERROR_NOT_SDHC = 8'd3;
  localparam logic [7:0] ERROR_CMD2 = 8'd4;
  localparam logic [7:0] ERROR_CMD3 = 8'd5;
  localparam logic [7:0] ERROR_CMD7 = 8'd6;
  localparam logic [7:0] ERROR_ACMD6 = 8'd7;
  localparam logic [7:0] ERROR_CMD17 = 8'd8;
  localparam logic [7:0] ERROR_DATA = 8'd9;
  localparam logic [7:0] ERROR_CMD6 = 8'd10;
  localparam logic [7:0] ERROR_CARD_STATUS = 8'd13;
  localparam logic [7:0] ERROR_CARD_STATE = 8'd14;
  localparam logic [7:0] ERROR_BUSY_TIMEOUT = 8'd15;
  localparam logic [7:0] ERROR_INIT_TIMEOUT = 8'd16;
  localparam logic [7:0] ERROR_ACMD42 = 8'd17;
  localparam logic [7:0] ERROR_CMD6_SELECT = 8'd18;
  localparam logic [7:0] ERROR_POWER_CYCLE_REQUIRED = 8'd19;
  localparam logic [7:0] ERROR_ACMD51 = 8'd20;
  localparam logic [7:0] ERROR_CMD12 = 8'd21;

  localparam logic [5:0] CMD0 = 6'd0;
  localparam logic [5:0] CMD2 = 6'd2;
  localparam logic [5:0] CMD3 = 6'd3;
  localparam logic [5:0] CMD6 = 6'd6;
  localparam logic [5:0] CMD7 = 6'd7;
  localparam logic [5:0] CMD8 = 6'd8;
  localparam logic [5:0] CMD12 = 6'd12;
  localparam logic [5:0] CMD17 = 6'd17;
  localparam logic [5:0] CMD18 = 6'd18;
  localparam logic [5:0] CMD23 = 6'd23;
  localparam logic [5:0] CMD55 = 6'd55;
  localparam logic [5:0] ACMD6 = 6'd6;
  localparam logic [5:0] ACMD41 = 6'd41;
  localparam logic [5:0] ACMD42 = 6'd42;
  localparam logic [5:0] ACMD51 = 6'd51;
  localparam logic [31:0] ACMD41_ARG = 32'h4030_0000;
  localparam logic [31:0] CMD6_QUERY_HIGH_SPEED_ARG = 32'h00ff_fff1;
  localparam logic [31:0] CMD6_SWITCH_HIGH_SPEED_ARG = 32'h80ff_fff1;
  localparam logic [31:0] R1_ERROR_MASK = 32'hffff_e008;
  localparam logic [3:0] CARD_STATE_IDLE = 4'd0;
  localparam logic [3:0] CARD_STATE_STANDBY = 4'd3;
  localparam logic [3:0] CARD_STATE_TRANSFER = 4'd4;

  typedef enum logic [4:0] {
    STATE_IDLE,
    STATE_SEND,
    STATE_WAIT_RSP,
    STATE_READ_DATA,
    STATE_WAIT_DATA_TRANSACTION,
    STATE_EMIT_BLOCK,
    STATE_WAIT_RETRY_TRANSACTION,
    STATE_WAIT_CMD6_TRANSACTION,
    STATE_WAIT_SCR_TRANSACTION,
    STATE_WAIT_MULTI_TRANSACTION,
    STATE_WAIT_MULTI_COMMAND_FALLBACK,
    STATE_WAIT_ABORT_TRANSACTION,
    STATE_WAIT_STOP_TRANSACTION,
    STATE_ERROR
  } state_t;

  typedef enum logic [4:0] {
    OP_NONE,
    OP_CMD0,
    OP_CMD8,
    OP_CMD55_IDLE,
    OP_ACMD41,
    OP_CMD2,
    OP_CMD3,
    OP_CMD7,
    OP_CMD55_CD,
    OP_ACMD42,
    OP_CMD55_4BIT,
    OP_ACMD6,
    OP_CMD55_SCR,
    OP_ACMD51,
    OP_CMD6_QUERY,
    OP_CMD6_SWITCH,
    OP_CMD17,
    OP_CMD23,
    OP_CMD18,
    OP_CMD12_NORMAL,
    OP_CMD12_RECOVERY
  } op_t;

  state_t state;
  op_t op;
  logic [5:0] pending_cmd_index;
  logic [31:0] pending_cmd_arg;
  sd_response_type_t pending_resp_type;
  logic pending_data_read;
  logic [15:0] pending_block_len;
  logic [15:0] pending_block_count;
  logic [15:0] rca;
  logic [INIT_TIMEOUT_WIDTH-1:0] init_timeout_count;
  logic init_timer_active;
  logic [LBA_WIDTH-1:0] active_lba;
  logic [15:0] blocks_remaining;
  logic [8:0] data_count;
  logic [8:0] emit_count;
  logic [7:0] block_buffer [0:511];
  logic cmd6_high_speed_supported;
  logic cmd6_high_speed_busy;
  logic [3:0] cmd6_selection;
  logic cmd6_is_switch;
  logic cmd23_supported;
  logic multi_used_cmd23;
  logic emit_resume_multi;
  logic recovery_due_to_data;
  logic [7:0] current_retry_count;

  logic cmd_accept;
  logic data_accept;
  logic [15:0] request_block_count;

  assign phy_cmd_valid = state == STATE_SEND;
  assign phy_cmd_index = pending_cmd_index;
  assign phy_cmd_arg = pending_cmd_arg;
  assign phy_cmd_resp_type = pending_resp_type;
  assign phy_cmd_data_read = pending_data_read;
  assign phy_cmd_block_len = pending_block_len;
  assign phy_cmd_block_count = pending_block_count;
  assign cmd_accept = phy_cmd_valid && phy_cmd_ready;
  assign phy_data_ready = state == STATE_READ_DATA;
  assign data_accept = phy_data_valid && phy_data_ready;
  assign block_req_ready = state == STATE_IDLE && initialized;
  assign busy = state != STATE_IDLE;
  assign request_block_count = block_req_block_count == 0 ? 16'd1 : block_req_block_count;

  function automatic logic r1_has_error(input logic [31:0] status);
    r1_has_error = |(status & R1_ERROR_MASK);
  endfunction

  function automatic logic r1_state_is(input logic [3:0] current_state, input logic [3:0] expected);
    r1_state_is = current_state == expected;
  endfunction

  function automatic logic r6_has_error(input logic [2:0] error_bits);
    r6_has_error = |error_bits;
  endfunction

  task automatic start_command(
      input logic [5:0] index,
      input logic [31:0] arg,
      input sd_response_type_t response_type,
      input logic data_read,
      input logic [15:0] block_len,
      input logic [15:0] block_count,
      input op_t next_op);
    begin
      pending_cmd_index <= index;
      pending_cmd_arg <= arg;
      pending_resp_type <= response_type;
      pending_data_read <= data_read;
      pending_block_len <= block_len;
      pending_block_count <= block_count;
      op <= next_op;
      state <= STATE_SEND;
    end
  endtask

  task automatic fail(input logic [7:0] code);
    begin
      error_code <= code;
      initialized <= 1'b0;
      high_speed_active <= 1'b0;
      state <= STATE_ERROR;
    end
  endtask

  task automatic finish_default_speed_init;
    begin
      initialized <= 1'b1;
      high_speed_active <= 1'b0;
      error_code <= ERROR_NONE;
      state <= STATE_IDLE;
    end
  endtask

  task automatic retry_or_fail(input logic due_to_data);
    begin
      if (current_retry_count < 8'(READ_RETRY_LIMIT)) begin
        current_retry_count <= current_retry_count + 8'd1;
        if (retry_count != 8'hff)
          retry_count <= retry_count + 8'd1;
        state <= STATE_WAIT_RETRY_TRANSACTION;
      end else begin
        fail(due_to_data ? ERROR_DATA : ERROR_CMD17);
      end
    end
  endtask

  task automatic start_single_block_retry(input logic due_to_data);
    begin
      if (current_retry_count < 8'(READ_RETRY_LIMIT)) begin
        current_retry_count <= current_retry_count + 8'd1;
        if (retry_count != 8'hff)
          retry_count <= retry_count + 8'd1;
        data_count <= '0;
        emit_resume_multi <= 1'b0;
        start_command(CMD17, 32'(active_lba), SD_RESP_R1,
                      1'b1, 16'd512, 16'd1, OP_CMD17);
      end else begin
        fail(due_to_data ? ERROR_DATA : ERROR_CMD17);
      end
    end
  endtask

  task automatic start_multi_read(input logic use_cmd23);
    begin
      multi_used_cmd23 <= use_cmd23;
      data_count <= '0;
      start_command(CMD18, 32'(active_lba), SD_RESP_R1,
                    1'b1, 16'd512, blocks_remaining, OP_CMD18);
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      op <= OP_NONE;
      initialized <= 1'b0;
      high_speed_active <= 1'b0;
      error_code <= ERROR_NONE;
      retry_count <= '0;
      recovery_error_code <= '0;
      current_retry_count <= '0;
      pending_cmd_index <= '0;
      pending_cmd_arg <= '0;
      pending_resp_type <= SD_RESP_NONE;
      pending_data_read <= 1'b0;
      pending_block_len <= '0;
      pending_block_count <= '0;
      rca <= '0;
      init_timeout_count <= '0;
      init_timer_active <= 1'b0;
      active_lba <= '0;
      blocks_remaining <= '0;
      data_count <= '0;
      emit_count <= '0;
      cmd6_high_speed_supported <= 1'b0;
      cmd6_high_speed_busy <= 1'b0;
      cmd6_selection <= '0;
      cmd6_is_switch <= 1'b0;
      cmd23_supported <= 1'b0;
      multi_used_cmd23 <= 1'b0;
      emit_resume_multi <= 1'b0;
      recovery_due_to_data <= 1'b0;
      block_byte_valid <= 1'b0;
      block_byte_data <= '0;
      block_byte_last <= 1'b0;
      phy_rsp_data_proceed <= 1'b0;
      phy_rsp_data_cancel <= 1'b0;
      phy_abort_request <= 1'b0;
    end else begin
      phy_rsp_data_proceed <= 1'b0;
      phy_rsp_data_cancel <= 1'b0;
      phy_abort_request <= 1'b0;
      if (block_byte_valid && block_byte_ready) begin
        block_byte_valid <= 1'b0;
        block_byte_last <= 1'b0;
      end

      if (init_timer_active && state != STATE_IDLE && state != STATE_ERROR) begin
        if (init_timeout_count == INIT_TIMEOUT_WIDTH'(INIT_TIMEOUT_CYCLES - 1)) begin
          fail(ERROR_INIT_TIMEOUT);
        end else begin
          init_timeout_count <= init_timeout_count + INIT_TIMEOUT_WIDTH'(1);
        end
      end

      unique case (state)
        STATE_IDLE: begin
          if (init_start && !initialized) begin
            error_code <= ERROR_NONE;
            retry_count <= '0;
            recovery_error_code <= '0;
            init_timeout_count <= '0;
            init_timer_active <= 1'b0;
            start_command(CMD0, 32'h0, SD_RESP_NONE, 1'b0, 16'd0, 16'd0, OP_CMD0);
          end else if (block_req_valid && block_req_ready) begin
            active_lba <= block_req_lba;
            blocks_remaining <= request_block_count;
            current_retry_count <= '0;
            data_count <= '0;
            emit_resume_multi <= 1'b0;
            if (request_block_count == 16'd1) begin
              start_command(CMD17, 32'(block_req_lba), SD_RESP_R1,
                            1'b1, 16'd512, 16'd1, OP_CMD17);
            end else if (cmd23_supported) begin
              start_command(CMD23, 32'(request_block_count), SD_RESP_R1,
                            1'b0, 16'd0, 16'd0, OP_CMD23);
            end else begin
              multi_used_cmd23 <= 1'b0;
              start_command(CMD18, 32'(block_req_lba), SD_RESP_R1,
                            1'b1, 16'd512, request_block_count, OP_CMD18);
            end
          end
        end

        STATE_SEND: begin
          if (cmd_accept) begin
            if (pending_resp_type == SD_RESP_NONE) begin
              if (op == OP_CMD0)
                start_command(CMD8, 32'h0000_01aa, SD_RESP_R7,
                              1'b0, 16'd0, 16'd0, OP_CMD8);
              else
                state <= STATE_IDLE;
            end else begin
              state <= STATE_WAIT_RSP;
            end
          end
        end

        STATE_WAIT_RSP: begin
          if (phy_rsp_valid) begin
            unique case (op)
              OP_CMD8: begin
                if (phy_rsp_status == SD_STATUS_OK && phy_rsp_data[11:0] == 12'h1aa)
                  start_command(CMD55, 32'h0, SD_RESP_R1,
                                1'b0, 16'd0, 16'd0, OP_CMD55_IDLE);
                else
                  fail(ERROR_CMD8);
              end

              OP_CMD55_IDLE: begin
                if (phy_rsp_status != SD_STATUS_OK)
                  fail(ERROR_ACMD41);
                else if (r1_has_error(phy_rsp_data[31:0]) || !phy_rsp_data[5])
                  fail(ERROR_CARD_STATUS);
                else if (!r1_state_is(phy_rsp_data[12:9], CARD_STATE_IDLE))
                  fail(ERROR_CARD_STATE);
                else begin
                  init_timer_active <= 1'b1;
                  start_command(ACMD41, ACMD41_ARG, SD_RESP_R3,
                                1'b0, 16'd0, 16'd0, OP_ACMD41);
                end
              end

              OP_ACMD41: begin
                if (phy_rsp_status != SD_STATUS_OK) begin
                  fail(ERROR_ACMD41);
                end else if (phy_rsp_data[31]) begin
                  init_timer_active <= 1'b0;
                  if (phy_rsp_data[30])
                    start_command(CMD2, 32'h0, SD_RESP_R2,
                                  1'b0, 16'd0, 16'd0, OP_CMD2);
                  else
                    fail(ERROR_NOT_SDHC);
                end else begin
                  start_command(CMD55, 32'h0, SD_RESP_R1,
                                1'b0, 16'd0, 16'd0, OP_CMD55_IDLE);
                end
              end

              OP_CMD2: begin
                if (phy_rsp_status == SD_STATUS_OK)
                  start_command(CMD3, 32'h0, SD_RESP_R6,
                                1'b0, 16'd0, 16'd0, OP_CMD3);
                else
                  fail(ERROR_CMD2);
              end

              OP_CMD3: begin
                if (phy_rsp_status != SD_STATUS_OK)
                  fail(ERROR_CMD3);
                else if (r6_has_error(phy_rsp_data[15:13]))
                  fail(ERROR_CARD_STATUS);
                else if (!r1_state_is(phy_rsp_data[12:9], CARD_STATE_STANDBY))
                  fail(ERROR_CARD_STATE);
                else begin
                  rca <= phy_rsp_data[31:16];
                  start_command(CMD7, {phy_rsp_data[31:16], 16'h0}, SD_RESP_R1B,
                                1'b0, 16'd0, 16'd0, OP_CMD7);
                end
              end

              OP_CMD7: begin
                if (phy_rsp_status == SD_STATUS_BUSY_TIMEOUT)
                  fail(ERROR_BUSY_TIMEOUT);
                else if (phy_rsp_status != SD_STATUS_OK)
                  fail(ERROR_CMD7);
                else if (r1_has_error(phy_rsp_data[31:0]))
                  fail(ERROR_CARD_STATUS);
                else if (!(r1_state_is(phy_rsp_data[12:9], CARD_STATE_STANDBY)
                           || r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER)))
                  fail(ERROR_CARD_STATE);
                else
                  start_command(CMD55, {rca, 16'h0}, SD_RESP_R1,
                                1'b0, 16'd0, 16'd0, OP_CMD55_CD);
              end

              OP_CMD55_CD, OP_CMD55_4BIT, OP_CMD55_SCR: begin
                if (phy_rsp_status != SD_STATUS_OK)
                  fail(op == OP_CMD55_CD ? ERROR_ACMD42
                       : op == OP_CMD55_SCR ? ERROR_ACMD51 : ERROR_ACMD6);
                else if (r1_has_error(phy_rsp_data[31:0]) || !phy_rsp_data[5])
                  fail(ERROR_CARD_STATUS);
                else if (!r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER))
                  fail(ERROR_CARD_STATE);
                else if (op == OP_CMD55_CD)
                  start_command(ACMD42, 32'h0, SD_RESP_R1,
                                1'b0, 16'd0, 16'd0, OP_ACMD42);
                else if (op == OP_CMD55_4BIT)
                  start_command(ACMD6, 32'h2, SD_RESP_R1,
                                1'b0, 16'd0, 16'd0, OP_ACMD6);
                else
                  start_command(ACMD51, 32'h0, SD_RESP_R1,
                                1'b1, 16'd8, 16'd1, OP_ACMD51);
              end

              OP_ACMD42: begin
                if (phy_rsp_status != SD_STATUS_OK)
                  fail(ERROR_ACMD42);
                else if (r1_has_error(phy_rsp_data[31:0]))
                  fail(ERROR_CARD_STATUS);
                else if (!r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER))
                  fail(ERROR_CARD_STATE);
                else
                  start_command(CMD55, {rca, 16'h0}, SD_RESP_R1,
                                1'b0, 16'd0, 16'd0, OP_CMD55_4BIT);
              end

              OP_ACMD6: begin
                if (phy_rsp_status != SD_STATUS_OK)
                  fail(ERROR_ACMD6);
                else if (r1_has_error(phy_rsp_data[31:0]))
                  fail(ERROR_CARD_STATUS);
                else if (!r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER))
                  fail(ERROR_CARD_STATE);
                else begin
                  cmd23_supported <= 1'b0;
                  start_command(CMD55, {rca, 16'h0}, SD_RESP_R1,
                                1'b0, 16'd0, 16'd0, OP_CMD55_SCR);
                end
              end

              OP_ACMD51: begin
                if (phy_rsp_status == SD_STATUS_OK
                    && !r1_has_error(phy_rsp_data[31:0])
                    && r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER)) begin
                  phy_rsp_data_proceed <= 1'b1;
                  data_count <= '0;
                  cmd23_supported <= 1'b0;
                  state <= STATE_READ_DATA;
                end else begin
                  phy_rsp_data_cancel <= 1'b1;
                  fail(ERROR_ACMD51);
                end
              end

              OP_CMD23: begin
                if (phy_rsp_status == SD_STATUS_OK
                    && !r1_has_error(phy_rsp_data[31:0])
                    && r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER)) begin
                  start_multi_read(1'b1);
                end else begin
                  cmd23_supported <= 1'b0;
                  start_multi_read(1'b0);
                end
              end

              OP_CMD18: begin
                if (phy_rsp_status == SD_STATUS_OK
                    && !r1_has_error(phy_rsp_data[31:0])
                    && r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER)) begin
                  phy_rsp_data_proceed <= 1'b1;
                  data_count <= '0;
                  state <= STATE_READ_DATA;
                end else begin
                  phy_rsp_data_cancel <= 1'b1;
                  recovery_due_to_data <= 1'b0;
                  state <= STATE_WAIT_MULTI_COMMAND_FALLBACK;
                end
              end

              OP_CMD12_NORMAL, OP_CMD12_RECOVERY: begin
                if (phy_rsp_status == SD_STATUS_BUSY_TIMEOUT) begin
                  recovery_error_code <= 4'd2;
                  fail(op == OP_CMD12_RECOVERY ? ERROR_DATA : ERROR_BUSY_TIMEOUT);
                end else if (phy_rsp_status != SD_STATUS_OK
                             || r1_has_error(phy_rsp_data[31:0])) begin
                  recovery_error_code <= 4'd1;
                  fail(op == OP_CMD12_RECOVERY ? ERROR_DATA : ERROR_CMD12);
                end else begin
                  state <= STATE_WAIT_STOP_TRANSACTION;
                end
              end

              OP_CMD6_QUERY, OP_CMD6_SWITCH: begin
                if (phy_rsp_status == SD_STATUS_OK
                    && !r1_has_error(phy_rsp_data[31:0])
                    && r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER)) begin
                  phy_rsp_data_proceed <= 1'b1;
                  data_count <= '0;
                  cmd6_high_speed_supported <= 1'b0;
                  cmd6_high_speed_busy <= 1'b0;
                  cmd6_selection <= '0;
                  cmd6_is_switch <= op == OP_CMD6_SWITCH;
                  state <= STATE_READ_DATA;
                end else begin
                  phy_rsp_data_cancel <= 1'b1;
                  if (phy_rsp_status != SD_STATUS_OK)
                    fail(ERROR_CMD6);
                  else
                    fail(r1_has_error(phy_rsp_data[31:0])
                         ? ERROR_CARD_STATUS : ERROR_CARD_STATE);
                end
              end

              OP_CMD17: begin
                if (phy_rsp_status == SD_STATUS_OK
                    && !r1_has_error(phy_rsp_data[31:0])
                    && r1_state_is(phy_rsp_data[12:9], CARD_STATE_TRANSFER)) begin
                  phy_rsp_data_proceed <= 1'b1;
                  data_count <= '0;
                  state <= STATE_READ_DATA;
                end else begin
                  phy_rsp_data_cancel <= 1'b1;
                  retry_or_fail(1'b0);
                end
              end

              default: fail(ERROR_CMD17);
            endcase
          end
        end

        STATE_READ_DATA: begin
          if (data_accept) begin
            if (phy_data_status != SD_STATUS_OK) begin
              if (op == OP_CMD6_QUERY || op == OP_CMD6_SWITCH) begin
                if (phy_data_status == SD_STATUS_CRC_ERROR)
                  fail(ERROR_POWER_CYCLE_REQUIRED);
                else
                  fail(ERROR_CMD6);
              end else if (op == OP_ACMD51) begin
                fail(ERROR_ACMD51);
              end else if (op == OP_CMD18) begin
                recovery_due_to_data <= 1'b1;
                phy_abort_request <= 1'b1;
                state <= STATE_WAIT_ABORT_TRANSACTION;
              end else begin
                retry_or_fail(1'b1);
              end
            end else if (op == OP_ACMD51) begin
              if (data_count == 9'd3)
                cmd23_supported <= phy_data[1];
              if (phy_data_last != (data_count == 9'd7)) begin
                fail(ERROR_ACMD51);
              end else if (phy_data_last) begin
                state <= STATE_WAIT_SCR_TRANSACTION;
              end else begin
                data_count <= data_count + 9'd1;
              end
            end else if (op == OP_CMD6_QUERY || op == OP_CMD6_SWITCH) begin
              if (data_count == 9'd13)
                cmd6_high_speed_supported <= phy_data[1];
              if (data_count == 9'd15)
                cmd6_high_speed_busy <= phy_data[1];
              if (data_count == 9'd16)
                cmd6_selection <= phy_data[3:0];
              if (phy_data_last != (data_count == 9'd63)) begin
                fail(ERROR_CMD6);
              end else if (phy_data_last) begin
                state <= STATE_WAIT_CMD6_TRANSACTION;
              end else begin
                data_count <= data_count + 9'd1;
              end
            end else begin
              block_buffer[data_count] <= phy_data;
              if (phy_data_last != (data_count == 9'd511)) begin
                if (op == OP_CMD18) begin
                  recovery_due_to_data <= 1'b1;
                  phy_abort_request <= 1'b1;
                  state <= STATE_WAIT_ABORT_TRANSACTION;
                end else begin
                  retry_or_fail(1'b1);
                end
              end else if (phy_data_last) begin
                if (op == OP_CMD18) begin
                  if (blocks_remaining == 16'd1) begin
                    state <= STATE_WAIT_MULTI_TRANSACTION;
                  end else begin
                    emit_count <= '0;
                    block_byte_data <= block_buffer[0];
                    block_byte_last <= 1'b0;
                    block_byte_valid <= 1'b1;
                    emit_resume_multi <= 1'b1;
                    state <= STATE_EMIT_BLOCK;
                  end
                end else begin
                  emit_resume_multi <= 1'b0;
                  state <= STATE_WAIT_DATA_TRANSACTION;
                end
              end else begin
                data_count <= data_count + 9'd1;
              end
            end
          end
        end

        STATE_WAIT_CMD6_TRANSACTION: begin
          if (phy_transaction_done) begin
            if (!cmd6_is_switch) begin
              if (cmd6_high_speed_supported && !cmd6_high_speed_busy) begin
                start_command(CMD6, CMD6_SWITCH_HIGH_SPEED_ARG, SD_RESP_R1,
                              1'b1, 16'd64, 16'd1, OP_CMD6_SWITCH);
              end else begin
                finish_default_speed_init();
              end
            end else if (cmd6_selection == 4'h1) begin
              initialized <= 1'b1;
              high_speed_active <= 1'b1;
              error_code <= ERROR_NONE;
              state <= STATE_IDLE;
            end else if (cmd6_selection == 4'h0) begin
              finish_default_speed_init();
            end else begin
              fail(ERROR_CMD6_SELECT);
            end
          end
        end

        STATE_WAIT_SCR_TRANSACTION: begin
          if (phy_transaction_done) begin
            if (ENABLE_HIGH_SPEED) begin
              cmd6_high_speed_supported <= 1'b0;
              cmd6_high_speed_busy <= 1'b0;
              cmd6_selection <= '0;
              cmd6_is_switch <= 1'b0;
              data_count <= '0;
              start_command(CMD6, CMD6_QUERY_HIGH_SPEED_ARG, SD_RESP_R1,
                            1'b1, 16'd64, 16'd1, OP_CMD6_QUERY);
            end else begin
              finish_default_speed_init();
            end
          end
        end

        STATE_WAIT_MULTI_TRANSACTION: begin
          if (phy_transaction_done) begin
            if (multi_used_cmd23) begin
              emit_count <= '0;
              block_byte_data <= block_buffer[0];
              block_byte_last <= 1'b0;
              block_byte_valid <= 1'b1;
              emit_resume_multi <= 1'b0;
              state <= STATE_EMIT_BLOCK;
            end else begin
              start_command(CMD12, 32'h0, SD_RESP_R1B,
                            1'b0, 16'd0, 16'd0, OP_CMD12_NORMAL);
            end
          end
        end

        STATE_WAIT_MULTI_COMMAND_FALLBACK: begin
          if (phy_transaction_done)
            start_single_block_retry(1'b0);
        end

        STATE_WAIT_ABORT_TRANSACTION: begin
          if (phy_transaction_done)
            start_command(CMD12, 32'h0, SD_RESP_R1B,
                          1'b0, 16'd0, 16'd0, OP_CMD12_RECOVERY);
        end

        STATE_WAIT_STOP_TRANSACTION: begin
          if (phy_transaction_done) begin
            if (op == OP_CMD12_NORMAL) begin
              emit_count <= '0;
              block_byte_data <= block_buffer[0];
              block_byte_last <= 1'b0;
              block_byte_valid <= 1'b1;
              emit_resume_multi <= 1'b0;
              state <= STATE_EMIT_BLOCK;
            end else begin
              start_single_block_retry(recovery_due_to_data);
            end
          end
        end

        STATE_WAIT_DATA_TRANSACTION: begin
          if (phy_transaction_done) begin
            emit_count <= '0;
            block_byte_data <= block_buffer[0];
            block_byte_last <= blocks_remaining == 16'd1 && 9'd0 == 9'd511;
            block_byte_valid <= 1'b1;
            state <= STATE_EMIT_BLOCK;
          end
        end

        STATE_EMIT_BLOCK: begin
          if (block_byte_valid && block_byte_ready) begin
            if (emit_count == 9'd511) begin
              current_retry_count <= '0;
              if (blocks_remaining > 16'd1) begin
                active_lba <= active_lba + LBA_WIDTH'(1);
                blocks_remaining <= blocks_remaining - 16'd1;
                data_count <= '0;
                if (emit_resume_multi) begin
                  state <= STATE_READ_DATA;
                end else begin
                  start_command(CMD17, 32'(active_lba + LBA_WIDTH'(1)), SD_RESP_R1,
                                1'b1, 16'd512, 16'd1, OP_CMD17);
                end
              end else begin
                state <= STATE_IDLE;
              end
            end else begin
              emit_count <= emit_count + 9'd1;
              block_byte_data <= block_buffer[emit_count + 9'd1];
              block_byte_last <= blocks_remaining == 16'd1 && emit_count == 9'd510;
              block_byte_valid <= 1'b1;
            end
          end
        end

        STATE_WAIT_RETRY_TRANSACTION: begin
          if (phy_transaction_done) begin
            data_count <= '0;
            start_command(CMD17, 32'(active_lba), SD_RESP_R1,
                          1'b1, 16'd512, 16'd1, OP_CMD17);
          end
        end

        STATE_ERROR: begin
          if (init_start) begin
            error_code <= ERROR_NONE;
            retry_count <= '0;
            recovery_error_code <= '0;
            init_timeout_count <= '0;
            init_timer_active <= 1'b0;
            start_command(CMD0, 32'h0, SD_RESP_NONE, 1'b0, 16'd0, 16'd0, OP_CMD0);
          end
        end

        default: fail(ERROR_CMD17);
      endcase
    end
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_rsp_upper;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_rsp_upper = ^phy_rsp_data[119:32];
endmodule
