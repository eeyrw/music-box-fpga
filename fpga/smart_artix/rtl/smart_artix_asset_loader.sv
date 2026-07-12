module smart_artix_asset_loader #(
  parameter int LBA_WIDTH = 32
) (
  input  logic                clk,
  input  logic                rst,

  input  logic                start,
  input  logic                ddr_init_calib_complete,
  output logic                busy,
  output logic                asset_loaded,
  output logic [3:0]          status_state,
  output logic [7:0]          error_code,
  output logic [63:0]         bytes_loaded,
  output logic [63:0]         sf2_size_bytes,
  output logic [LBA_WIDTH-1:0] current_lba,

  output logic                sd_req_valid,
  input  logic                sd_req_ready,
  output logic [LBA_WIDTH-1:0] sd_req_lba,
  input  logic                sd_byte_valid,
  output logic                sd_byte_ready,
  input  logic [7:0]          sd_byte_data,
  input  logic                sd_byte_last,

  output logic                writer_start,
  output logic [63:0]         writer_base_byte_addr,
  output logic [63:0]         writer_total_bytes,
  output logic                writer_byte_valid,
  input  logic                writer_byte_ready,
  output logic [7:0]          writer_byte_data,
  input  logic                writer_busy,
  input  logic                writer_done_pulse,
  input  logic                writer_error_pulse
);
  localparam logic [31:0] IMAGE_MAGIC = 32'h4653_5457; // "WTSF" little-endian.
  localparam logic [31:0] IMAGE_VERSION = 32'd1;

  localparam logic [3:0] STATUS_IDLE = 4'd0;
  localparam logic [3:0] STATUS_DDR_CALIBRATING = 4'd1;
  localparam logic [3:0] STATUS_READING_HEADER = 4'd2;
  localparam logic [3:0] STATUS_LOADING_SF2 = 4'd3;
  localparam logic [3:0] STATUS_VERIFYING = 4'd4;
  localparam logic [3:0] STATUS_LOADED = 4'd5;
  localparam logic [3:0] STATUS_ERROR = 4'd15;

  localparam logic [7:0] ERROR_NONE = 8'd0;
  localparam logic [7:0] ERROR_BAD_MAGIC = 8'd1;
  localparam logic [7:0] ERROR_BAD_VERSION = 8'd2;
  localparam logic [7:0] ERROR_EMPTY_IMAGE = 8'd3;
  localparam logic [7:0] ERROR_WRITER = 8'd4;
  localparam logic [7:0] ERROR_LBA_RANGE = 8'd5;

  typedef enum logic [3:0] {
    STATE_IDLE,
    STATE_WAIT_DDR,
    STATE_REQ_HEADER,
    STATE_READ_HEADER,
    STATE_START_WRITER,
    STATE_REQ_DATA,
    STATE_STREAM_DATA,
    STATE_WAIT_WRITER,
    STATE_DONE,
    STATE_ERROR
  } state_t;

  state_t state;
  logic [8:0] sector_byte_index;
  logic [31:0] header_magic;
  logic [31:0] header_version;
  logic [63:0] header_sf2_start_lba;
  logic [63:0] header_sf2_size_bytes;
  logic [63:0] header_ddr_base_byte_addr;
  logic [63:0] data_bytes_remaining;
  logic writer_byte_accepted;

  assign busy = (state != STATE_IDLE) && (state != STATE_DONE) && (state != STATE_ERROR);
  assign sd_req_valid = (state == STATE_REQ_HEADER) || (state == STATE_REQ_DATA);
  assign sd_req_lba = (state == STATE_REQ_HEADER) ? LBA_WIDTH'(0) : current_lba;
  assign sd_byte_ready = (state == STATE_READ_HEADER) ? 1'b1
      : (state == STATE_STREAM_DATA) ? ((data_bytes_remaining == 64'd0) ? 1'b1 : writer_byte_ready)
      : 1'b0;
  assign writer_start = state == STATE_START_WRITER;
  assign writer_base_byte_addr = header_ddr_base_byte_addr;
  assign writer_total_bytes = header_sf2_size_bytes;
  assign writer_byte_valid = (state == STATE_STREAM_DATA) && sd_byte_valid
      && (data_bytes_remaining != 64'd0);
  assign writer_byte_data = sd_byte_data;
  assign writer_byte_accepted = writer_byte_valid && writer_byte_ready;

  always_comb begin
    unique case (state)
      STATE_IDLE: status_state = asset_loaded ? STATUS_LOADED : STATUS_IDLE;
      STATE_WAIT_DDR: status_state = STATUS_DDR_CALIBRATING;
      STATE_REQ_HEADER,
      STATE_READ_HEADER: status_state = STATUS_READING_HEADER;
      STATE_START_WRITER,
      STATE_REQ_DATA,
      STATE_STREAM_DATA: status_state = STATUS_LOADING_SF2;
      STATE_WAIT_WRITER: status_state = STATUS_VERIFYING;
      STATE_DONE: status_state = STATUS_LOADED;
      default: status_state = STATUS_ERROR;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      asset_loaded <= 1'b0;
      error_code <= ERROR_NONE;
      bytes_loaded <= '0;
      sf2_size_bytes <= '0;
      current_lba <= '0;
      sector_byte_index <= '0;
      header_magic <= '0;
      header_version <= '0;
      header_sf2_start_lba <= '0;
      header_sf2_size_bytes <= '0;
      header_ddr_base_byte_addr <= '0;
      data_bytes_remaining <= '0;
    end else begin
      if (writer_error_pulse) begin
        error_code <= ERROR_WRITER;
        asset_loaded <= 1'b0;
        state <= STATE_ERROR;
      end else begin
        unique case (state)
          STATE_IDLE: begin
            if (start) begin
              asset_loaded <= 1'b0;
              error_code <= ERROR_NONE;
              bytes_loaded <= '0;
              sf2_size_bytes <= '0;
              current_lba <= '0;
              sector_byte_index <= '0;
              header_magic <= '0;
              header_version <= '0;
              header_sf2_start_lba <= '0;
              header_sf2_size_bytes <= '0;
              header_ddr_base_byte_addr <= '0;
              data_bytes_remaining <= '0;
              state <= ddr_init_calib_complete ? STATE_REQ_HEADER : STATE_WAIT_DDR;
            end
          end

          STATE_WAIT_DDR: begin
            if (ddr_init_calib_complete)
              state <= STATE_REQ_HEADER;
          end

          STATE_REQ_HEADER: begin
            if (sd_req_ready) begin
              sector_byte_index <= '0;
              state <= STATE_READ_HEADER;
            end
          end

          STATE_READ_HEADER: begin
            if (sd_byte_valid) begin
              unique case (sector_byte_index)
                9'h000: header_magic[7:0] <= sd_byte_data;
                9'h001: header_magic[15:8] <= sd_byte_data;
                9'h002: header_magic[23:16] <= sd_byte_data;
                9'h003: header_magic[31:24] <= sd_byte_data;
                9'h004: header_version[7:0] <= sd_byte_data;
                9'h005: header_version[15:8] <= sd_byte_data;
                9'h006: header_version[23:16] <= sd_byte_data;
                9'h007: header_version[31:24] <= sd_byte_data;
                9'h010: header_sf2_start_lba[7:0] <= sd_byte_data;
                9'h011: header_sf2_start_lba[15:8] <= sd_byte_data;
                9'h012: header_sf2_start_lba[23:16] <= sd_byte_data;
                9'h013: header_sf2_start_lba[31:24] <= sd_byte_data;
                9'h014: header_sf2_start_lba[39:32] <= sd_byte_data;
                9'h015: header_sf2_start_lba[47:40] <= sd_byte_data;
                9'h016: header_sf2_start_lba[55:48] <= sd_byte_data;
                9'h017: header_sf2_start_lba[63:56] <= sd_byte_data;
                9'h018: header_sf2_size_bytes[7:0] <= sd_byte_data;
                9'h019: header_sf2_size_bytes[15:8] <= sd_byte_data;
                9'h01a: header_sf2_size_bytes[23:16] <= sd_byte_data;
                9'h01b: header_sf2_size_bytes[31:24] <= sd_byte_data;
                9'h01c: header_sf2_size_bytes[39:32] <= sd_byte_data;
                9'h01d: header_sf2_size_bytes[47:40] <= sd_byte_data;
                9'h01e: header_sf2_size_bytes[55:48] <= sd_byte_data;
                9'h01f: header_sf2_size_bytes[63:56] <= sd_byte_data;
                9'h020: header_ddr_base_byte_addr[7:0] <= sd_byte_data;
                9'h021: header_ddr_base_byte_addr[15:8] <= sd_byte_data;
                9'h022: header_ddr_base_byte_addr[23:16] <= sd_byte_data;
                9'h023: header_ddr_base_byte_addr[31:24] <= sd_byte_data;
                9'h024: header_ddr_base_byte_addr[39:32] <= sd_byte_data;
                9'h025: header_ddr_base_byte_addr[47:40] <= sd_byte_data;
                9'h026: header_ddr_base_byte_addr[55:48] <= sd_byte_data;
                9'h027: header_ddr_base_byte_addr[63:56] <= sd_byte_data;
                default: ;
              endcase

              sector_byte_index <= sector_byte_index + 9'd1;
              if (sd_byte_last) begin
                if (header_magic != IMAGE_MAGIC) begin
                  error_code <= ERROR_BAD_MAGIC;
                  state <= STATE_ERROR;
                end else if (header_version != IMAGE_VERSION) begin
                  error_code <= ERROR_BAD_VERSION;
                  state <= STATE_ERROR;
                end else if (header_sf2_size_bytes == 64'd0) begin
                  error_code <= ERROR_EMPTY_IMAGE;
                  state <= STATE_ERROR;
                end else if (header_sf2_start_lba[63:LBA_WIDTH] != '0) begin
                  error_code <= ERROR_LBA_RANGE;
                  state <= STATE_ERROR;
                end else begin
                  sf2_size_bytes <= header_sf2_size_bytes;
                  data_bytes_remaining <= header_sf2_size_bytes;
                  current_lba <= LBA_WIDTH'(header_sf2_start_lba);
                  state <= STATE_START_WRITER;
                end
              end
            end
          end

          STATE_START_WRITER: begin
            state <= STATE_REQ_DATA;
          end

          STATE_REQ_DATA: begin
            if (sd_req_ready) begin
              sector_byte_index <= '0;
              state <= STATE_STREAM_DATA;
            end
          end

          STATE_STREAM_DATA: begin
            if (sd_byte_valid && sd_byte_ready) begin
              sector_byte_index <= sector_byte_index + 9'd1;
              if (writer_byte_accepted) begin
                data_bytes_remaining <= data_bytes_remaining - 64'd1;
                bytes_loaded <= bytes_loaded + 64'd1;
              end

              if (sd_byte_last) begin
                if (data_bytes_remaining == (writer_byte_accepted ? 64'd1 : 64'd0))
                  state <= STATE_WAIT_WRITER;
                else begin
                  current_lba <= current_lba + LBA_WIDTH'(1);
                  state <= STATE_REQ_DATA;
                end
              end
            end
          end

          STATE_WAIT_WRITER: begin
            if (writer_done_pulse || !writer_busy) begin
              asset_loaded <= 1'b1;
              state <= STATE_DONE;
            end
          end

          STATE_DONE: begin
            if (start) begin
              asset_loaded <= 1'b0;
              bytes_loaded <= '0;
              state <= ddr_init_calib_complete ? STATE_REQ_HEADER : STATE_WAIT_DDR;
            end
          end

          STATE_ERROR: begin
            if (start) begin
              asset_loaded <= 1'b0;
              error_code <= ERROR_NONE;
              bytes_loaded <= '0;
              state <= ddr_init_calib_complete ? STATE_REQ_HEADER : STATE_WAIT_DDR;
            end
          end

          default: state <= STATE_ERROR;
        endcase
      end
    end
  end
endmodule
