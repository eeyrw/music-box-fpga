module sd_native_pin_phy #(
  parameter int unsigned DIV_WIDTH = 16,
  parameter int unsigned SYS_CLK_HZ = 100_000_000,
  parameter int unsigned RESPONSE_TIMEOUT_CYCLES = 4_096,
  parameter int unsigned DATA_TIMEOUT_CYCLES = SYS_CLK_HZ / 10,
  parameter int unsigned BUSY_TIMEOUT_CYCLES = SYS_CLK_HZ / 4,
  parameter int unsigned POWER_UP_CLOCKS = 80,
  parameter int unsigned POST_TRANSACTION_CLOCKS = 8
) (
  input  logic clk,
  input  logic rst,
  input  logic [DIV_WIDTH-1:0] clk_div,

  input  logic cmd_valid,
  output logic cmd_ready,
  input  logic [5:0] cmd_index,
  input  logic [31:0] cmd_arg,
  input  sd_native_pkg::sd_response_type_t cmd_resp_type,
  input  logic cmd_data_read,
  input  logic [15:0] cmd_block_len,
  input  logic [15:0] cmd_block_count,
  input  logic rsp_data_proceed,
  input  logic rsp_data_cancel,
  input  logic abort_request,

  output logic rsp_valid,
  output sd_native_pkg::sd_transport_status_t rsp_status,
  output logic [119:0] rsp_data,
  output logic transaction_done,

  output logic data_valid,
  input  logic data_ready,
  output logic [7:0] data,
  output logic data_last,
  output sd_native_pkg::sd_transport_status_t data_status,

  output logic sd_clk,
  output logic sd_cmd_o,
  output logic sd_cmd_oe,
  input  logic sd_cmd_i,
  input  logic [3:0] sd_dat_i
);
  import sd_native_pkg::*;

  function automatic int unsigned max3(
      input int unsigned a, input int unsigned b, input int unsigned c);
    int unsigned ab;
    begin
      ab = a > b ? a : b;
      max3 = ab > c ? ab : c;
    end
  endfunction

  localparam int unsigned MAX_TIMEOUT_CYCLES =
      max3(RESPONSE_TIMEOUT_CYCLES, DATA_TIMEOUT_CYCLES, BUSY_TIMEOUT_CYCLES);
  localparam int unsigned TIMEOUT_WIDTH =
      MAX_TIMEOUT_CYCLES <= 1 ? 1 : $clog2(MAX_TIMEOUT_CYCLES);
  localparam int unsigned POWER_COUNT_WIDTH =
      POWER_UP_CLOCKS <= 1 ? 1 : $clog2(POWER_UP_CLOCKS);
  localparam int unsigned POST_COUNT_WIDTH =
      POST_TRANSACTION_CLOCKS <= 1 ? 1 : $clog2(POST_TRANSACTION_CLOCKS);

  typedef enum logic [4:0] {
    STATE_POWER_LOW,
    STATE_POWER_HIGH,
    STATE_IDLE,
    STATE_CMD_LOW,
    STATE_CMD_HIGH,
    STATE_RESP_WAIT_LOW,
    STATE_RESP_WAIT_HIGH,
    STATE_RESP_CAPTURE_LOW,
    STATE_RESP_CAPTURE_HIGH,
    STATE_RESP_DECISION,
    STATE_BUSY_WAIT_LOW,
    STATE_BUSY_WAIT_HIGH,
    STATE_DATA_WAIT_LOW,
    STATE_DATA_WAIT_HIGH,
    STATE_DATA_CAPTURE_LOW,
    STATE_DATA_CAPTURE_HIGH,
    STATE_DATA_HOLD,
    STATE_DATA_CRC_LOW,
    STATE_DATA_CRC_HIGH,
    STATE_DATA_END_LOW,
    STATE_DATA_END_HIGH,
    STATE_DATA_EMIT_FINAL,
    STATE_DATA_FINAL_HOLD,
    STATE_ERROR_HOLD,
    STATE_POST_LOW,
    STATE_POST_HIGH,
    STATE_DONE
  } state_t;

  state_t state;
  logic [DIV_WIDTH-1:0] active_clk_div;
  logic [DIV_WIDTH-1:0] div_count;
  logic [47:0] cmd_frame;
  logic [5:0] cmd_bit_index;
  logic [5:0] active_cmd_index;
  sd_response_type_t active_resp_type;
  logic active_data_read;
  logic [15:0] active_block_len;
  logic [15:0] active_block_count;
  logic [7:0] response_bits;
  logic [7:0] rsp_bit_count;
  logic [135:0] rsp_shift;
  logic [TIMEOUT_WIDTH-1:0] timeout_count;
  logic [POWER_COUNT_WIDTH-1:0] power_clock_count;
  logic [POST_COUNT_WIDTH-1:0] post_clock_count;
  logic [15:0] data_byte_count;
  logic data_half;
  logic [3:0] data_high_nibble;
  logic [15:0] crc_dat [0:3];
  logic [15:0] crc_rx [0:3];
  logic [4:0] crc_bit_count;
  logic [7:0] pending_final_data;
  logic end_token_ok;
  logic data_start_seen;
  logic data_start_malformed;
  logic power_clocks_done;
  logic half_tick;

  assign cmd_ready = state == STATE_IDLE && power_clocks_done;
  assign half_tick = div_count == active_clk_div;
  assign response_bits = active_resp_type == SD_RESP_R2 ? 8'd136 : 8'd48;

  function automatic logic [6:0] crc7_next(input logic [6:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[6];
      crc7_next = {crc[5:3], crc[2] ^ feedback, crc[1:0], feedback};
    end
  endfunction

  function automatic logic [6:0] crc7_40(input logic [39:0] payload);
    logic [6:0] crc;
    begin
      crc = '0;
      for (int i = 39; i >= 0; i--)
        crc = crc7_next(crc, payload[i]);
      crc7_40 = crc;
    end
  endfunction

  function automatic logic [6:0] crc7_120(input logic [119:0] payload);
    logic [6:0] crc;
    begin
      crc = '0;
      for (int i = 119; i >= 0; i--)
        crc = crc7_next(crc, payload[i]);
      crc7_120 = crc;
    end
  endfunction

  function automatic logic [6:0] crc7_command(input logic [5:0] index, input logic [31:0] arg);
    crc7_command = crc7_40({2'b01, index, arg});
  endfunction

  function automatic sd_transport_status_t classify_short_response(
      input logic [47:0] response,
      input logic [5:0] index,
      input sd_response_type_t response_type);
    begin
      if (response[47:46] != 2'b00 || !response[0]) begin
        classify_short_response = SD_STATUS_FRAMING_ERROR;
      end else if (response_type == SD_RESP_R3) begin
        if (response[45:40] != 6'h3f || response[7:1] != 7'h7f)
          classify_short_response = SD_STATUS_FRAMING_ERROR;
        else
          classify_short_response = SD_STATUS_OK;
      end else if (response[45:40] != index) begin
        classify_short_response = SD_STATUS_WRONG_INDEX;
      end else if (crc7_40(response[47:8]) != response[7:1]) begin
        classify_short_response = SD_STATUS_CRC_ERROR;
      end else begin
        classify_short_response = SD_STATUS_OK;
      end
    end
  endfunction

  function automatic sd_transport_status_t classify_long_response(input logic [135:0] response);
    begin
      if (response[135:134] != 2'b00 || response[133:128] != 6'h3f || !response[0])
        classify_long_response = SD_STATUS_FRAMING_ERROR;
      else if (crc7_120(response[127:8]) != response[7:1])
        classify_long_response = SD_STATUS_CRC_ERROR;
      else
        classify_long_response = SD_STATUS_OK;
    end
  endfunction

  function automatic logic [15:0] crc16_next(input logic [15:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[15];
      crc16_next = {crc[14:12], crc[11] ^ feedback, crc[10:5],
                    crc[4] ^ feedback, crc[3:0], feedback};
    end
  endfunction

  function automatic logic data_crc_matches;
    data_crc_matches = (crc_rx[0] == crc_dat[0]) && (crc_rx[1] == crc_dat[1])
        && (crc_rx[2] == crc_dat[2]) && (crc_rx[3] == crc_dat[3]);
  endfunction

  task automatic emit_data_error(input sd_transport_status_t status);
    begin
      data <= '0;
      data_last <= 1'b1;
      data_status <= status;
      data_valid <= 1'b1;
      state <= STATE_ERROR_HOLD;
    end
  endtask

  task automatic begin_post_clocks;
    begin
      post_clock_count <= '0;
      div_count <= '0;
      sd_clk <= 1'b0;
      state <= STATE_POST_LOW;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_POWER_LOW;
      active_clk_div <= clk_div;
      div_count <= '0;
      cmd_frame <= '1;
      cmd_bit_index <= '0;
      active_cmd_index <= '0;
      active_resp_type <= SD_RESP_NONE;
      active_data_read <= 1'b0;
      active_block_len <= '0;
      active_block_count <= '0;
      rsp_bit_count <= '0;
      rsp_shift <= '0;
      timeout_count <= '0;
      power_clock_count <= '0;
      post_clock_count <= '0;
      data_byte_count <= '0;
      data_half <= 1'b0;
      data_high_nibble <= '0;
      for (int line = 0; line < 4; line++) begin
        crc_dat[line] <= '0;
        crc_rx[line] <= '0;
      end
      crc_bit_count <= '0;
      pending_final_data <= '0;
      end_token_ok <= 1'b0;
      data_start_seen <= 1'b0;
      data_start_malformed <= 1'b0;
      power_clocks_done <= 1'b0;
      rsp_valid <= 1'b0;
      rsp_status <= SD_STATUS_OK;
      rsp_data <= '0;
      transaction_done <= 1'b0;
      data_valid <= 1'b0;
      data <= '0;
      data_last <= 1'b0;
      data_status <= SD_STATUS_OK;
      sd_clk <= 1'b0;
      sd_cmd_o <= 1'b1;
      sd_cmd_oe <= 1'b0;
    end else begin
      rsp_valid <= 1'b0;
      transaction_done <= 1'b0;
      if (data_valid && data_ready) begin
        data_valid <= 1'b0;
        data_last <= 1'b0;
      end

      if (state == STATE_DATA_WAIT_LOW || state == STATE_DATA_WAIT_HIGH
          || state == STATE_BUSY_WAIT_LOW || state == STATE_BUSY_WAIT_HIGH)
        timeout_count <= timeout_count + TIMEOUT_WIDTH'(1);

      if (abort_request && state != STATE_IDLE && state != STATE_POWER_LOW && state != STATE_POWER_HIGH) begin
        rsp_status <= SD_STATUS_ABORTED;
        data_valid <= 1'b0;
        sd_cmd_oe <= 1'b0;
        begin_post_clocks();
      end else begin
        unique case (state)
          STATE_POWER_LOW: begin
            sd_cmd_o <= 1'b1;
            sd_cmd_oe <= 1'b0;
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              state <= STATE_POWER_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_POWER_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (power_clock_count == POWER_COUNT_WIDTH'(POWER_UP_CLOCKS - 1)) begin
                power_clocks_done <= 1'b1;
                state <= STATE_IDLE;
              end else begin
                power_clock_count <= power_clock_count + POWER_COUNT_WIDTH'(1);
                state <= STATE_POWER_LOW;
              end
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_IDLE: begin
            sd_clk <= 1'b0;
            sd_cmd_o <= 1'b1;
            sd_cmd_oe <= 1'b0;
            div_count <= '0;
            if (cmd_valid) begin
              active_clk_div <= clk_div;
              active_cmd_index <= cmd_index;
              active_resp_type <= cmd_resp_type;
              active_data_read <= cmd_data_read;
              active_block_len <= cmd_block_len;
              active_block_count <= cmd_block_count == 0 ? 16'd1 : cmd_block_count;
              cmd_frame <= {2'b01, cmd_index, cmd_arg, crc7_command(cmd_index, cmd_arg), 1'b1};
              cmd_bit_index <= 6'd47;
              sd_cmd_o <= 1'b0;
              sd_cmd_oe <= 1'b1;
              state <= STATE_CMD_LOW;
            end
          end

          STATE_CMD_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              state <= STATE_CMD_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_CMD_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (cmd_bit_index == 0) begin
                sd_cmd_oe <= 1'b0;
                timeout_count <= '0;
                rsp_shift <= '0;
                rsp_bit_count <= '0;
                if (active_resp_type == SD_RESP_NONE) begin
                  rsp_status <= SD_STATUS_OK;
                  rsp_data <= '0;
                  rsp_valid <= 1'b1;
                  if (active_data_read)
                    state <= STATE_RESP_DECISION;
                  else
                    begin_post_clocks();
                end else begin
                  state <= STATE_RESP_WAIT_LOW;
                end
              end else begin
                cmd_bit_index <= cmd_bit_index - 6'd1;
                sd_cmd_o <= cmd_frame[cmd_bit_index - 6'd1];
                state <= STATE_CMD_LOW;
              end
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_RESP_WAIT_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              if (!sd_cmd_i) begin
                rsp_shift <= '0;
                rsp_bit_count <= 8'd1;
              end
              state <= STATE_RESP_WAIT_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_RESP_WAIT_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (rsp_bit_count != 0) begin
                state <= STATE_RESP_CAPTURE_LOW;
              end else if (timeout_count == TIMEOUT_WIDTH'(RESPONSE_TIMEOUT_CYCLES - 1)) begin
                rsp_status <= SD_STATUS_TIMEOUT;
                rsp_data <= '0;
                rsp_valid <= 1'b1;
                if (active_data_read)
                  state <= STATE_RESP_DECISION;
                else
                  begin_post_clocks();
              end else begin
                timeout_count <= timeout_count + TIMEOUT_WIDTH'(1);
                state <= STATE_RESP_WAIT_LOW;
              end
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_RESP_CAPTURE_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              rsp_shift <= {rsp_shift[134:0], sd_cmd_i};
              rsp_bit_count <= rsp_bit_count + 8'd1;
              state <= STATE_RESP_CAPTURE_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_RESP_CAPTURE_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (rsp_bit_count == response_bits) begin
                rsp_status <= active_resp_type == SD_RESP_R2
                    ? classify_long_response(rsp_shift)
                    : classify_short_response(rsp_shift[47:0], active_cmd_index, active_resp_type);
                rsp_data <= active_resp_type == SD_RESP_R2
                    ? rsp_shift[127:8] : {88'd0, rsp_shift[39:8]};
                if (active_resp_type == SD_RESP_R1B
                    && classify_short_response(rsp_shift[47:0], active_cmd_index,
                                               active_resp_type) == SD_STATUS_OK) begin
                  timeout_count <= '0;
                  state <= STATE_BUSY_WAIT_LOW;
                end else begin
                  rsp_valid <= 1'b1;
                  if (active_data_read)
                    state <= STATE_RESP_DECISION;
                  else
                    begin_post_clocks();
                end
              end else begin
                state <= STATE_RESP_CAPTURE_LOW;
              end
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_BUSY_WAIT_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              state <= STATE_BUSY_WAIT_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_BUSY_WAIT_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (sd_dat_i[0]) begin
                rsp_status <= SD_STATUS_OK;
                rsp_valid <= 1'b1;
                begin_post_clocks();
              end else if (timeout_count >= TIMEOUT_WIDTH'(BUSY_TIMEOUT_CYCLES - 1)) begin
                rsp_status <= SD_STATUS_BUSY_TIMEOUT;
                rsp_valid <= 1'b1;
                begin_post_clocks();
              end else begin
                state <= STATE_BUSY_WAIT_LOW;
              end
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_RESP_DECISION: begin
            if (rsp_data_proceed) begin
              timeout_count <= '0;
              state <= STATE_DATA_WAIT_LOW;
            end else if (rsp_data_cancel) begin
              begin_post_clocks();
            end
          end

          STATE_DATA_WAIT_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              data_start_seen <= sd_dat_i == 4'h0;
              data_start_malformed <= sd_dat_i != 4'h0 && sd_dat_i != 4'hf;
              if (sd_dat_i == 4'h0) begin
                data_byte_count <= '0;
                data_half <= 1'b0;
                for (int line = 0; line < 4; line++) begin
                  crc_dat[line] <= '0;
                  crc_rx[line] <= '0;
                end
                crc_bit_count <= '0;
                end_token_ok <= 1'b0;
                data_status <= SD_STATUS_OK;
              end
              state <= STATE_DATA_WAIT_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_WAIT_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (data_start_seen) begin
                state <= STATE_DATA_CAPTURE_LOW;
              end else if (data_start_malformed) begin
                emit_data_error(SD_STATUS_FRAMING_ERROR);
              end else if (timeout_count >= TIMEOUT_WIDTH'(DATA_TIMEOUT_CYCLES - 1)) begin
                emit_data_error(SD_STATUS_TIMEOUT);
              end else begin
                state <= STATE_DATA_WAIT_LOW;
              end
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_CAPTURE_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              for (int line = 0; line < 4; line++)
                crc_dat[line] <= crc16_next(crc_dat[line], sd_dat_i[line]);
              if (!data_half) begin
                data_high_nibble <= sd_dat_i;
                data_half <= 1'b1;
              end else begin
                if (data_byte_count == active_block_len - 16'd1)
                  pending_final_data <= {data_high_nibble, sd_dat_i};
                else begin
                  data <= {data_high_nibble, sd_dat_i};
                  data_status <= SD_STATUS_OK;
                  data_last <= 1'b0;
                  data_valid <= 1'b1;
                end
                data_half <= 1'b0;
                data_byte_count <= data_byte_count + 16'd1;
              end
              state <= STATE_DATA_CAPTURE_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_CAPTURE_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (data_valid && !data_ready)
                state <= STATE_DATA_HOLD;
              else if (data_byte_count == active_block_len && !data_valid) begin
                crc_bit_count <= '0;
                state <= STATE_DATA_CRC_LOW;
              end else
                state <= STATE_DATA_CAPTURE_LOW;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_HOLD: begin
            if (!data_valid)
              state <= data_byte_count == active_block_len
                  ? STATE_DATA_CRC_LOW : STATE_DATA_CAPTURE_LOW;
          end

          STATE_DATA_CRC_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              for (int line = 0; line < 4; line++)
                crc_rx[line] <= {crc_rx[line][14:0], sd_dat_i[line]};
              crc_bit_count <= crc_bit_count + 5'd1;
              state <= STATE_DATA_CRC_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_CRC_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              state <= crc_bit_count == 5'd16 ? STATE_DATA_END_LOW : STATE_DATA_CRC_LOW;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_END_LOW: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              end_token_ok <= sd_dat_i == 4'hf;
              state <= STATE_DATA_END_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_END_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              state <= STATE_DATA_EMIT_FINAL;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DATA_EMIT_FINAL: begin
            if (!data_valid) begin
              data <= pending_final_data;
              data_status <= !end_token_ok ? SD_STATUS_FRAMING_ERROR
                  : data_crc_matches() ? SD_STATUS_OK : SD_STATUS_CRC_ERROR;
              // data_last marks each CRC-checked physical block boundary. The
              // command descriptor's block count still controls transaction_done.
              data_last <= 1'b1;
              data_valid <= 1'b1;
              state <= STATE_DATA_FINAL_HOLD;
            end
          end

          STATE_DATA_FINAL_HOLD: begin
            if (data_valid && data_ready) begin
              if (data_status != SD_STATUS_OK) begin
                begin_post_clocks();
              end else if (active_block_count > 16'd1) begin
                active_block_count <= active_block_count - 16'd1;
                timeout_count <= '0;
                state <= STATE_DATA_WAIT_LOW;
              end else begin
                begin_post_clocks();
              end
            end
          end

          STATE_ERROR_HOLD: begin
            if (data_valid && data_ready)
              begin_post_clocks();
          end

          STATE_POST_LOW: begin
            sd_cmd_o <= 1'b1;
            sd_cmd_oe <= 1'b0;
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b1;
              state <= STATE_POST_HIGH;
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_POST_HIGH: begin
            if (half_tick) begin
              div_count <= '0;
              sd_clk <= 1'b0;
              if (post_clock_count == POST_COUNT_WIDTH'(POST_TRANSACTION_CLOCKS - 1)) begin
                post_clock_count <= '0;
                state <= STATE_DONE;
              end else begin
                post_clock_count <= post_clock_count + POST_COUNT_WIDTH'(1);
                state <= STATE_POST_LOW;
              end
            end else begin
              div_count <= div_count + DIV_WIDTH'(1);
            end
          end

          STATE_DONE: begin
            transaction_done <= 1'b1;
            state <= STATE_IDLE;
          end

          default: state <= STATE_POWER_LOW;
        endcase
      end
    end
  end
endmodule
