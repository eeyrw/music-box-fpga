module fake_sd_native_phy_model #(
  parameter int DATA_DELAY_CYCLES = 3,
  parameter int INIT_BUSY_RESPONSES = 1
) (
  input  logic         clk,
  input  logic         rst,

  input  logic         cmd_valid,
  output logic         cmd_ready,
  input  logic [5:0]   cmd_index,
  input  logic [31:0]  cmd_arg,
  input  logic [1:0]   cmd_resp_type,
  input  logic         cmd_data_read,
  input  logic [15:0]  cmd_block_len,
  input  logic [15:0]  cmd_block_count,

  output logic         rsp_valid,
  output logic [2:0]   rsp_status,
  output logic [119:0] rsp_data,

  output logic         data_valid,
  input  logic         data_ready,
  output logic [7:0]   data,
  output logic         data_last,
  output logic [2:0]   data_status,

  output logic [7:0]   illegal_command_count,
  output logic [31:0]  last_read_lba,
  output logic         selected,
  output logic         wide_bus
);
  localparam logic [2:0] STATUS_OK = 3'd0;
  localparam logic [2:0] STATUS_TIMEOUT = 3'd1;

  localparam logic [15:0] RCA = 16'h1234;
  localparam logic [31:0] OCR_BUSY_SDHC = 32'hc0ff_8000;
  localparam logic [31:0] OCR_STILL_BUSY = 32'h40ff_8000;
  localparam logic [119:0] CID = 120'h02544d53_41303847_14394a67_c700e4;

  typedef enum logic [2:0] {
    CARD_IDLE,
    CARD_READY,
    CARD_IDENT,
    CARD_STANDBY,
    CARD_TRANSFER
  } card_state_t;

  typedef enum logic [1:0] {
    DATA_IDLE,
    DATA_WAIT,
    DATA_SEND
  } data_state_t;

  card_state_t card_state;
  data_state_t data_state;
  logic app_cmd;
  logic [15:0] data_delay_count;
  logic [15:0] data_byte_index;
  logic [15:0] active_block_len;
  logic [15:0] active_block_index;
  logic [15:0] active_block_count;
  logic [15:0] predeclared_block_count;
  logic [7:0] acmd41_count;
  logic cmd_accept;
  logic unused_cmd_inputs;

  assign cmd_ready = 1'b1;
  assign cmd_accept = cmd_valid && cmd_ready;
  assign unused_cmd_inputs = (^cmd_resp_type) ^ (^cmd_block_count);

  function automatic logic [7:0] sector_byte(input logic [31:0] lba,
                                              input logic [15:0] byte_index);
    logic [63:0] sf2_lba;
    logic [31:0] sf2_size;
    logic [63:0] ddr_base;
    begin
      sf2_lba = 64'd7;
      sf2_size = 32'd20;
      ddr_base = 64'd0;
      sector_byte = 8'd0;
      if (lba == 32'd0) begin
        unique case (byte_index)
          16'h0000: sector_byte = "W";
          16'h0001: sector_byte = "T";
          16'h0002: sector_byte = "S";
          16'h0003: sector_byte = "F";
          16'h0004: sector_byte = 8'd1;
          16'h0010, 16'h0011, 16'h0012, 16'h0013,
          16'h0014, 16'h0015, 16'h0016, 16'h0017:
            sector_byte = sf2_lba[(byte_index - 16'h0010) * 8 +: 8];
          16'h0018, 16'h0019, 16'h001a, 16'h001b:
            sector_byte = sf2_size[(byte_index - 16'h0018) * 8 +: 8];
          16'h0020, 16'h0021, 16'h0022, 16'h0023,
          16'h0024, 16'h0025, 16'h0026, 16'h0027:
            sector_byte = ddr_base[(byte_index - 16'h0020) * 8 +: 8];
          default: sector_byte = 8'd0;
        endcase
      end else begin
        sector_byte = lba[7:0] ^ lba[15:8] ^ lba[23:16] ^ lba[31:24]
            ^ byte_index[7:0] ^ byte_index[15:8];
      end
    end
  endfunction

  task automatic respond_ok(input logic [119:0] value);
    begin
      rsp_status <= STATUS_OK;
      rsp_data <= value;
      rsp_valid <= 1'b1;
    end
  endtask

  task automatic respond_illegal();
    begin
      rsp_status <= STATUS_TIMEOUT;
      rsp_data <= '0;
      rsp_valid <= 1'b1;
      illegal_command_count <= illegal_command_count + 8'd1;
    end
  endtask

  task automatic start_data(input logic [15:0] block_len);
    begin
      active_block_len <= block_len;
      active_block_index <= '0;
      active_block_count <= 16'd1;
      data_byte_index <= '0;
      data_delay_count <= '0;
      data_state <= DATA_WAIT;
    end
  endtask

  task automatic start_multi_data(input logic [15:0] block_len,
                                  input logic [15:0] block_count);
    begin
      active_block_len <= block_len;
      active_block_index <= '0;
      active_block_count <= (block_count == 16'd0) ? 16'd1 : block_count;
      data_byte_index <= '0;
      data_delay_count <= '0;
      data_state <= DATA_WAIT;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      card_state <= CARD_IDLE;
      data_state <= DATA_IDLE;
      app_cmd <= 1'b0;
      wide_bus <= 1'b0;
      selected <= 1'b0;
      acmd41_count <= '0;
      illegal_command_count <= '0;
      last_read_lba <= '0;
      active_block_len <= 16'd512;
      active_block_index <= '0;
      active_block_count <= 16'd1;
      predeclared_block_count <= 16'd0;
      data_delay_count <= '0;
      data_byte_index <= '0;
      rsp_valid <= 1'b0;
      rsp_status <= STATUS_OK;
      rsp_data <= '0;
      data_valid <= 1'b0;
      data <= '0;
      data_last <= 1'b0;
      data_status <= STATUS_OK;
    end else begin
      rsp_valid <= 1'b0;

      if (data_valid && data_ready) begin
        data_valid <= 1'b0;
        data_last <= 1'b0;
      end

      unique case (data_state)
        DATA_IDLE: ;

        DATA_WAIT: begin
          if (data_delay_count == 16'(DATA_DELAY_CYCLES)) begin
            data_state <= DATA_SEND;
          end else begin
            data_delay_count <= data_delay_count + 16'd1;
          end
        end

        DATA_SEND: begin
          if (!data_valid || data_ready) begin
            data <= (active_block_len == 16'd64) ? 8'h5a
                : sector_byte(last_read_lba + 32'(active_block_index), data_byte_index);
            data_status <= STATUS_OK;
            data_last <= (data_byte_index == active_block_len - 16'd1)
                && (active_block_index == active_block_count - 16'd1);
            data_valid <= 1'b1;
            if (data_byte_index == active_block_len - 16'd1) begin
              data_byte_index <= '0;
              if (active_block_index == active_block_count - 16'd1) begin
                data_state <= DATA_IDLE;
              end else begin
                active_block_index <= active_block_index + 16'd1;
                data_delay_count <= '0;
                data_state <= DATA_WAIT;
              end
            end else begin
              data_byte_index <= data_byte_index + 16'd1;
            end
          end
        end

        default: data_state <= DATA_IDLE;
      endcase

      if (cmd_accept) begin
        unique case (cmd_index)
          6'd0: begin
            card_state <= CARD_IDLE;
            selected <= 1'b0;
            wide_bus <= 1'b0;
            app_cmd <= 1'b0;
            acmd41_count <= '0;
            respond_ok('0);
          end

          6'd8: begin
            app_cmd <= 1'b0;
            if (card_state == CARD_IDLE && cmd_arg[11:0] == 12'h1aa)
              respond_ok(120'h0000_01aa);
            else
              respond_illegal();
          end

          6'd55: begin
            app_cmd <= 1'b1;
            if ((card_state == CARD_IDLE && cmd_arg == 32'd0)
                || (selected && cmd_arg == {RCA, 16'h0000})) begin
              respond_ok('0);
            end else begin
              respond_illegal();
            end
          end

          6'd41: begin
            if (app_cmd && card_state == CARD_IDLE) begin
              app_cmd <= 1'b0;
              if (acmd41_count < 8'(INIT_BUSY_RESPONSES)) begin
                acmd41_count <= acmd41_count + 8'd1;
                respond_ok({88'd0, OCR_STILL_BUSY});
              end else begin
                card_state <= CARD_READY;
                respond_ok({88'd0, OCR_BUSY_SDHC});
              end
            end else begin
              app_cmd <= 1'b0;
              respond_illegal();
            end
          end

          6'd2: begin
            app_cmd <= 1'b0;
            if (card_state == CARD_READY) begin
              card_state <= CARD_IDENT;
              respond_ok(CID);
            end else begin
              respond_illegal();
            end
          end

          6'd3: begin
            app_cmd <= 1'b0;
            if (card_state == CARD_IDENT || card_state == CARD_READY) begin
              card_state <= CARD_STANDBY;
              respond_ok({88'd0, RCA, 16'h0000});
            end else begin
              respond_illegal();
            end
          end

          6'd7: begin
            app_cmd <= 1'b0;
            if (card_state == CARD_STANDBY && cmd_arg == {RCA, 16'h0000}) begin
              card_state <= CARD_TRANSFER;
              selected <= 1'b1;
              respond_ok('0);
            end else begin
              respond_illegal();
            end
          end

          6'd6: begin
            if (app_cmd && selected && cmd_arg == 32'h0000_0002) begin
              app_cmd <= 1'b0;
              wide_bus <= 1'b1;
              respond_ok('0);
            end else if (!app_cmd && selected && card_state == CARD_TRANSFER
                         && cmd_arg == 32'h80ff_fff1 && cmd_data_read
                         && cmd_block_len == 16'd64) begin
              respond_ok('0);
              start_data(16'd64);
            end else begin
              app_cmd <= 1'b0;
              respond_illegal();
            end
          end

          6'd17: begin
            app_cmd <= 1'b0;
            if (selected && card_state == CARD_TRANSFER && cmd_data_read && cmd_block_len == 16'd512) begin
              last_read_lba <= cmd_arg;
              respond_ok('0);
              start_data(cmd_block_len);
            end else begin
              respond_illegal();
            end
          end

          6'd23: begin
            app_cmd <= 1'b0;
            if (selected && card_state == CARD_TRANSFER && cmd_arg[31:16] == 16'd0
                && cmd_arg[15:0] != 16'd0) begin
              predeclared_block_count <= cmd_arg[15:0];
              respond_ok('0);
            end else begin
              respond_illegal();
            end
          end

          6'd18: begin
            app_cmd <= 1'b0;
            if (selected && card_state == CARD_TRANSFER && cmd_data_read && cmd_block_len == 16'd512
                && predeclared_block_count != 16'd0
                && cmd_block_count == predeclared_block_count) begin
              last_read_lba <= cmd_arg;
              respond_ok('0);
              start_multi_data(cmd_block_len, predeclared_block_count);
              predeclared_block_count <= 16'd0;
            end else begin
              respond_illegal();
            end
          end

          default: begin
            app_cmd <= 1'b0;
            respond_illegal();
          end
        endcase
      end
    end
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_inputs;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_inputs = unused_cmd_inputs;
endmodule
