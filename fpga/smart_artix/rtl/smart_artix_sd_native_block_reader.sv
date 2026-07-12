module smart_artix_sd_native_block_reader #(
  parameter int LBA_WIDTH = 32,
  parameter int INIT_RETRY_LIMIT = 1024
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

  output logic                phy_cmd_valid,
  input  logic                phy_cmd_ready,
  output logic [5:0]          phy_cmd_index,
  output logic [31:0]         phy_cmd_arg,
  output logic [1:0]          phy_cmd_resp_type,
  output logic                phy_cmd_data_read,
  output logic [15:0]         phy_cmd_block_len,
  output logic [15:0]         phy_cmd_block_count,
  input  logic                phy_rsp_valid,
  input  logic [2:0]          phy_rsp_status,
  input  logic [119:0]        phy_rsp_data,

  input  logic                phy_data_valid,
  output logic                phy_data_ready,
  input  logic [7:0]          phy_data,
  input  logic                phy_data_last,
  input  logic [2:0]          phy_data_status
);
  localparam logic [1:0] RESP_NONE = 2'd0;
  localparam logic [1:0] RESP_SHORT = 2'd1;
  localparam logic [1:0] RESP_LONG = 2'd2;

  localparam logic [2:0] STATUS_OK = 3'd0;

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

  localparam logic [5:0] CMD0 = 6'd0;
  localparam logic [5:0] CMD2 = 6'd2;
  localparam logic [5:0] CMD3 = 6'd3;
  localparam logic [5:0] CMD7 = 6'd7;
  localparam logic [5:0] CMD8 = 6'd8;
  localparam logic [5:0] CMD17 = 6'd17;
  localparam logic [5:0] CMD55 = 6'd55;
  localparam logic [5:0] ACMD6 = 6'd6;
  localparam logic [5:0] ACMD41 = 6'd41;

  typedef enum logic [4:0] {
    STATE_IDLE,
    STATE_SEND,
    STATE_WAIT_RSP,
    STATE_READ_DATA,
    STATE_ERROR
  } state_t;

  typedef enum logic [3:0] {
    OP_NONE,
    OP_CMD0,
    OP_CMD8,
    OP_CMD55_IDLE,
    OP_ACMD41,
    OP_CMD2,
    OP_CMD3,
    OP_CMD7,
    OP_CMD55_4BIT,
    OP_ACMD6,
    OP_CMD17
  } op_t;

  state_t state;
  op_t op;
  logic [5:0] pending_cmd_index;
  logic [31:0] pending_cmd_arg;
  logic [1:0] pending_resp_type;
  logic pending_data_read;
  logic [15:0] init_retry_count;
  logic [15:0] rca;
  logic [8:0] data_count;
  logic cmd_accept;
  logic data_accept;
  logic unused_rsp_bits;

  assign busy = state != STATE_IDLE;
  assign block_req_ready = initialized && (state == STATE_IDLE);
  assign cmd_accept = phy_cmd_valid && phy_cmd_ready;
  assign data_accept = phy_data_valid && phy_data_ready;
  assign unused_rsp_bits = (^phy_rsp_data[119:32]) ^ (^phy_rsp_data[15:12]);

  assign phy_cmd_valid = state == STATE_SEND;
  assign phy_cmd_index = pending_cmd_index;
  assign phy_cmd_arg = pending_cmd_arg;
  assign phy_cmd_resp_type = pending_resp_type;
  assign phy_cmd_data_read = pending_data_read;
  assign phy_cmd_block_len = 16'd512;
  assign phy_cmd_block_count = pending_data_read ? 16'd1 : 16'd0;
  assign phy_data_ready = (state == STATE_READ_DATA) && (!block_byte_valid || block_byte_ready);

  task automatic start_command(input logic [5:0] cmd_index,
                               input logic [31:0] cmd_arg,
                               input logic [1:0] resp_type,
                               input logic data_read,
                               input op_t next_op);
    begin
      pending_cmd_index <= cmd_index;
      pending_cmd_arg <= cmd_arg;
      pending_resp_type <= resp_type;
      pending_data_read <= data_read;
      op <= next_op;
      state <= STATE_SEND;
    end
  endtask

  task automatic fail(input logic [7:0] code);
    begin
      error_code <= code;
      initialized <= 1'b0;
      state <= STATE_ERROR;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      op <= OP_NONE;
      initialized <= 1'b0;
      error_code <= ERROR_NONE;
      pending_cmd_index <= '0;
      pending_cmd_arg <= '0;
      pending_resp_type <= RESP_NONE;
      pending_data_read <= 1'b0;
      init_retry_count <= '0;
      rca <= '0;
      data_count <= '0;
      block_byte_valid <= 1'b0;
      block_byte_data <= '0;
      block_byte_last <= 1'b0;
    end else begin
      if (block_byte_valid && block_byte_ready) begin
        block_byte_valid <= 1'b0;
        block_byte_last <= 1'b0;
      end

      unique case (state)
        STATE_IDLE: begin
          if (init_start && !initialized) begin
            error_code <= ERROR_NONE;
            init_retry_count <= '0;
            start_command(CMD0, 32'h0000_0000, RESP_NONE, 1'b0, OP_CMD0);
          end else if (block_req_valid && block_req_ready) begin
            start_command(CMD17, 32'(block_req_lba), RESP_SHORT, 1'b1, OP_CMD17);
          end
        end

        STATE_SEND: begin
          if (cmd_accept) begin
            if (pending_resp_type == RESP_NONE) begin
              if (op == OP_CMD0)
                start_command(CMD8, 32'h0000_01aa, RESP_SHORT, 1'b0, OP_CMD8);
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
                if (phy_rsp_status == STATUS_OK && phy_rsp_data[11:0] == 12'h1aa)
                  start_command(CMD55, 32'h0000_0000, RESP_SHORT, 1'b0, OP_CMD55_IDLE);
                else
                  fail(ERROR_CMD8);
              end

              OP_CMD55_IDLE: begin
                if (phy_rsp_status == STATUS_OK)
                  start_command(ACMD41, 32'h4030_0000, RESP_SHORT, 1'b0, OP_ACMD41);
                else
                  fail(ERROR_ACMD41);
              end

              OP_ACMD41: begin
                if (phy_rsp_status != STATUS_OK) begin
                  fail(ERROR_ACMD41);
                end else if (phy_rsp_data[31]) begin
                  if (phy_rsp_data[30])
                    start_command(CMD2, 32'h0000_0000, RESP_LONG, 1'b0, OP_CMD2);
                  else
                    fail(ERROR_NOT_SDHC);
                end else if (init_retry_count != 16'(INIT_RETRY_LIMIT - 1)) begin
                  init_retry_count <= init_retry_count + 16'd1;
                  start_command(CMD55, 32'h0000_0000, RESP_SHORT, 1'b0, OP_CMD55_IDLE);
                end else begin
                  fail(ERROR_ACMD41);
                end
              end

              OP_CMD2: begin
                if (phy_rsp_status == STATUS_OK)
                  start_command(CMD3, 32'h0000_0000, RESP_SHORT, 1'b0, OP_CMD3);
                else
                  fail(ERROR_CMD2);
              end

              OP_CMD3: begin
                if (phy_rsp_status == STATUS_OK) begin
                  rca <= phy_rsp_data[31:16];
                  start_command(CMD7, {phy_rsp_data[31:16], 16'h0000}, RESP_SHORT, 1'b0, OP_CMD7);
                end else begin
                  fail(ERROR_CMD3);
                end
              end

              OP_CMD7: begin
                if (phy_rsp_status == STATUS_OK)
                  start_command(CMD55, {rca, 16'h0000}, RESP_SHORT, 1'b0, OP_CMD55_4BIT);
                else
                  fail(ERROR_CMD7);
              end

              OP_CMD55_4BIT: begin
                if (phy_rsp_status == STATUS_OK)
                  start_command(ACMD6, 32'h0000_0002, RESP_SHORT, 1'b0, OP_ACMD6);
                else
                  fail(ERROR_ACMD6);
              end

              OP_ACMD6: begin
                if (phy_rsp_status == STATUS_OK) begin
                  initialized <= 1'b1;
                  error_code <= ERROR_NONE;
                  state <= STATE_IDLE;
                end else begin
                  fail(ERROR_ACMD6);
                end
              end

              OP_CMD17: begin
                if (phy_rsp_status == STATUS_OK) begin
                  data_count <= '0;
                  state <= STATE_READ_DATA;
                end else begin
                  fail(ERROR_CMD17);
                end
              end

              default: fail(ERROR_CMD17);
            endcase
          end
        end

        STATE_READ_DATA: begin
          if (data_accept) begin
            if (phy_data_status != STATUS_OK) begin
              fail(ERROR_DATA);
            end else begin
              block_byte_data <= phy_data;
              block_byte_valid <= 1'b1;
              block_byte_last <= phy_data_last || data_count == 9'd511;
              if (phy_data_last || data_count == 9'd511)
                state <= STATE_IDLE;
              else
                data_count <= data_count + 9'd1;
            end
          end
        end

        STATE_ERROR: begin
          if (init_start) begin
            error_code <= ERROR_NONE;
            init_retry_count <= '0;
            start_command(CMD0, 32'h0000_0000, RESP_NONE, 1'b0, OP_CMD0);
          end
        end

        default: state <= STATE_ERROR;
      endcase
    end
  end
endmodule
