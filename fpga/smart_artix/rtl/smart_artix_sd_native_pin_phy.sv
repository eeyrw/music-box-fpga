module smart_artix_sd_native_pin_phy #(
  parameter int DIV_WIDTH = 16,
  parameter int RESPONSE_TIMEOUT_CYCLES = 4096,
  parameter int DATA_TIMEOUT_CYCLES = 65535
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic [DIV_WIDTH-1:0] clk_div,

  input  logic                 cmd_valid,
  output logic                 cmd_ready,
  input  logic [5:0]           cmd_index,
  input  logic [31:0]          cmd_arg,
  input  logic [1:0]           cmd_resp_type,
  input  logic                 cmd_data_read,
  input  logic [15:0]          cmd_block_len,
  input  logic [15:0]          cmd_block_count,

  output logic                 rsp_valid,
  output logic [2:0]           rsp_status,
  output logic [119:0]         rsp_data,

  output logic                 data_valid,
  input  logic                 data_ready,
  output logic [7:0]           data,
  output logic                 data_last,
  output logic [2:0]           data_status,

  output logic                 sd_clk,
  output logic                 sd_cmd_o,
  output logic                 sd_cmd_oe,
  input  logic                 sd_cmd_i,
  input  logic [3:0]           sd_dat_i
);
  localparam logic [1:0] RESP_NONE = 2'd0;
  localparam logic [1:0] RESP_LONG = 2'd2;

  localparam logic [2:0] STATUS_OK = 3'd0;
  localparam logic [2:0] STATUS_TIMEOUT = 3'd1;
  localparam logic [2:0] STATUS_CRC_ERROR = 3'd2;

  typedef enum logic [3:0] {
    STATE_IDLE,
    STATE_CMD_LOW,
    STATE_CMD_HIGH,
    STATE_RESP_WAIT,
    STATE_RESP_LOW,
    STATE_RESP_HIGH,
    STATE_DATA_WAIT,
    STATE_DATA_LOW,
    STATE_DATA_HIGH,
    STATE_DATA_HOLD,
    STATE_DATA_CRC_LOW,
    STATE_DATA_CRC_HIGH,
    STATE_DATA_EMIT_FINAL,
    STATE_DATA_FINAL_HOLD,
    STATE_DONE
  } state_t;

  state_t state;
  logic [DIV_WIDTH-1:0] div_count;
  logic [47:0] cmd_frame;
  logic [5:0] cmd_bit_index;
  logic [7:0] rsp_bit_count;
  logic [135:0] rsp_shift;
  logic [15:0] data_byte_count;
  logic data_half;
  logic [3:0] data_high_nibble;
  logic [15:0] timeout_count;
  logic [15:0] crc_skip_count;
  logic [15:0] crc_dat0;
  logic [15:0] crc_dat1;
  logic [15:0] crc_dat2;
  logic [15:0] crc_dat3;
  logic [15:0] crc_rx0;
  logic [15:0] crc_rx1;
  logic [15:0] crc_rx2;
  logic [15:0] crc_rx3;
  logic [4:0] crc_bit_count;
  logic [7:0] pending_final_data;
  logic crc_match;
  logic half_tick;
  logic command_done;
  logic response_done;
  logic data_done;
  logic [7:0] response_bits;
  logic unused_rsp_shift_msb;

  assign cmd_ready = state == STATE_IDLE;
  assign half_tick = div_count == clk_div;
  assign response_bits = (cmd_resp_type == RESP_LONG) ? 8'd136 : 8'd48;
  assign unused_rsp_shift_msb = rsp_shift[135];
  assign crc_match = (crc_rx0 == crc_dat0) && (crc_rx1 == crc_dat1)
      && (crc_rx2 == crc_dat2) && (crc_rx3 == crc_dat3);

  function automatic logic [6:0] crc7_next(input logic [6:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[6];
      crc7_next = {crc[5:3], crc[2] ^ feedback, crc[1:0], feedback};
    end
  endfunction

  function automatic logic [6:0] crc7_payload(input logic [39:0] payload);
    logic [6:0] crc;
    begin
      crc = 7'd0;
      for (int i = 39; i >= 0; i--)
        crc = crc7_next(crc, payload[i]);
      crc7_payload = crc;
    end
  endfunction

  function automatic logic [6:0] crc7_command(input logic [5:0] index, input logic [31:0] arg);
    begin
      crc7_command = crc7_payload({2'b01, index, arg});
    end
  endfunction

  function automatic logic response_crc_ok(input logic [47:0] response, input logic [5:0] index);
    begin
      // R3 responses do not include a CRC7 field; native ACMD41 is the only R3 user here.
      response_crc_ok = (response[47:46] == 2'b00) && response[0]
          && ((index == 6'd41) || (crc7_payload(response[47:8]) == response[7:1]));
    end
  endfunction

  function automatic logic [15:0] crc16_next(input logic [15:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[15];
      crc16_next = {crc[14:12], crc[11] ^ feedback, crc[10:5], crc[4] ^ feedback, crc[3:0], feedback};
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      div_count <= '0;
      cmd_frame <= '1;
      cmd_bit_index <= '0;
      rsp_bit_count <= '0;
      rsp_shift <= '0;
      rsp_valid <= 1'b0;
      rsp_status <= STATUS_OK;
      rsp_data <= '0;
      data_byte_count <= '0;
      data_half <= 1'b0;
      data_high_nibble <= '0;
      data_valid <= 1'b0;
      data <= '0;
      data_last <= 1'b0;
      data_status <= STATUS_OK;
      timeout_count <= '0;
      crc_skip_count <= '0;
      crc_dat0 <= '0;
      crc_dat1 <= '0;
      crc_dat2 <= '0;
      crc_dat3 <= '0;
      crc_rx0 <= '0;
      crc_rx1 <= '0;
      crc_rx2 <= '0;
      crc_rx3 <= '0;
      crc_bit_count <= '0;
      pending_final_data <= '0;
      sd_clk <= 1'b0;
      sd_cmd_o <= 1'b1;
      sd_cmd_oe <= 1'b0;
    end else begin
      rsp_valid <= 1'b0;
      if (data_valid && data_ready) begin
        data_valid <= 1'b0;
        data_last <= 1'b0;
      end

      unique case (state)
        STATE_IDLE: begin
          sd_clk <= 1'b0;
          div_count <= '0;
          sd_cmd_o <= 1'b1;
          sd_cmd_oe <= 1'b0;
          if (cmd_valid) begin
            cmd_frame <= {2'b01, cmd_index, cmd_arg, crc7_command(cmd_index, cmd_arg), 1'b1};
            cmd_bit_index <= 6'd47;
            sd_cmd_o <= 1'b0;
            sd_cmd_oe <= 1'b1;
            state <= STATE_CMD_LOW;
          end
        end

        STATE_CMD_LOW: begin
          sd_cmd_o <= cmd_frame[cmd_bit_index];
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
            if (cmd_bit_index == 6'd0) begin
              sd_cmd_oe <= 1'b0;
              timeout_count <= '0;
              rsp_shift <= '0;
              rsp_bit_count <= '0;
              if (cmd_resp_type == RESP_NONE) begin
                rsp_status <= STATUS_OK;
                rsp_data <= '0;
                rsp_valid <= 1'b1;
                state <= cmd_data_read ? STATE_DATA_WAIT : STATE_DONE;
              end else begin
                state <= STATE_RESP_WAIT;
              end
            end else begin
              cmd_bit_index <= cmd_bit_index - 6'd1;
              state <= STATE_CMD_LOW;
            end
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_RESP_WAIT: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b1;
            if (sd_cmd_i == 1'b0) begin
              rsp_shift <= 136'(1'b0);
              rsp_bit_count <= 8'd1;
              state <= STATE_RESP_HIGH;
            end else if (timeout_count == 16'(RESPONSE_TIMEOUT_CYCLES - 1)) begin
              rsp_status <= STATUS_TIMEOUT;
              rsp_data <= '0;
              rsp_valid <= 1'b1;
              state <= STATE_DONE;
            end else begin
              timeout_count <= timeout_count + 16'd1;
              state <= STATE_RESP_HIGH;
            end
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_RESP_LOW: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b1;
            rsp_shift <= {rsp_shift[134:0], sd_cmd_i};
            rsp_bit_count <= rsp_bit_count + 8'd1;
            state <= STATE_RESP_HIGH;
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_RESP_HIGH: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b0;
            if (rsp_bit_count == response_bits) begin
              rsp_status <= (cmd_resp_type == RESP_LONG || response_crc_ok(rsp_shift[47:0], cmd_index))
                  ? STATUS_OK : STATUS_CRC_ERROR;
              rsp_data <= (cmd_resp_type == RESP_LONG) ? rsp_shift[120:1] : {88'd0, rsp_shift[39:8]};
              rsp_valid <= 1'b1;
              state <= cmd_data_read ? STATE_DATA_WAIT : STATE_DONE;
            end else begin
              state <= STATE_RESP_LOW;
            end
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_DATA_WAIT: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b1;
            if (sd_dat_i[0] == 1'b0) begin
              data_byte_count <= '0;
              data_half <= 1'b0;
              crc_dat0 <= '0;
              crc_dat1 <= '0;
              crc_dat2 <= '0;
              crc_dat3 <= '0;
              crc_rx0 <= '0;
              crc_rx1 <= '0;
              crc_rx2 <= '0;
              crc_rx3 <= '0;
              crc_bit_count <= '0;
              state <= STATE_DATA_HIGH;
            end else if (timeout_count == 16'(DATA_TIMEOUT_CYCLES - 1)) begin
              data_status <= STATUS_TIMEOUT;
              data <= '0;
              data_last <= 1'b1;
              data_valid <= 1'b1;
              state <= STATE_DONE;
            end else begin
              timeout_count <= timeout_count + 16'd1;
              state <= STATE_DATA_HIGH;
            end
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_DATA_LOW: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b1;
            if (!data_half) begin
              data_high_nibble <= sd_dat_i;
              crc_dat0 <= crc16_next(crc_dat0, sd_dat_i[0]);
              crc_dat1 <= crc16_next(crc_dat1, sd_dat_i[1]);
              crc_dat2 <= crc16_next(crc_dat2, sd_dat_i[2]);
              crc_dat3 <= crc16_next(crc_dat3, sd_dat_i[3]);
              data_half <= 1'b1;
            end else begin
              crc_dat0 <= crc16_next(crc_dat0, sd_dat_i[0]);
              crc_dat1 <= crc16_next(crc_dat1, sd_dat_i[1]);
              crc_dat2 <= crc16_next(crc_dat2, sd_dat_i[2]);
              crc_dat3 <= crc16_next(crc_dat3, sd_dat_i[3]);
              if (data_byte_count == (cmd_block_len - 16'd1)) begin
                pending_final_data <= {data_high_nibble, sd_dat_i};
              end else begin
                data <= {data_high_nibble, sd_dat_i};
                data_status <= STATUS_OK;
                data_last <= 1'b0;
                data_valid <= 1'b1;
              end
              data_half <= 1'b0;
              data_byte_count <= data_byte_count + 16'd1;
            end
            state <= STATE_DATA_HIGH;
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_DATA_HIGH: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b0;
            if (data_valid && !data_ready) begin
              state <= STATE_DATA_HOLD;
            end else if (data_byte_count == cmd_block_len && !data_valid) begin
              crc_skip_count <= '0;
              crc_bit_count <= '0;
              state <= STATE_DATA_CRC_LOW;
            end else begin
              state <= STATE_DATA_LOW;
            end
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_DATA_HOLD: begin
          if (!data_valid)
            state <= data_byte_count == cmd_block_len ? STATE_DATA_CRC_LOW : STATE_DATA_LOW;
        end

        STATE_DATA_CRC_LOW: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b1;
            crc_rx0 <= {crc_rx0[14:0], sd_dat_i[0]};
            crc_rx1 <= {crc_rx1[14:0], sd_dat_i[1]};
            crc_rx2 <= {crc_rx2[14:0], sd_dat_i[2]};
            crc_rx3 <= {crc_rx3[14:0], sd_dat_i[3]};
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
            state <= (crc_bit_count == 5'd16) ? STATE_DATA_EMIT_FINAL : STATE_DATA_CRC_LOW;
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_DATA_EMIT_FINAL: begin
          if (!data_valid) begin
            data <= pending_final_data;
            data_status <= crc_match ? STATUS_OK : STATUS_CRC_ERROR;
            data_last <= 1'b1;
            data_valid <= 1'b1;
            state <= STATE_DATA_FINAL_HOLD;
          end
        end

        STATE_DATA_FINAL_HOLD: begin
          if (data_valid && data_ready)
            state <= STATE_DONE;
        end

        STATE_DONE: begin
          sd_clk <= 1'b0;
          sd_cmd_oe <= 1'b0;
          state <= STATE_IDLE;
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_inputs;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_inputs = (^cmd_block_count) ^ command_done ^ response_done ^ data_done
      ^ (^crc_skip_count) ^ unused_rsp_shift_msb;
  assign command_done = 1'b0;
  assign response_done = 1'b0;
  assign data_done = 1'b0;
endmodule
