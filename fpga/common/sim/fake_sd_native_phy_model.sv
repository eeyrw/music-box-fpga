module fake_sd_native_phy_model #(
  parameter int DATA_DELAY_CYCLES = 3,
  parameter int INIT_BUSY_RESPONSES = 1,
  parameter bit HIGH_SPEED_SUPPORTED = 1'b1,
  parameter bit SCR_CMD23_SUPPORTED = 1'b1,
  parameter bit CMD23_ACCEPTED = SCR_CMD23_SUPPORTED
) (
  input  logic clk,
  input  logic rst,
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
  output logic [7:0] illegal_command_count,
  output logic [31:0] last_read_lba,
  output logic selected,
  output logic wide_bus
);
  import sd_native_pkg::*;
  localparam logic [15:0] RCA = 16'h1234;
  localparam logic [31:0] OCR_BUSY_SDHC = 32'hc0ff_8000;
  localparam logic [31:0] OCR_STILL_BUSY = 32'h40ff_8000;
  localparam logic [119:0] CID = 120'h02544d53_41303847_14394a67_c700e4;
  localparam logic [31:0] R1_IDLE_APP = 32'h0000_0020;
  localparam logic [31:0] R1_STANDBY = 32'h0000_0700;
  localparam logic [31:0] R1_TRANSFER = 32'h0000_0900;
  localparam logic [31:0] R1_TRANSFER_APP = 32'h0000_0920;

  typedef enum logic [2:0] {
    CARD_IDLE,
    CARD_READY,
    CARD_IDENT,
    CARD_STANDBY,
    CARD_TRANSFER
  } card_state_t;
  typedef enum logic [1:0] { DATA_IDLE, DATA_WAIT, DATA_SEND } data_state_t;

  card_state_t card_state;
  data_state_t data_state;
  logic app_cmd;
  logic card_detect_pullup_connected;
  logic high_speed_selected;
  logic pending_data;
  logic pending_cmd6;
  logic pending_cmd6_switch;
  logic pending_scr;
  logic pending_command_done;
  logic [15:0] pending_block_len;
  logic [15:0] pending_block_count;
  logic [15:0] preset_block_count;
  logic [15:0] data_delay_count;
  logic [15:0] data_byte_index;
  logic [7:0] acmd41_count;
  logic cmd_accept;

  assign cmd_ready = data_state == DATA_IDLE && !pending_data;
  assign cmd_accept = cmd_valid && cmd_ready;

  function automatic logic [7:0] sector_byte(
      input logic [31:0] lba, input logic [15:0] byte_index);
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
      rsp_status <= SD_STATUS_OK;
      rsp_data <= value;
      rsp_valid <= 1'b1;
    end
  endtask

  task automatic respond_illegal;
    begin
      rsp_status <= SD_STATUS_OK;
      rsp_data <= {88'd0, R1_TRANSFER | 32'h0040_0000};
      rsp_valid <= 1'b1;
      illegal_command_count <= illegal_command_count + 8'd1;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      card_state <= CARD_IDLE;
      data_state <= DATA_IDLE;
      app_cmd <= 1'b0;
      card_detect_pullup_connected <= 1'b1;
      high_speed_selected <= 1'b0;
      selected <= 1'b0;
      wide_bus <= 1'b0;
      pending_data <= 1'b0;
      pending_cmd6 <= 1'b0;
      pending_cmd6_switch <= 1'b0;
      pending_scr <= 1'b0;
      pending_command_done <= 1'b0;
      pending_block_len <= '0;
      pending_block_count <= '0;
      preset_block_count <= '0;
      data_delay_count <= '0;
      data_byte_index <= '0;
      acmd41_count <= '0;
      illegal_command_count <= '0;
      last_read_lba <= '0;
      rsp_valid <= 1'b0;
      rsp_status <= SD_STATUS_OK;
      rsp_data <= '0;
      transaction_done <= 1'b0;
      data_valid <= 1'b0;
      data <= '0;
      data_last <= 1'b0;
      data_status <= SD_STATUS_OK;
    end else begin
      rsp_valid <= 1'b0;
      transaction_done <= 1'b0;
      if (pending_command_done) begin
        transaction_done <= 1'b1;
        pending_command_done <= 1'b0;
      end
      if (data_valid && data_ready) begin
        data_valid <= 1'b0;
        data_last <= 1'b0;
        if (data_last) begin
          if (pending_block_count > 16'd1) begin
            pending_block_count <= pending_block_count - 16'd1;
            last_read_lba <= last_read_lba + 32'd1;
            data_byte_index <= '0;
            data_delay_count <= '0;
            data_state <= DATA_WAIT;
          end else begin
            transaction_done <= 1'b1;
            pending_cmd6 <= 1'b0;
            pending_scr <= 1'b0;
            data_state <= DATA_IDLE;
          end
        end
      end

      if (abort_request || rsp_data_cancel) begin
        pending_data <= 1'b0;
        pending_scr <= 1'b0;
        pending_cmd6 <= 1'b0;
        data_state <= DATA_IDLE;
        data_valid <= 1'b0;
        transaction_done <= 1'b1;
      end else if (rsp_data_proceed && pending_data) begin
        pending_data <= 1'b0;
        data_delay_count <= '0;
        data_byte_index <= '0;
        data_state <= DATA_WAIT;
      end

      unique case (data_state)
        DATA_IDLE: ;
        DATA_WAIT: begin
          if (data_delay_count == 16'(DATA_DELAY_CYCLES))
            data_state <= DATA_SEND;
          else
            data_delay_count <= data_delay_count + 16'd1;
        end
        DATA_SEND: begin
          if (!data_valid) begin
            if (pending_scr) begin
              data <= data_byte_index == 16'd3 && SCR_CMD23_SUPPORTED
                  ? 8'h02 : 8'h00;
            end else if (pending_cmd6) begin
              data <= data_byte_index == 16'd13 && HIGH_SPEED_SUPPORTED ? 8'h02
                  : data_byte_index == 16'd16 && pending_cmd6_switch
                    && HIGH_SPEED_SUPPORTED ? 8'h01 : 8'h00;
            end else begin
              data <= sector_byte(last_read_lba, data_byte_index);
            end
            data_status <= SD_STATUS_OK;
            data_last <= data_byte_index == pending_block_len - 16'd1;
            data_valid <= 1'b1;
            if (data_byte_index == pending_block_len - 16'd1) begin
              if (pending_cmd6 && pending_cmd6_switch && HIGH_SPEED_SUPPORTED)
                high_speed_selected <= 1'b1;
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
            card_detect_pullup_connected <= 1'b1;
            high_speed_selected <= 1'b0;
            acmd41_count <= '0;
            preset_block_count <= '0;
            respond_ok('0);
            transaction_done <= 1'b1;
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
            if (card_state == CARD_IDLE && cmd_arg == 0)
              respond_ok({88'd0, R1_IDLE_APP});
            else if (selected && cmd_arg == {RCA, 16'h0})
              respond_ok({88'd0, R1_TRANSFER_APP});
            else
              respond_illegal();
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
              respond_illegal();
            end
          end
          6'd2: begin
            app_cmd <= 1'b0;
            if (card_state == CARD_READY) begin
              card_state <= CARD_IDENT;
              respond_ok(CID);
            end else
              respond_illegal();
          end
          6'd3: begin
            app_cmd <= 1'b0;
            if (card_state == CARD_IDENT) begin
              card_state <= CARD_STANDBY;
              respond_ok({88'd0, RCA, 16'h0500});
            end else
              respond_illegal();
          end
          6'd7: begin
            app_cmd <= 1'b0;
            if (card_state == CARD_STANDBY && cmd_arg == {RCA, 16'h0}) begin
              card_state <= CARD_TRANSFER;
              selected <= 1'b1;
              respond_ok({88'd0, R1_STANDBY});
            end else
              respond_illegal();
          end
          6'd42: begin
            if (app_cmd && selected && cmd_arg == 0) begin
              app_cmd <= 1'b0;
              card_detect_pullup_connected <= 1'b0;
              respond_ok({88'd0, R1_TRANSFER});
            end else
              respond_illegal();
          end
          6'd6: begin
            if (app_cmd && selected && cmd_arg == 32'h2
                && !card_detect_pullup_connected) begin
              app_cmd <= 1'b0;
              wide_bus <= 1'b1;
              respond_ok({88'd0, R1_TRANSFER});
            end else if (!app_cmd && selected && wide_bus && cmd_data_read
                         && cmd_block_len == 16'd64
                         && (cmd_arg == 32'h00ff_fff1 || cmd_arg == 32'h80ff_fff1)) begin
              respond_ok({88'd0, R1_TRANSFER});
              pending_data <= 1'b1;
              pending_cmd6 <= 1'b1;
              pending_scr <= 1'b0;
              pending_cmd6_switch <= cmd_arg[31];
              pending_block_len <= 16'd64;
              pending_block_count <= 16'd1;
            end else
              respond_illegal();
          end
          6'd51: begin
            if (app_cmd && selected && wide_bus && cmd_arg == 0
                && cmd_data_read && cmd_block_len == 16'd8
                && cmd_block_count == 16'd1) begin
              app_cmd <= 1'b0;
              respond_ok({88'd0, R1_TRANSFER});
              pending_data <= 1'b1;
              pending_scr <= 1'b1;
              pending_cmd6 <= 1'b0;
              pending_block_len <= 16'd8;
              pending_block_count <= 16'd1;
            end else
              respond_illegal();
          end
          6'd23: begin
            app_cmd <= 1'b0;
            if (selected && wide_bus && card_state == CARD_TRANSFER
                && SCR_CMD23_SUPPORTED && CMD23_ACCEPTED && cmd_arg[15:0] != 0) begin
              preset_block_count <= cmd_arg[15:0];
              respond_ok({88'd0, R1_TRANSFER});
            end else
              respond_illegal();
          end
          6'd17: begin
            app_cmd <= 1'b0;
            if (selected && wide_bus && card_state == CARD_TRANSFER
                && cmd_data_read && cmd_block_len == 16'd512
                && cmd_block_count == 16'd1) begin
              last_read_lba <= cmd_arg;
              respond_ok({88'd0, R1_TRANSFER});
              pending_data <= 1'b1;
              pending_cmd6 <= 1'b0;
              pending_scr <= 1'b0;
              pending_block_len <= 16'd512;
              pending_block_count <= 16'd1;
            end else
              respond_illegal();
          end
          6'd18: begin
            app_cmd <= 1'b0;
            if (selected && wide_bus && card_state == CARD_TRANSFER
                && cmd_data_read && cmd_block_len == 16'd512
                && cmd_block_count > 16'd1
                && (preset_block_count == 0
                    || preset_block_count == cmd_block_count)) begin
              last_read_lba <= cmd_arg;
              respond_ok({88'd0, R1_TRANSFER});
              pending_data <= 1'b1;
              pending_cmd6 <= 1'b0;
              pending_scr <= 1'b0;
              pending_block_len <= 16'd512;
              pending_block_count <= cmd_block_count;
              preset_block_count <= '0;
            end else
              respond_illegal();
          end
          6'd12: begin
            app_cmd <= 1'b0;
            if (selected && wide_bus && card_state == CARD_TRANSFER) begin
              pending_data <= 1'b0;
              data_state <= DATA_IDLE;
              data_valid <= 1'b0;
              preset_block_count <= '0;
              respond_ok({88'd0, R1_TRANSFER});
              pending_command_done <= 1'b1;
            end else
              respond_illegal();
          end
          default: respond_illegal();
        endcase
      end
    end
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_inputs;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_inputs = (^cmd_resp_type) ^ high_speed_selected;
endmodule
