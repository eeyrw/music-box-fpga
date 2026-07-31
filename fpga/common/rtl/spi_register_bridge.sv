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
  output logic        spi_miso,
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
  input  logic        cmd_ready
);
  localparam logic [7:0] MAILBOX_REQUEST_OPCODE = 8'h5a;
  localparam logic [7:0] MAILBOX_FETCH_OPCODE = 8'h5b;
  localparam logic [7:0] COMMAND_STREAM_OPCODE = 8'ha5;
  localparam logic [7:0] REGISTER_READ = 8'h00;
  localparam logic [7:0] REGISTER_WRITE = 8'h01;
  localparam logic [7:0] RESPONSE_OK = 8'h00;
  localparam logic [7:0] RESPONSE_BUS_ERROR = 8'h01;
  localparam logic [7:0] RESPONSE_BUSY = 8'h02;
  localparam logic [7:0] RESPONSE_EMPTY = 8'h03;
  localparam int COMMAND_INDEX_WIDTH = $clog2(MAX_COMMAND_WORDS);

  typedef enum logic [3:0] {
    STATE_IDLE,
    STATE_COMMAND,
    STATE_MAILBOX_REQUEST,
    STATE_MAILBOX_REQUEST_WAIT,
    STATE_FETCH_HEADER,
    STATE_FETCH_DATA,
    STATE_FETCH_WAIT,
    STATE_STREAM_HEADER,
    STATE_STREAM_DATA,
    STATE_REJECT
  } state_t;

  state_t state;
  logic [1:0] sclk_sync;
  logic [1:0] cs_sync;
  logic [1:0] mosi_sync;
  logic [6:0] command_shift;
  logic [6:0] bit_count;
  logic [30:0] data_shift;
  logic [86:0] mailbox_request_shift;
  logic [94:0] mailbox_tx_shift;
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
  logic response_valid;
  logic [7:0] response_status;
  logic [7:0] response_operation;
  logic [15:0] response_address;
  logic [31:0] response_data;
  logic [7:0] fetch_status;
  logic [7:0] fetch_operation;
  logic [15:0] fetch_address;
  logic [31:0] fetch_data;
  logic [31:0] fetch_crc;
  logic [95:0] fetch_frame;

  logic [31:0] command_staging [0:MAX_COMMAND_WORDS-1];
  logic [7:0] stream_declared_words;
  logic [7:0] stream_received_words;
  logic [7:0] stream_command_words_remaining;
  logic [15:0] stream_expected_crc;
  logic [15:0] stream_crc;
  logic stream_reject;
  logic [COMMAND_INDEX_WIDTH-1:0] commit_index;
  logic [7:0] commit_words;

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

  function automatic logic [15:0] crc16_ccitt_word(
    input logic [15:0] crc_in,
    input logic [31:0] data
  );
    logic [15:0] crc;
    begin
      crc = crc16_ccitt_byte(crc_in, data[31:24]);
      crc = crc16_ccitt_byte(crc, data[23:16]);
      crc = crc16_ccitt_byte(crc, data[15:8]);
      crc16_ccitt_word = crc16_ccitt_byte(crc, data[7:0]);
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

  function automatic logic [31:0] register_frame_crc32(
    input logic [7:0] byte0,
    input logic [7:0] byte1,
    input logic [15:0] address,
    input logic [31:0] data
  );
    logic [31:0] crc;
    begin
      crc = crc32_byte(32'hffff_ffff, byte0);
      crc = crc32_byte(crc, byte1);
      crc = crc32_byte(crc, address[15:8]);
      crc = crc32_byte(crc, address[7:0]);
      crc = crc32_byte(crc, data[31:24]);
      crc = crc32_byte(crc, data[23:16]);
      crc = crc32_byte(crc, data[15:8]);
      crc = crc32_byte(crc, data[7:0]);
      register_frame_crc32 = crc ^ 32'hffff_ffff;
    end
  endfunction

  assign sclk_rise = cs_active && !sclk_sync[1] && sclk_sync[0];
  assign sclk_fall = cs_active && sclk_sync[1] && !sclk_sync[0];
  assign cs_active = !cs_sync[0];
  assign cs_start = cs_sync[1] && !cs_sync[0];
  assign cs_end = !cs_sync[1] && cs_sync[0];

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
    fetch_crc = register_frame_crc32(
        fetch_status, fetch_operation, fetch_address, fetch_data);
    fetch_frame = {
      fetch_status, fetch_operation, fetch_address, fetch_data, fetch_crc
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
      data_shift <= '0;
      mailbox_request_shift <= '0;
      mailbox_tx_shift <= '0;
      read_sample_seen <= 1'b0;
      request_operation <= '0;
      request_address <= '0;
      request_wdata <= '0;
      request_expected_crc <= '0;
      response_valid <= 1'b0;
      response_status <= RESPONSE_EMPTY;
      response_operation <= '0;
      response_address <= '0;
      response_data <= '0;
      spi_miso <= 1'b0;
      spi_error <= 1'b0;
      bus_valid <= 1'b0;
      bus_write <= 1'b0;
      bus_address <= '0;
      bus_wdata <= '0;
      cmd_valid <= 1'b0;
      cmd_data <= '0;
      stream_declared_words <= '0;
      stream_received_words <= '0;
      stream_command_words_remaining <= '0;
      stream_expected_crc <= '0;
      stream_crc <= '0;
      stream_reject <= 1'b0;
      commit_index <= '0;
      commit_words <= '0;
    end else begin
      if (bus_valid && bus_ready) begin
        bus_valid <= 1'b0;
        response_valid <= 1'b1;
        response_status <= bus_error ? RESPONSE_BUS_ERROR : RESPONSE_OK;
        response_operation <= bus_write ? REGISTER_WRITE : REGISTER_READ;
        response_address <= bus_address;
        response_data <= (!bus_write && !bus_error) ? bus_rdata : 32'd0;
        spi_error <= spi_error || bus_error;
      end

      if (cmd_valid && cmd_ready) begin
        if ((8'(commit_index) + 8'd1) >= commit_words) begin
          cmd_valid <= 1'b0;
        end else begin
          commit_index <= commit_index + 1'b1;
          cmd_data <= command_staging[commit_index + 1'b1];
        end
      end

      if (cs_end) begin
        if (state == STATE_MAILBOX_REQUEST_WAIT) begin
          if (!bus_valid) begin
            response_valid <= 1'b0;
            if (((request_operation == REGISTER_READ) ||
                 (request_operation == REGISTER_WRITE)) &&
                (!CHECK_REGISTER_CRC ||
                 (request_expected_crc == register_frame_crc32(
                     MAILBOX_REQUEST_OPCODE, request_operation,
                     request_address, request_wdata)))) begin
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
              !cmd_valid) begin
            commit_index <= '0;
            commit_words <= stream_received_words;
            cmd_data <= command_staging[0];
            cmd_valid <= 1'b1;
          end else begin
            spi_error <= 1'b1;
          end
        end else if ((state != STATE_FETCH_WAIT) &&
                     !((state == STATE_COMMAND) && (bit_count == 0))) begin
          if (!bus_valid && ((state == STATE_MAILBOX_REQUEST) ||
                             (state == STATE_MAILBOX_REQUEST_WAIT)))
            response_valid <= 1'b0;
          spi_error <= 1'b1;
        end
        state <= STATE_IDLE;
        bit_count <= '0;
        spi_miso <= 1'b0;
      end else if (!cs_active) begin
        state <= STATE_IDLE;
        bit_count <= '0;
        spi_miso <= 1'b0;
      end else if (cs_start) begin
        state <= STATE_COMMAND;
        command_shift <= '0;
        bit_count <= '0;
        data_shift <= '0;
        mailbox_request_shift <= '0;
        read_sample_seen <= 1'b0;
        spi_miso <= 1'b0;
        spi_error <= 1'b0;
        stream_declared_words <= '0;
        stream_received_words <= '0;
        stream_command_words_remaining <= '0;
        stream_expected_crc <= '0;
        stream_crc <= '0;
        stream_reject <= 1'b0;
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
                  MAILBOX_REQUEST_OPCODE: state <= STATE_MAILBOX_REQUEST;
                  MAILBOX_FETCH_OPCODE: state <= STATE_FETCH_HEADER;
                  COMMAND_STREAM_OPCODE: state <= STATE_STREAM_HEADER;
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

          STATE_FETCH_HEADER: begin
            if (sclk_rise) begin
              data_shift <= {data_shift[29:0], mosi_sync[1]};
              if (bit_count == 7'd23) begin
                if ({data_shift[22:0], mosi_sync[1]} != 24'd0)
                  spi_error <= 1'b1;
                spi_miso <= fetch_frame[95];
                mailbox_tx_shift <= fetch_frame[94:0];
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
                spi_miso <= 1'b0;
                state <= STATE_FETCH_WAIT;
              end else begin
                spi_miso <= mailbox_tx_shift[94];
                mailbox_tx_shift <= {mailbox_tx_shift[93:0], 1'b0};
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
                stream_reject <= cmd_valid ||
                    (data_shift[22:15] == 0) ||
                    (data_shift[22:15] > 8'(MAX_COMMAND_WORDS));
                if (cmd_valid ||
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
              if (bit_count == 7'd31) begin
                bit_count <= '0;
                if (!stream_reject &&
                    (stream_received_words < stream_declared_words) &&
                    (stream_received_words < 8'(MAX_COMMAND_WORDS))) begin
                  command_staging[stream_received_words[COMMAND_INDEX_WIDTH-1:0]] <=
                      {data_shift[30:0], mosi_sync[1]};
                end
                stream_crc <= crc16_ccitt_word(
                    stream_crc, {data_shift[30:0], mosi_sync[1]});
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

          STATE_REJECT: begin
          end

          default: state <= STATE_IDLE;
        endcase
      end
    end
  end
endmodule
