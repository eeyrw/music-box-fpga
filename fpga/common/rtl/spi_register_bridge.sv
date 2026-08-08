/* verilator lint_off SYNCASYNCNET */
module spi_register_bridge #(
  parameter bit CHECK_COMMAND_CRC = 1'b1,
  parameter bit CHECK_REGISTER_CRC = 1'b1,
  parameter int MAX_COMMAND_WORDS = 63
) (
  input  logic        clk,
  input  logic        rst,
  input  logic        spi_sclk,
  input  logic        spi_cs_n,
  input  logic        spi_mosi,
  (* IOB = "TRUE" *) output logic spi_miso,
  output logic        spi_error,
  output logic        bus_valid,
  output logic        bus_write,
  output logic [15:0] bus_address,
  output logic [31:0] bus_wdata,
  input  logic [31:0] bus_rdata,
  input  logic        bus_ready,
  input  logic        bus_error,
  output logic        cmd_valid,
  output logic [31:0] cmd_data,
  input  logic        cmd_ready,
  output logic        cmd_flush_req,
  input  logic        cmd_flush_ack,
  output logic        session_reset_req,
  input  logic        session_reset_ack,
  input  logic [31:0] session_epoch,
  input  logic completion_event_valid,
  input  logic [8:0] completion_event_voice,
  input  logic [15:0] completion_event_generation,
  input  logic [1:0] completion_event_reason
);
  localparam logic [7:0] MAILBOX_REQUEST_OPCODE = 8'h5a;
  localparam logic [7:0] MAILBOX_FETCH_OPCODE = 8'h5b;
  localparam logic [7:0] COMPLETION_LOG_OPCODE = 8'h5d;
  localparam logic [7:0] COMMAND_STREAM_OPCODE = 8'ha5;
  localparam logic [7:0] COMMAND_FLUSH_OPCODE = 8'ha6;
  localparam logic [7:0] SESSION_RESET_OPCODE = 8'ha7;
  localparam logic [7:0] REGISTER_READ = 8'h00;
  localparam logic [7:0] REGISTER_WRITE = 8'h01;
  localparam logic [7:0] RESPONSE_OK = 8'h00;
  localparam logic [7:0] RESPONSE_BUS_ERROR = 8'h01;
  localparam logic [7:0] RESPONSE_BUSY = 8'h02;
  localparam logic [7:0] RESPONSE_EMPTY = 8'h03;
  localparam int COMPLETION_LOG_ITEMS = 16;
  localparam int COMPLETION_LOG_HEADER_BITS = 96;
  localparam int COMMAND_INDEX_WIDTH = $clog2(MAX_COMMAND_WORDS);

  typedef enum logic [4:0] {
    STATE_IDLE,
    STATE_COMMAND,
    STATE_MAILBOX_REQUEST,
    STATE_MAILBOX_REQUEST_WAIT,
    STATE_FETCH_HEADER,
    STATE_FETCH_DATA,
    STATE_FETCH_WAIT,
    STATE_STREAM_HEADER,
    STATE_STREAM_DATA,
    STATE_FLUSH_HEADER,
    STATE_FLUSH_WAIT,
    STATE_SESSION_RESET_HEADER,
    STATE_SESSION_RESET_WAIT,
    STATE_COMPLETION_LOG_REQUEST,
    STATE_COMPLETION_LOG_TURNAROUND,
    STATE_COMPLETION_LOG_DATA,
    STATE_COMPLETION_LOG_WAIT,
    STATE_REJECT
  } state_t;

  state_t state;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] sclk_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] cs_sync;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [1:0] mosi_sync;
  logic [6:0] command_shift;
  logic [6:0] bit_count;
  logic [9:0] completion_data_bit_count;
  logic [30:0] data_shift;
  logic [86:0] mailbox_request_shift;
  logic read_sample_seen;
  logic sclk_rise;
  logic sclk_fall;
  logic cs_active;
  logic cs_start;
  logic cs_end;

  logic [7:0] request_operation;
  logic [15:0] request_address;
  logic [31:0] request_wdata;
  logic [31:0] request_expected_crc;
  logic [31:0] request_crc;
  logic response_valid;
  logic [7:0] response_status;
  logic [7:0] response_operation;
  logic [15:0] response_address;
  logic [31:0] response_data;
  logic [7:0] fetch_status;
  logic [7:0] fetch_operation;
  logic [15:0] fetch_address;
  logic [31:0] fetch_data;
  logic [63:0] fetch_payload;
  logic [9:0] spi_tx_bit_count;
  logic [30:0] spi_tx_header_shift;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [63:0] fetch_payload_meta;
  (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [63:0] fetch_payload_sync;
  logic [63:0] fetch_payload_snapshot;
  logic [31:0] spi_tx_crc_work;
  logic [95:0] fetch_frame_snapshot;
  logic [94:0] spi_tx_shift;
  logic spi_tx_fetch_valid;
  logic spi_tx_completion_log_valid;
  logic [6:0] completion_tx_byte_shift;
  logic [30:0] completion_tx_crc_shift;
  logic [31:0] completion_tx_crc_q;

  logic completion_log_snapshot_toggle_meta;
  logic completion_log_snapshot_toggle_sync;
  logic completion_log_snapshot_toggle_start;
  logic completion_log_snapshot_toggle_q;
  logic [30:0] completion_log_request_shift;
  logic [15:0] completion_log_request_crc;
  logic completion_log_query_valid;
  logic completion_log_query_ready;
  logic [15:0] completion_log_query_sequence;
  logic completion_log_response_valid;
  logic [7:0] completion_log_response_status;
  logic [15:0] completion_log_response_start_sequence;
  logic [15:0] completion_log_response_write_sequence;
  logic [7:0] completion_log_response_count;
  logic completion_log_response_overflow;
  logic [COMPLETION_LOG_HEADER_BITS-1:0] completion_log_response_header;
  logic [31:0] completion_log_epoch_q;
  logic [15:0] completion_log_read_sequence;
  logic [31:0] completion_log_read_data;
  logic [COMPLETION_LOG_HEADER_BITS-2:0] completion_log_header_shift;
  logic [30:0] completion_log_item_shift;
  logic [9:0] completion_log_valid_item_bits;
  logic completion_log_tx_bit;

  (* ram_style = "block" *) logic [31:0]
      command_staging [0:MAX_COMMAND_WORDS-1];
  logic staging_write_enable;
  logic [COMMAND_INDEX_WIDTH-1:0] staging_write_address;
  logic [31:0] staging_write_data;
  logic [COMMAND_INDEX_WIDTH-1:0] staging_read_address;
  logic [31:0] staging_read_data;
  logic [7:0] stream_declared_words;
  logic [7:0] stream_received_words;
  logic [7:0] stream_command_words_remaining;
  logic [15:0] stream_expected_crc;
  logic [15:0] stream_crc;
  logic stream_reject;
  logic [COMMAND_INDEX_WIDTH-1:0] commit_index;
  logic [7:0] commit_words;
  logic commit_start_pending;

  function automatic logic [15:0] crc16_ccitt_byte(
    input logic [15:0] crc_in,
    input logic [7:0] data
  );
    logic [15:0] crc;
    begin
      crc = crc_in ^ {data, 8'd0};
      for (int bit_index = 0; bit_index < 8; bit_index++)
        crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
      crc16_ccitt_byte = crc;
    end
  endfunction

  function automatic logic [31:0] crc32_byte(
    input logic [31:0] crc_in,
    input logic [7:0] data
  );
    logic [31:0] crc;
    begin
      crc = crc_in ^ {24'd0, data};
      for (int bit_index = 0; bit_index < 8; bit_index++)
        crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
      crc32_byte = crc;
    end
  endfunction

  assign sclk_rise = cs_active && !sclk_sync[1] && sclk_sync[0];
  assign sclk_fall = cs_active && sclk_sync[1] && !sclk_sync[0];
  assign cs_active = !cs_sync[0];
  assign cs_start = cs_sync[1] && !cs_sync[0];
  assign cs_end = !cs_sync[1] && cs_sync[0];

  assign completion_log_response_header = {
    completion_log_response_status,
    8'h01,
    {7'd0, completion_log_response_overflow},
    completion_log_response_count,
    completion_log_epoch_q,
    completion_log_response_write_sequence,
    completion_log_response_start_sequence
  };

  always_comb begin
    if (spi_tx_bit_count <= 10'd199) begin
      completion_log_tx_bit = completion_log_header_shift[
          COMPLETION_LOG_HEADER_BITS-2];
    end else if (completion_log_valid_item_bits == 0) begin
      completion_log_tx_bit = 1'b0;
    end else if (spi_tx_bit_count[4:0] == 5'd8) begin
      completion_log_tx_bit = completion_log_read_data[31];
    end else begin
      completion_log_tx_bit = completion_log_item_shift[30];
    end
  end

  spi_completion_log #(
    .DEPTH(512),
    .BATCH_ITEMS(COMPLETION_LOG_ITEMS)
  ) completion_log (
    .clk,
    .rst,
    .clear(session_reset_req && session_reset_ack),
    .event_valid(completion_event_valid),
    .event_voice(completion_event_voice),
    .event_generation(completion_event_generation),
    .event_reason(completion_event_reason),
    .query_valid(completion_log_query_valid),
    .query_ready(completion_log_query_ready),
    .query_sequence(completion_log_query_sequence),
    .read_clk(spi_sclk),
    .read_address(completion_log_read_sequence[8:0]),
    .read_data(completion_log_read_data),
    .response_valid(completion_log_response_valid),
    .response_status(completion_log_response_status),
    .response_start_sequence(completion_log_response_start_sequence),
    .response_write_sequence(completion_log_response_write_sequence),
    .response_count(completion_log_response_count),
    .response_overflow(completion_log_response_overflow)
  );

  always_comb begin
    staging_write_enable = (state == STATE_STREAM_DATA) && sclk_rise &&
        (bit_count == 7'd31) && !stream_reject &&
        (stream_received_words < stream_declared_words) &&
        (stream_received_words < 8'(MAX_COMMAND_WORDS));
    staging_write_address =
        stream_received_words[COMMAND_INDEX_WIDTH-1:0];
    staging_write_data = {data_shift[30:0], mosi_sync[1]};

    staging_read_address = commit_index;
    if (commit_start_pending &&
        ((8'(commit_index) + 8'd1) < commit_words)) begin
      staging_read_address = commit_index + 1'b1;
    end else if (cmd_valid && cmd_ready &&
                 ((8'(commit_index) + 8'd2) < commit_words)) begin
      staging_read_address = commit_index + COMMAND_INDEX_WIDTH'(2);
    end else if (cmd_valid &&
                 ((8'(commit_index) + 8'd1) < commit_words)) begin
      staging_read_address = commit_index + 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (staging_write_enable)
      command_staging[staging_write_address] <= staging_write_data;
    staging_read_data <= command_staging[staging_read_address];
  end

  // A fetch response is already complete before its data phase. Synchronize
  // and freeze it during the 32-bit MOSI header, then launch each MISO bit from
  // the real SCLK falling edge so mode-0 setup does not include oversampling
  // latency from the system-clock domain.
  always_ff @(posedge spi_sclk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
      spi_tx_bit_count <= '0;
      spi_tx_header_shift <= '0;
      fetch_payload_meta <= '0;
      fetch_payload_sync <= '0;
      fetch_payload_snapshot <= '0;
      spi_tx_crc_work <= '0;
      fetch_frame_snapshot <= '0;
      spi_tx_fetch_valid <= 1'b0;
      spi_tx_completion_log_valid <= 1'b0;
      completion_log_snapshot_toggle_meta <= 1'b0;
      completion_log_snapshot_toggle_sync <= 1'b0;
      completion_log_snapshot_toggle_start <= 1'b0;
    end else begin
      fetch_payload_meta <= fetch_payload;
      fetch_payload_sync <= fetch_payload_meta;
      completion_log_snapshot_toggle_meta <=
          completion_log_snapshot_toggle_q;
      completion_log_snapshot_toggle_sync <=
          completion_log_snapshot_toggle_meta;

      if (spi_tx_bit_count < 10'd96) begin
        spi_tx_header_shift <= {spi_tx_header_shift[29:0], spi_mosi};
        spi_tx_bit_count <= spi_tx_bit_count + 10'd1;
        if (spi_tx_bit_count == 10'd7) begin
          fetch_payload_snapshot <= fetch_payload_sync;
          spi_tx_crc_work <= crc32_byte(
              32'hffff_ffff, fetch_payload_sync[63:56]);
        end else if (spi_tx_bit_count >= 10'd8 &&
                     spi_tx_bit_count <= 10'd14) begin
          spi_tx_crc_work <= crc32_byte(
              spi_tx_crc_work,
              fetch_payload_snapshot[(14 - spi_tx_bit_count)*8 +: 8]);
        end else if (spi_tx_bit_count == 10'd15) begin
          fetch_frame_snapshot <= {
            fetch_payload_snapshot, spi_tx_crc_work ^ 32'hffff_ffff
          };
        end
        if (spi_tx_bit_count == 10'd31)
          spi_tx_fetch_valid <=
              {spi_tx_header_shift[30:0], spi_mosi} == 32'h5b00_0000;
        if (spi_tx_bit_count == 10'd7) begin
          spi_tx_completion_log_valid <=
              {spi_tx_header_shift[6:0], spi_mosi} ==
              COMPLETION_LOG_OPCODE;
          completion_log_snapshot_toggle_start <=
              completion_log_snapshot_toggle_sync;
        end
      end else if (spi_tx_bit_count < 10'd744) begin
        spi_tx_bit_count <= spi_tx_bit_count + 10'd1;
      end
    end
  end

  always_ff @(negedge spi_sclk or posedge spi_cs_n) begin
    if (spi_cs_n) begin
      spi_miso <= 1'b0;
      spi_tx_shift <= '0;
      completion_tx_byte_shift <= '0;
      completion_tx_crc_shift <= '0;
      completion_tx_crc_q <= '0;
      completion_log_read_sequence <= '0;
      completion_log_header_shift <= '0;
      completion_log_item_shift <= '0;
      completion_log_valid_item_bits <= '0;
    end else if (spi_tx_fetch_valid && spi_tx_bit_count == 10'd32) begin
      spi_miso <= fetch_frame_snapshot[95];
      spi_tx_shift <= fetch_frame_snapshot[94:0];
    end else if (spi_tx_fetch_valid && spi_tx_bit_count > 10'd32 &&
                 spi_tx_bit_count <= 10'd127) begin
      spi_miso <= spi_tx_shift[94];
      spi_tx_shift <= {spi_tx_shift[93:0], 1'b0};
    end else if (spi_tx_completion_log_valid &&
                 (spi_tx_bit_count == 10'd104)) begin
      spi_miso <= (completion_log_snapshot_toggle_sync !=
                   completion_log_snapshot_toggle_start) ?
          completion_log_response_header[COMPLETION_LOG_HEADER_BITS-1] :
          1'b0;
      completion_log_header_shift <= completion_log_response_header[
          COMPLETION_LOG_HEADER_BITS-2:0];
      completion_tx_byte_shift <= {
        6'd0,
        completion_log_response_header[COMPLETION_LOG_HEADER_BITS-1]
      };
      completion_tx_crc_q <= 32'hffff_ffff;
      completion_log_read_sequence <=
          completion_log_response_start_sequence;
      completion_log_valid_item_bits <=
          10'(completion_log_response_count) << 5;
    end else if (spi_tx_completion_log_valid &&
                 (spi_tx_bit_count > 10'd104) &&
                 (spi_tx_bit_count <= 10'd711)) begin
      if (spi_tx_bit_count <= 10'd199) begin
        spi_miso <= completion_log_tx_bit;
        completion_log_header_shift <= {
          completion_log_header_shift[COMPLETION_LOG_HEADER_BITS-3:0], 1'b0
        };
        completion_tx_byte_shift <= {
          completion_tx_byte_shift[5:0],
          completion_log_tx_bit
        };
      end else if (spi_tx_bit_count[4:0] == 5'd8) begin
        spi_miso <= completion_log_tx_bit;
        completion_log_item_shift <= completion_log_read_data[30:0];
        completion_tx_byte_shift <= {
          completion_tx_byte_shift[5:0],
          completion_log_tx_bit
        };
      end else begin
        spi_miso <= completion_log_tx_bit;
        completion_log_item_shift <= {
          completion_log_item_shift[29:0], 1'b0
        };
        completion_tx_byte_shift <= {
          completion_tx_byte_shift[5:0],
          completion_log_tx_bit
        };
      end
      if (spi_tx_bit_count >= 10'd200 &&
          completion_log_valid_item_bits != 0)
        completion_log_valid_item_bits <=
            completion_log_valid_item_bits - 1'b1;
      if (spi_tx_bit_count >= 10'd200 &&
          spi_tx_bit_count[4:0] == 5'd7)
        completion_log_read_sequence <=
            completion_log_read_sequence + 1'b1;
      if (spi_tx_bit_count[2:0] == 3'd7) begin
        if (spi_tx_bit_count == 10'd711)
          completion_tx_crc_q <= crc32_byte(
              completion_tx_crc_q,
              {completion_tx_byte_shift,
               completion_log_tx_bit}) ^
              32'hffff_ffff;
        else
          completion_tx_crc_q <= crc32_byte(
              completion_tx_crc_q,
              {completion_tx_byte_shift,
               completion_log_tx_bit});
      end
    end else if (spi_tx_completion_log_valid &&
                 (spi_tx_bit_count == 10'd712)) begin
      spi_miso <= completion_tx_crc_q[31];
      completion_tx_crc_shift <= completion_tx_crc_q[30:0];
    end else if (spi_tx_completion_log_valid &&
                 (spi_tx_bit_count > 10'd712) &&
                 (spi_tx_bit_count <= 10'd743)) begin
      spi_miso <= completion_tx_crc_shift[30];
      completion_tx_crc_shift <= {completion_tx_crc_shift[29:0], 1'b0};
    end else begin
      spi_miso <= 1'b0;
    end
  end

  always_comb begin
    if (bus_valid) begin
      fetch_status = RESPONSE_BUSY;
      fetch_operation = bus_write ? REGISTER_WRITE : REGISTER_READ;
      fetch_address = bus_address;
      fetch_data = 32'd0;
    end else if (response_valid) begin
      fetch_status = response_status;
      fetch_operation = response_operation;
      fetch_address = response_address;
      fetch_data = response_data;
    end else begin
      fetch_status = RESPONSE_EMPTY;
      fetch_operation = 8'd0;
      fetch_address = 16'd0;
      fetch_data = 32'd0;
    end
    fetch_payload = {
      fetch_status, fetch_operation, fetch_address, fetch_data
    };
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      sclk_sync <= '0;
      cs_sync <= 2'b11;
      mosi_sync <= '0;
    end else begin
      sclk_sync <= {sclk_sync[0], spi_sclk};
      cs_sync <= {cs_sync[0], spi_cs_n};
      mosi_sync <= {mosi_sync[0], spi_mosi};
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      command_shift <= '0;
      bit_count <= '0;
      completion_data_bit_count <= '0;
      data_shift <= '0;
      mailbox_request_shift <= '0;
      read_sample_seen <= 1'b0;
      request_operation <= '0;
      request_address <= '0;
      request_wdata <= '0;
      request_expected_crc <= '0;
      request_crc <= '0;
      response_valid <= 1'b0;
      response_status <= RESPONSE_EMPTY;
      response_operation <= '0;
      response_address <= '0;
      response_data <= '0;
      spi_error <= 1'b0;
      bus_valid <= 1'b0;
      bus_write <= 1'b0;
      bus_address <= '0;
      bus_wdata <= '0;
      cmd_valid <= 1'b0;
      cmd_data <= '0;
      cmd_flush_req <= 1'b0;
      session_reset_req <= 1'b0;
      stream_declared_words <= '0;
      stream_received_words <= '0;
      stream_command_words_remaining <= '0;
      stream_expected_crc <= '0;
      stream_crc <= '0;
      stream_reject <= 1'b0;
      commit_index <= '0;
      commit_words <= '0;
      commit_start_pending <= 1'b0;
      completion_log_request_shift <= '0;
      completion_log_request_crc <= '0;
      completion_log_query_valid <= 1'b0;
      completion_log_query_sequence <= '0;
      completion_log_snapshot_toggle_q <= 1'b0;
      completion_log_epoch_q <= '0;
    end else begin
      completion_log_query_valid <= 1'b0;

      if (cmd_flush_req && cmd_flush_ack)
        cmd_flush_req <= 1'b0;
      if (session_reset_req && session_reset_ack)
        session_reset_req <= 1'b0;

      if (session_reset_req && session_reset_ack)
        completion_log_snapshot_toggle_q <= 1'b0;

      if (completion_log_response_valid) begin
        completion_log_epoch_q <= session_epoch;
        completion_log_snapshot_toggle_q <=
            ~completion_log_snapshot_toggle_q;
      end

      if (bus_valid && bus_ready) begin
        bus_valid <= 1'b0;
        response_valid <= 1'b1;
        response_status <= bus_error ? RESPONSE_BUS_ERROR : RESPONSE_OK;
        response_operation <= bus_write ? REGISTER_WRITE : REGISTER_READ;
        response_address <= bus_address;
        response_data <= (!bus_write && !bus_error) ? bus_rdata : 32'd0;
        spi_error <= spi_error || bus_error;
      end

      if (commit_start_pending) begin
        commit_start_pending <= 1'b0;
        cmd_valid <= 1'b1;
      end

      if (cmd_valid && cmd_ready) begin
        if ((8'(commit_index) + 8'd1) >= commit_words) begin
          cmd_valid <= 1'b0;
        end else begin
          commit_index <= commit_index + 1'b1;
          cmd_data <= staging_read_data;
        end
      end

      if (cs_end) begin
        if (state == STATE_MAILBOX_REQUEST_WAIT) begin
          if (!bus_valid) begin
            response_valid <= 1'b0;
            if (((request_operation == REGISTER_READ) ||
                 (request_operation == REGISTER_WRITE)) &&
                (!CHECK_REGISTER_CRC ||
                 (request_expected_crc ==
                  (request_crc ^ 32'hffff_ffff)))) begin
              bus_valid <= 1'b1;
              bus_write <= request_operation == REGISTER_WRITE;
              bus_address <= request_address;
              bus_wdata <= request_wdata;
            end else begin
              spi_error <= 1'b1;
            end
          end else begin
            spi_error <= 1'b1;
          end
        end else if (state == STATE_STREAM_DATA) begin
          if (!stream_reject && (bit_count == 0) &&
              (stream_received_words == stream_declared_words) &&
              (stream_command_words_remaining == 0) &&
              (!CHECK_COMMAND_CRC || (stream_crc == stream_expected_crc)) &&
              !cmd_valid && !commit_start_pending && !session_reset_req) begin
            commit_index <= '0;
            commit_words <= stream_received_words;
            cmd_data <= staging_read_data;
            commit_start_pending <= 1'b1;
          end else begin
            spi_error <= 1'b1;
          end
        end else if (state == STATE_FLUSH_WAIT) begin
          if ((data_shift[23:16] == 8'h00) &&
              (!CHECK_COMMAND_CRC ||
               (data_shift[15:0] ==
                crc16_ccitt_byte(
                    crc16_ccitt_byte(16'hffff, COMMAND_FLUSH_OPCODE),
                    8'h00))) && !cmd_flush_req && !session_reset_req) begin
            cmd_flush_req <= 1'b1;
            cmd_valid <= 1'b0;
            commit_start_pending <= 1'b0;
            commit_index <= '0;
            commit_words <= '0;
          end else begin
            spi_error <= 1'b1;
          end
        end else if (state == STATE_SESSION_RESET_WAIT) begin
          if ((data_shift[23:16] == 8'h00) &&
              (!CHECK_COMMAND_CRC ||
               (data_shift[15:0] ==
                crc16_ccitt_byte(
                    crc16_ccitt_byte(16'hffff, SESSION_RESET_OPCODE),
                    8'h00))) && !cmd_flush_req && !session_reset_req) begin
            session_reset_req <= 1'b1;
            cmd_valid <= 1'b0;
            commit_start_pending <= 1'b0;
            commit_index <= '0;
            commit_words <= '0;
          end else begin
            spi_error <= 1'b1;
          end
        end else if ((state != STATE_FETCH_WAIT) &&
                     (state != STATE_COMPLETION_LOG_WAIT) &&
                     !((state == STATE_COMMAND) && (bit_count == 0))) begin
          if (!bus_valid && ((state == STATE_MAILBOX_REQUEST) ||
                             (state == STATE_MAILBOX_REQUEST_WAIT)))
            response_valid <= 1'b0;
          spi_error <= 1'b1;
        end
        state <= STATE_IDLE;
        bit_count <= '0;
        completion_data_bit_count <= '0;
      end else if (!cs_active) begin
        state <= STATE_IDLE;
        bit_count <= '0;
        completion_data_bit_count <= '0;
      end else if (cs_start) begin
        state <= (cmd_flush_req || session_reset_req) ?
                 STATE_REJECT : STATE_COMMAND;
        command_shift <= '0;
        bit_count <= '0;
        data_shift <= '0;
        mailbox_request_shift <= '0;
        read_sample_seen <= 1'b0;
        spi_error <= cmd_flush_req || session_reset_req;
        stream_declared_words <= '0;
        stream_received_words <= '0;
        stream_command_words_remaining <= '0;
        stream_expected_crc <= '0;
        stream_crc <= '0;
        stream_reject <= 1'b0;
        request_crc <= '0;
        completion_log_request_shift <= '0;
        completion_log_request_crc <= '0;
      end else begin
        unique case (state)
          STATE_IDLE: begin
          end

          STATE_COMMAND: begin
            if (sclk_rise) begin
              command_shift <= {command_shift[5:0], mosi_sync[1]};
              if (bit_count == 7'd7) begin
                bit_count <= '0;
                data_shift <= '0;
                unique case ({command_shift[6:0], mosi_sync[1]})
                  MAILBOX_REQUEST_OPCODE: begin
                    state <= STATE_MAILBOX_REQUEST;
                    request_crc <= crc32_byte(
                        32'hffff_ffff, MAILBOX_REQUEST_OPCODE);
                  end
                  MAILBOX_FETCH_OPCODE: state <= STATE_FETCH_HEADER;
                  COMPLETION_LOG_OPCODE: begin
                    state <= STATE_COMPLETION_LOG_REQUEST;
                    completion_log_request_shift <= '0;
                    completion_log_request_crc <= crc16_ccitt_byte(
                        16'hffff, COMPLETION_LOG_OPCODE);
                  end
                  COMMAND_STREAM_OPCODE: begin
                    state <= STATE_STREAM_HEADER;
                    commit_index <= '0;
                  end
                  COMMAND_FLUSH_OPCODE: begin
                    state <= STATE_FLUSH_HEADER;
                    data_shift <= '0;
                  end
                  SESSION_RESET_OPCODE: begin
                    state <= STATE_SESSION_RESET_HEADER;
                    data_shift <= '0;
                  end
                  default: begin
                    state <= STATE_REJECT;
                    spi_error <= 1'b1;
                  end
                endcase
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_MAILBOX_REQUEST: begin
            if (sclk_rise) begin
              mailbox_request_shift <= {
                mailbox_request_shift[85:0], mosi_sync[1]
              };
              if ((bit_count < 7'd56) && (bit_count[2:0] == 3'd7))
                request_crc <= crc32_byte(
                    request_crc,
                    {mailbox_request_shift[6:0], mosi_sync[1]});
              if (bit_count == 7'd87) begin
                request_operation <= mailbox_request_shift[86:79];
                request_address <= mailbox_request_shift[78:63];
                request_wdata <= mailbox_request_shift[62:31];
                request_expected_crc <= {
                  mailbox_request_shift[30:0], mosi_sync[1]
                };
                bit_count <= '0;
                state <= STATE_MAILBOX_REQUEST_WAIT;
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_MAILBOX_REQUEST_WAIT: begin
            if (sclk_rise) begin
              state <= STATE_REJECT;
              spi_error <= 1'b1;
            end
          end

          STATE_COMPLETION_LOG_REQUEST: begin
            if (sclk_rise) begin
              completion_log_request_shift <= {
                completion_log_request_shift[29:0], mosi_sync[1]
              };
              if ((bit_count == 7'd7) || (bit_count == 7'd15))
                completion_log_request_crc <= crc16_ccitt_byte(
                    completion_log_request_crc,
                    {completion_log_request_shift[6:0], mosi_sync[1]});
              if (bit_count == 7'd31) begin
                bit_count <= '0;
                if (({completion_log_request_shift[14:0], mosi_sync[1]} ==
                     completion_log_request_crc) &&
                    completion_log_query_ready) begin
                  completion_log_query_sequence <=
                      completion_log_request_shift[30:15];
                  completion_log_query_valid <= 1'b1;
                  state <= STATE_COMPLETION_LOG_TURNAROUND;
                end else begin
                  spi_error <= 1'b1;
                  state <= STATE_REJECT;
                end
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_COMPLETION_LOG_TURNAROUND: begin
            if (sclk_rise) begin
              if (bit_count == 7'd63) begin
                bit_count <= '0;
                completion_data_bit_count <= '0;
                state <= STATE_COMPLETION_LOG_DATA;
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_COMPLETION_LOG_DATA: begin
            if (sclk_rise) begin
              if (completion_data_bit_count == 10'd639) begin
                completion_data_bit_count <= '0;
                state <= STATE_COMPLETION_LOG_WAIT;
              end else begin
                completion_data_bit_count <=
                    completion_data_bit_count + 1'b1;
              end
            end
          end

          STATE_COMPLETION_LOG_WAIT: begin
            if (sclk_rise) begin
              state <= STATE_REJECT;
              spi_error <= 1'b1;
            end
          end

          STATE_FETCH_HEADER: begin
            if (sclk_rise) begin
              data_shift <= {data_shift[29:0], mosi_sync[1]};
              if (bit_count == 7'd23) begin
                if ({data_shift[22:0], mosi_sync[1]} != 24'd0)
                  spi_error <= 1'b1;
                read_sample_seen <= 1'b0;
                bit_count <= '0;
                state <= STATE_FETCH_DATA;
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_FETCH_DATA: begin
            if (sclk_rise) begin
              read_sample_seen <= 1'b1;
            end else if (sclk_fall && read_sample_seen) begin
              read_sample_seen <= 1'b0;
              if (bit_count == 7'd95) begin
                bit_count <= '0;
                state <= STATE_FETCH_WAIT;
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_FETCH_WAIT: begin
            if (sclk_rise) begin
              state <= STATE_REJECT;
              spi_error <= 1'b1;
            end
          end

          STATE_STREAM_HEADER: begin
            if (sclk_rise) begin
              data_shift <= {data_shift[29:0], mosi_sync[1]};
              if (bit_count == 7'd23) begin
                stream_declared_words <= data_shift[22:15];
                stream_expected_crc <= {data_shift[14:0], mosi_sync[1]};
                stream_crc <= crc16_ccitt_byte(
                    16'hffff, data_shift[22:15]);
                stream_reject <= cmd_valid || commit_start_pending ||
                    cmd_flush_req || session_reset_req ||
                    (data_shift[22:15] == 0) ||
                    (data_shift[22:15] > 8'(MAX_COMMAND_WORDS));
                if (cmd_valid || commit_start_pending || cmd_flush_req ||
                    session_reset_req ||
                    (data_shift[22:15] == 0) ||
                    (data_shift[22:15] > 8'(MAX_COMMAND_WORDS)))
                  spi_error <= 1'b1;
                bit_count <= '0;
                data_shift <= '0;
                state <= STATE_STREAM_DATA;
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_STREAM_DATA: begin
            if (sclk_rise) begin
              data_shift <= {data_shift[29:0], mosi_sync[1]};
              if (bit_count[2:0] == 3'd7)
                stream_crc <= crc16_ccitt_byte(
                    stream_crc, {data_shift[6:0], mosi_sync[1]});
              if (bit_count == 7'd31) begin
                bit_count <= '0;
                if (stream_command_words_remaining == 0) begin
                  if ({data_shift[6:0], mosi_sync[1]} > 8'd16)
                    stream_reject <= 1'b1;
                  stream_command_words_remaining <=
                      {data_shift[6:0], mosi_sync[1]};
                end else begin
                  stream_command_words_remaining <=
                      stream_command_words_remaining - 1'b1;
                end
                if (stream_received_words < 8'hff)
                  stream_received_words <= stream_received_words + 1'b1;
                if (stream_received_words >= stream_declared_words) begin
                  stream_reject <= 1'b1;
                  spi_error <= 1'b1;
                end
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_FLUSH_HEADER: begin
            if (sclk_rise) begin
              data_shift <= {data_shift[29:0], mosi_sync[1]};
              if (bit_count == 7'd23) begin
                bit_count <= '0;
                state <= STATE_FLUSH_WAIT;
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_FLUSH_WAIT: begin
            if (sclk_rise) begin
              state <= STATE_REJECT;
              spi_error <= 1'b1;
            end
          end

          STATE_SESSION_RESET_HEADER: begin
            if (sclk_rise) begin
              data_shift <= {data_shift[29:0], mosi_sync[1]};
              if (bit_count == 7'd23) begin
                bit_count <= '0;
                state <= STATE_SESSION_RESET_WAIT;
              end else begin
                bit_count <= bit_count + 7'd1;
              end
            end
          end

          STATE_SESSION_RESET_WAIT: begin
            if (sclk_rise) begin
              state <= STATE_REJECT;
              spi_error <= 1'b1;
            end
          end

          STATE_REJECT: begin
          end

          default: state <= STATE_IDLE;
        endcase
      end
    end
  end
endmodule
/* verilator lint_on SYNCASYNCNET */
