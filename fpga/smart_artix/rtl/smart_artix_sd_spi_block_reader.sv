module smart_artix_sd_spi_block_reader #(
  parameter int LBA_WIDTH = 32,
  parameter int POWER_UP_DUMMY_BYTES = 10,
  parameter int R1_TIMEOUT_BYTES = 64,
  parameter int INIT_RETRY_LIMIT = 16,
  parameter int DATA_TOKEN_TIMEOUT_BYTES = 2048
) (
  input  logic                clk,
  input  logic                rst,

  input  logic                init_start,
  output logic                initialized,
  output logic                busy,
  output logic [7:0]          error_code,

  input  logic                block_req_valid,
  output logic                block_req_ready,
  input  logic [LBA_WIDTH-1:0] block_req_lba,

  output logic                block_byte_valid,
  input  logic                block_byte_ready,
  output logic [7:0]          block_byte_data,
  output logic                block_byte_last,

  output logic                spi_cs_n,
  output logic                spi_tx_valid,
  input  logic                spi_tx_ready,
  output logic [7:0]          spi_tx_data,
  input  logic                spi_rx_valid,
  input  logic [7:0]          spi_rx_data
);
  localparam logic [7:0] ERROR_NONE = 8'd0;
  localparam logic [7:0] ERROR_R1_TIMEOUT = 8'd1;
  localparam logic [7:0] ERROR_CMD0 = 8'd2;
  localparam logic [7:0] ERROR_CMD8 = 8'd3;
  localparam logic [7:0] ERROR_INIT_RETRY = 8'd4;
  localparam logic [7:0] ERROR_CMD58 = 8'd5;
  localparam logic [7:0] ERROR_NOT_SDHC = 8'd6;
  localparam logic [7:0] ERROR_CMD17 = 8'd7;
  localparam logic [7:0] ERROR_DATA_TOKEN = 8'd8;

  localparam logic [5:0] CMD0 = 6'd0;
  localparam logic [5:0] CMD8 = 6'd8;
  localparam logic [5:0] CMD17 = 6'd17;
  localparam logic [5:0] CMD55 = 6'd55;
  localparam logic [5:0] CMD58 = 6'd58;
  localparam logic [5:0] ACMD41 = 6'd41;

  typedef enum logic [4:0] {
    STATE_IDLE,
    STATE_POWER_CLOCKS,
    STATE_SEND_CMD,
    STATE_WAIT_R1,
    STATE_CMD8_EXTRA,
    STATE_CMD58_EXTRA,
    STATE_READ_WAIT_TOKEN,
    STATE_READ_DATA,
    STATE_READ_CRC,
    STATE_ERROR
  } state_t;

  typedef enum logic [2:0] {
    OP_NONE,
    OP_CMD0,
    OP_CMD8,
    OP_CMD55_INIT,
    OP_ACMD41,
    OP_CMD58,
    OP_CMD17
  } op_t;

  state_t state;
  op_t op;
  logic awaiting_rx;
  logic [5:0] cmd;
  logic [31:0] cmd_arg;
  logic [7:0] cmd_crc;
  logic [2:0] cmd_index;
  logic [7:0] r1_count;
  logic [7:0] extra_index;
  logic [23:0] extra_shift;
  logic [31:0] extra_next;
  logic [15:0] dummy_count;
  logic [7:0] init_retry_count;
  logic [15:0] token_count;
  logic [8:0] data_count;
  logic [1:0] crc_count;
  logic state_sends_byte;
  logic tx_fire;
  logic rx_fire;

  assign busy = state != STATE_IDLE;
  assign block_req_ready = initialized && (state == STATE_IDLE);
  assign spi_cs_n = state == STATE_IDLE || state == STATE_POWER_CLOCKS;
  assign tx_fire = spi_tx_valid && spi_tx_ready;
  assign rx_fire = awaiting_rx && spi_rx_valid;
  assign extra_next = {extra_shift, spi_rx_data};

  always_comb begin
    state_sends_byte = 1'b0;
    spi_tx_data = 8'hff;

    unique case (state)
      STATE_POWER_CLOCKS: begin
        state_sends_byte = 1'b1;
        spi_tx_data = 8'hff;
      end

      STATE_SEND_CMD: begin
        state_sends_byte = 1'b1;
        unique case (cmd_index)
          3'd0: spi_tx_data = {2'b01, cmd};
          3'd1: spi_tx_data = cmd_arg[31:24];
          3'd2: spi_tx_data = cmd_arg[23:16];
          3'd3: spi_tx_data = cmd_arg[15:8];
          3'd4: spi_tx_data = cmd_arg[7:0];
          default: spi_tx_data = cmd_crc;
        endcase
      end

      STATE_WAIT_R1,
      STATE_CMD8_EXTRA,
      STATE_CMD58_EXTRA,
      STATE_READ_WAIT_TOKEN,
      STATE_READ_DATA,
      STATE_READ_CRC: begin
        state_sends_byte = !(state == STATE_READ_DATA && block_byte_valid && !block_byte_ready);
        spi_tx_data = 8'hff;
      end

      default: begin
        state_sends_byte = 1'b0;
        spi_tx_data = 8'hff;
      end
    endcase
  end

  assign spi_tx_valid = state_sends_byte && !awaiting_rx;

  task automatic start_command(input logic [5:0] next_cmd,
                               input logic [31:0] next_arg,
                               input logic [7:0] next_crc,
                               input op_t next_op);
    begin
      cmd <= next_cmd;
      cmd_arg <= next_arg;
      cmd_crc <= next_crc;
      op <= next_op;
      cmd_index <= 3'd0;
      r1_count <= '0;
      state <= STATE_SEND_CMD;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      op <= OP_NONE;
      awaiting_rx <= 1'b0;
      initialized <= 1'b0;
      error_code <= ERROR_NONE;
      cmd <= '0;
      cmd_arg <= '0;
      cmd_crc <= '0;
      cmd_index <= '0;
      r1_count <= '0;
      extra_index <= '0;
      extra_shift <= '0;
      dummy_count <= '0;
      init_retry_count <= '0;
      token_count <= '0;
      data_count <= '0;
      crc_count <= '0;
      block_byte_valid <= 1'b0;
      block_byte_data <= '0;
      block_byte_last <= 1'b0;
    end else begin
      if (block_byte_valid && block_byte_ready) begin
        block_byte_valid <= 1'b0;
        block_byte_last <= 1'b0;
      end

      if (tx_fire)
        awaiting_rx <= 1'b1;

      if (rx_fire) begin
        awaiting_rx <= 1'b0;

        unique case (state)
          STATE_POWER_CLOCKS: begin
            if (dummy_count == 16'(POWER_UP_DUMMY_BYTES - 1)) begin
              dummy_count <= '0;
              start_command(CMD0, 32'h0000_0000, 8'h95, OP_CMD0);
            end else begin
              dummy_count <= dummy_count + 16'd1;
            end
          end

          STATE_SEND_CMD: begin
            if (cmd_index == 3'd5) begin
              cmd_index <= '0;
              r1_count <= '0;
              state <= STATE_WAIT_R1;
            end else begin
              cmd_index <= cmd_index + 3'd1;
            end
          end

          STATE_WAIT_R1: begin
            if (spi_rx_data == 8'hff) begin
              if (r1_count == 8'(R1_TIMEOUT_BYTES - 1)) begin
                error_code <= ERROR_R1_TIMEOUT;
                state <= STATE_ERROR;
              end else begin
                r1_count <= r1_count + 8'd1;
              end
            end else begin
              unique case (op)
                OP_CMD0: begin
                  if (spi_rx_data == 8'h01)
                    start_command(CMD8, 32'h0000_01aa, 8'h87, OP_CMD8);
                  else begin
                    error_code <= ERROR_CMD0;
                    state <= STATE_ERROR;
                  end
                end

                OP_CMD8: begin
                  if (spi_rx_data == 8'h01) begin
                    extra_index <= '0;
                    extra_shift <= '0;
                    state <= STATE_CMD8_EXTRA;
                  end else begin
                    error_code <= ERROR_CMD8;
                    state <= STATE_ERROR;
                  end
                end

                OP_CMD55_INIT: begin
                  if (spi_rx_data == 8'h01 || spi_rx_data == 8'h00)
                    start_command(ACMD41, 32'h4000_0000, 8'hff, OP_ACMD41);
                  else begin
                    error_code <= ERROR_INIT_RETRY;
                    state <= STATE_ERROR;
                  end
                end

                OP_ACMD41: begin
                  if (spi_rx_data == 8'h00)
                    start_command(CMD58, 32'h0000_0000, 8'hff, OP_CMD58);
                  else if (spi_rx_data == 8'h01 && init_retry_count != 8'(INIT_RETRY_LIMIT - 1)) begin
                    init_retry_count <= init_retry_count + 8'd1;
                    start_command(CMD55, 32'h0000_0000, 8'hff, OP_CMD55_INIT);
                  end else begin
                    error_code <= ERROR_INIT_RETRY;
                    state <= STATE_ERROR;
                  end
                end

                OP_CMD58: begin
                  if (spi_rx_data == 8'h00) begin
                    extra_index <= '0;
                    extra_shift <= '0;
                    state <= STATE_CMD58_EXTRA;
                  end else begin
                    error_code <= ERROR_CMD58;
                    state <= STATE_ERROR;
                  end
                end

                OP_CMD17: begin
                  if (spi_rx_data == 8'h00) begin
                    token_count <= '0;
                    state <= STATE_READ_WAIT_TOKEN;
                  end else begin
                    error_code <= ERROR_CMD17;
                    state <= STATE_ERROR;
                  end
                end

                default: begin
                  error_code <= ERROR_R1_TIMEOUT;
                  state <= STATE_ERROR;
                end
              endcase
            end
          end

          STATE_CMD8_EXTRA: begin
            extra_shift <= extra_next[23:0];
            if (extra_index == 8'd3) begin
              if (extra_next == 32'h0000_01aa)
                start_command(CMD55, 32'h0000_0000, 8'hff, OP_CMD55_INIT);
              else begin
                error_code <= ERROR_CMD8;
                state <= STATE_ERROR;
              end
            end else begin
              extra_index <= extra_index + 8'd1;
            end
          end

          STATE_CMD58_EXTRA: begin
            extra_shift <= extra_next[23:0];
            if (extra_index == 8'd3) begin
              if (extra_next[30]) begin
                initialized <= 1'b1;
                error_code <= ERROR_NONE;
                state <= STATE_IDLE;
              end else begin
                error_code <= ERROR_NOT_SDHC;
                state <= STATE_ERROR;
              end
            end else begin
              extra_index <= extra_index + 8'd1;
            end
          end

          STATE_READ_WAIT_TOKEN: begin
            if (spi_rx_data == 8'hfe) begin
              data_count <= '0;
              state <= STATE_READ_DATA;
            end else if (token_count == 16'(DATA_TOKEN_TIMEOUT_BYTES - 1)) begin
              error_code <= ERROR_DATA_TOKEN;
              state <= STATE_ERROR;
            end else begin
              token_count <= token_count + 16'd1;
            end
          end

          STATE_READ_DATA: begin
            block_byte_data <= spi_rx_data;
            block_byte_valid <= 1'b1;
            block_byte_last <= data_count == 9'd511;
            if (data_count == 9'd511) begin
              crc_count <= '0;
              state <= STATE_READ_CRC;
            end else begin
              data_count <= data_count + 9'd1;
            end
          end

          STATE_READ_CRC: begin
            if (crc_count == 2'd1)
              state <= STATE_IDLE;
            else
              crc_count <= crc_count + 2'd1;
          end

          default: ;
        endcase
      end

      if (!awaiting_rx && !tx_fire) begin
        unique case (state)
          STATE_IDLE: begin
            if (init_start && !initialized) begin
              error_code <= ERROR_NONE;
              dummy_count <= '0;
              init_retry_count <= '0;
              state <= STATE_POWER_CLOCKS;
            end else if (block_req_valid && block_req_ready) begin
              start_command(CMD17, 32'(block_req_lba), 8'hff, OP_CMD17);
            end
          end

          default: ;
        endcase
      end
    end
  end
endmodule
