module smart_artix_fat_file_reader #(
  parameter int LBA_WIDTH = 32,
  parameter logic [87:0] TARGET_NAME_11 = "MT6276  SF2"
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic                 start,
  output logic                 busy,
  output logic                 file_found,
  output logic                 done,
  output logic [3:0]           status_state,
  output logic [7:0]           error_code,
  output logic [31:0]          file_size_bytes,
  output logic [31:0]          bytes_read,
  output logic [LBA_WIDTH-1:0] current_lba,

  output logic                 sd_req_valid,
  input  logic                 sd_req_ready,
  output logic [LBA_WIDTH-1:0] sd_req_lba,
  input  logic                 sd_byte_valid,
  output logic                 sd_byte_ready,
  input  logic [7:0]           sd_byte_data,
  input  logic                 sd_byte_last,

  output logic                 file_byte_valid,
  input  logic                 file_byte_ready,
  output logic [7:0]           file_byte_data,
  output logic                 file_byte_last
);
  localparam logic [3:0] STATUS_IDLE = 4'd0;
  localparam logic [3:0] STATUS_READING_BOOT = 4'd1;
  localparam logic [3:0] STATUS_SCANNING_DIR = 4'd2;
  localparam logic [3:0] STATUS_READING_FILE = 4'd3;
  localparam logic [3:0] STATUS_DONE = 4'd4;
  localparam logic [3:0] STATUS_ERROR = 4'd15;

  localparam logic [7:0] ERROR_NONE = 8'd0;
  localparam logic [7:0] ERROR_BAD_BOOT = 8'd1;
  localparam logic [7:0] ERROR_UNSUPPORTED_BPB = 8'd2;
  localparam logic [7:0] ERROR_FILE_NOT_FOUND = 8'd3;
  localparam logic [7:0] ERROR_BAD_CLUSTER = 8'd4;
  localparam logic [7:0] ERROR_LBA_RANGE = 8'd5;

  typedef enum logic [3:0] {
    STATE_IDLE,
    STATE_REQ_SECTOR,
    STATE_READ_SECTOR,
    STATE_PARSE_MBR,
    STATE_PARSE_BOOT,
    STATE_SCAN_DIR,
    STATE_EMIT_FILE,
    STATE_DONE,
    STATE_ERROR
  } state_t;

  typedef enum logic [2:0] {
    CTX_MBR,
    CTX_BOOT,
    CTX_DIR,
    CTX_FILE,
    CTX_DIR_FAT,
    CTX_FILE_FAT
  } context_t;

  state_t state;
  context_t read_context;
  logic [7:0] sector_buf [0:511];
  logic [8:0] sector_byte_index;
  logic [8:0] emit_index;
  logic [3:0] dir_entry_index;
  logic [LBA_WIDTH-1:0] request_lba;
  logic [LBA_WIDTH-1:0] boot_lba;
  logic [LBA_WIDTH-1:0] first_fat_lba;
  logic [LBA_WIDTH-1:0] data_start_lba;
  logic [LBA_WIDTH-1:0] root_dir_lba;
  logic fat32;
  logic [7:0] sectors_per_cluster;
  logic [15:0] root_dir_sectors;
  logic [31:0] root_cluster;
  logic [31:0] dir_cluster;
  logic [31:0] file_cluster;
  logic [31:0] file_bytes_remaining;
  logic [7:0] cluster_sector_offset;
  logic [15:0] fixed_root_sector_offset;
  logic [8:0] fat_entry_offset;
  logic entry_matches;
  logic entry_is_file;
  logic [31:0] entry_cluster;
  logic [31:0] entry_size;
  logic [31:0] next_cluster_value;

  assign busy = state != STATE_IDLE && state != STATE_DONE && state != STATE_ERROR;
  assign done = state == STATE_DONE;
  assign sd_req_valid = state == STATE_REQ_SECTOR;
  assign sd_req_lba = request_lba;
  assign sd_byte_ready = state == STATE_READ_SECTOR;
  assign file_byte_valid = state == STATE_EMIT_FILE && file_bytes_remaining != 32'd0;
  assign file_byte_data = sector_buf[emit_index];
  assign file_byte_last = file_byte_valid && file_bytes_remaining == 32'd1;

  always_comb begin
    unique case (state)
      STATE_IDLE: status_state = STATUS_IDLE;
      STATE_REQ_SECTOR,
      STATE_READ_SECTOR,
      STATE_PARSE_MBR,
      STATE_PARSE_BOOT: status_state = STATUS_READING_BOOT;
      STATE_SCAN_DIR: status_state = STATUS_SCANNING_DIR;
      STATE_EMIT_FILE: status_state = STATUS_READING_FILE;
      STATE_DONE: status_state = STATUS_DONE;
      default: status_state = STATUS_ERROR;
    endcase
  end

  function automatic logic [15:0] le16(input logic [8:0] index);
    begin
      le16 = {sector_buf[index + 1], sector_buf[index]};
    end
  endfunction

  function automatic logic [31:0] le32(input logic [8:0] index);
    begin
      le32 = {sector_buf[index + 3], sector_buf[index + 2], sector_buf[index + 1], sector_buf[index]};
    end
  endfunction

  function automatic logic boot_signature_ok();
    begin
      boot_signature_ok = sector_buf[510] == 8'h55 && sector_buf[511] == 8'haa;
    end
  endfunction

  function automatic logic looks_like_boot_sector();
    begin
      looks_like_boot_sector = boot_signature_ok()
          && (sector_buf[0] == 8'heb || sector_buf[0] == 8'he9);
    end
  endfunction

  function automatic logic is_eoc(input logic [31:0] cluster);
    begin
      is_eoc = fat32 ? ((cluster & 32'h0fff_ffff) >= 32'h0fff_fff8) : (cluster >= 32'h0000_fff8);
    end
  endfunction

  function automatic logic [31:0] cluster_entry(input int base_index);
    begin
      cluster_entry = {le16(9'(base_index + 20)), le16(9'(base_index + 26))};
    end
  endfunction

  function automatic logic short_name_matches(input int base_index);
    logic match;
    begin
      match = 1'b1;
      for (int i = 0; i < 11; i++) begin
        if (sector_buf[base_index + i] != TARGET_NAME_11[(10 - i) * 8 +: 8])
          match = 1'b0;
      end
      short_name_matches = match;
    end
  endfunction

  function automatic logic [LBA_WIDTH:0] cluster_lba(input logic [31:0] cluster,
                                                     input logic [7:0] sector_offset);
    logic [LBA_WIDTH:0] cluster_offset;
    begin
      cluster_offset = {1'b0, LBA_WIDTH'(cluster - 32'd2)} * {1'b0, LBA_WIDTH'(sectors_per_cluster)};
      cluster_lba = {1'b0, data_start_lba} + cluster_offset + {1'b0, LBA_WIDTH'(sector_offset)};
    end
  endfunction

  function automatic logic [LBA_WIDTH:0] fat_lba(input logic [31:0] cluster);
    begin
      fat_lba = {1'b0, first_fat_lba}
          + {1'b0, LBA_WIDTH'(fat32 ? (cluster >> 7) : (cluster >> 8))};
    end
  endfunction

  task automatic request_sector(input logic [LBA_WIDTH:0] next_lba,
                                input context_t next_context);
    begin
      if (next_lba[LBA_WIDTH]) begin
        error_code <= ERROR_LBA_RANGE;
        state <= STATE_ERROR;
      end else begin
        request_lba <= next_lba[LBA_WIDTH-1:0];
        current_lba <= next_lba[LBA_WIDTH-1:0];
        read_context <= next_context;
        sector_byte_index <= '0;
        state <= STATE_REQ_SECTOR;
      end
    end
  endtask

  task automatic lookup_next_cluster(input logic [31:0] cluster,
                                     input context_t next_context);
    begin
      fat_entry_offset <= fat32 ? {cluster[6:0], 2'b00} : {cluster[7:0], 1'b0};
      request_sector(fat_lba(cluster), next_context);
    end
  endtask

  always_comb begin
    entry_matches = short_name_matches(dir_entry_index * 32);
    entry_is_file = sector_buf[dir_entry_index * 32] != 8'h00
        && sector_buf[dir_entry_index * 32] != 8'he5
        && (sector_buf[dir_entry_index * 32 + 11] & 8'h08) == 8'h00
        && (sector_buf[dir_entry_index * 32 + 11] & 8'h10) == 8'h00
        && (sector_buf[dir_entry_index * 32 + 11] & 8'h0f) != 8'h0f;
    entry_cluster = cluster_entry(dir_entry_index * 32);
    entry_size = le32(9'(dir_entry_index * 32 + 28));

    if (fat32)
      next_cluster_value = le32(fat_entry_offset) & 32'h0fff_ffff;
    else
      next_cluster_value = {16'd0, le16(fat_entry_offset)};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      read_context <= CTX_MBR;
      sector_byte_index <= '0;
      emit_index <= '0;
      dir_entry_index <= '0;
      request_lba <= '0;
      boot_lba <= '0;
      first_fat_lba <= '0;
      data_start_lba <= '0;
      root_dir_lba <= '0;
      fat32 <= 1'b0;
      sectors_per_cluster <= '0;
      root_dir_sectors <= '0;
      root_cluster <= '0;
      dir_cluster <= '0;
      file_cluster <= '0;
      file_size_bytes <= '0;
      bytes_read <= '0;
      file_bytes_remaining <= '0;
      cluster_sector_offset <= '0;
      fixed_root_sector_offset <= '0;
      fat_entry_offset <= '0;
      file_found <= 1'b0;
      error_code <= ERROR_NONE;
      current_lba <= '0;
    end else begin
      unique case (state)
        STATE_IDLE: begin
          if (start) begin
            file_found <= 1'b0;
            error_code <= ERROR_NONE;
            file_size_bytes <= '0;
            bytes_read <= '0;
            file_bytes_remaining <= '0;
            request_sector({1'b0, LBA_WIDTH'(0)}, CTX_MBR);
          end
        end

        STATE_REQ_SECTOR: begin
          if (sd_req_ready) begin
            sector_byte_index <= '0;
            state <= STATE_READ_SECTOR;
          end
        end

        STATE_READ_SECTOR: begin
          if (sd_byte_valid) begin
            sector_buf[sector_byte_index] <= sd_byte_data;
            sector_byte_index <= sector_byte_index + 9'd1;
            if (sd_byte_last) begin
              unique case (read_context)
                CTX_MBR: state <= STATE_PARSE_MBR;
                CTX_BOOT: state <= STATE_PARSE_BOOT;
                CTX_DIR: begin
                  dir_entry_index <= '0;
                  state <= STATE_SCAN_DIR;
                end
                CTX_FILE: begin
                  emit_index <= '0;
                  state <= STATE_EMIT_FILE;
                end
                CTX_DIR_FAT: begin
                  if (is_eoc(next_cluster_value)) begin
                    error_code <= ERROR_FILE_NOT_FOUND;
                    state <= STATE_ERROR;
                  end else begin
                    dir_cluster <= next_cluster_value;
                    cluster_sector_offset <= '0;
                    request_sector(cluster_lba(next_cluster_value, 8'd0), CTX_DIR);
                  end
                end
                CTX_FILE_FAT: begin
                  if (is_eoc(next_cluster_value)) begin
                    error_code <= file_bytes_remaining == 32'd0 ? ERROR_NONE : ERROR_BAD_CLUSTER;
                    state <= file_bytes_remaining == 32'd0 ? STATE_DONE : STATE_ERROR;
                  end else begin
                    file_cluster <= next_cluster_value;
                    cluster_sector_offset <= '0;
                    request_sector(cluster_lba(next_cluster_value, 8'd0), CTX_FILE);
                  end
                end
                default: state <= STATE_ERROR;
              endcase
            end
          end
        end

        STATE_PARSE_MBR: begin
          if (looks_like_boot_sector()) begin
            boot_lba <= '0;
            state <= STATE_PARSE_BOOT;
          end else if (boot_signature_ok() && le32(9'h1c6) != 32'd0) begin
            boot_lba <= LBA_WIDTH'(le32(9'h1c6));
            request_sector({1'b0, LBA_WIDTH'(le32(9'h1c6))}, CTX_BOOT);
          end else begin
            error_code <= ERROR_BAD_BOOT;
            state <= STATE_ERROR;
          end
        end

        STATE_PARSE_BOOT: begin
          if (!looks_like_boot_sector()) begin
            error_code <= ERROR_BAD_BOOT;
            state <= STATE_ERROR;
          end else if (le16(9'h00b) != 16'd512 || sector_buf[9'h00d] == 8'd0
              || sector_buf[9'h010] == 8'd0) begin
            error_code <= ERROR_UNSUPPORTED_BPB;
            state <= STATE_ERROR;
          end else begin
            sectors_per_cluster <= sector_buf[9'h00d];
            first_fat_lba <= boot_lba + LBA_WIDTH'(le16(9'h00e));
            if (le16(9'h011) != 16'd0) begin
              fat32 <= 1'b0;
              root_dir_sectors <= 16'((32'(le16(9'h011)) + 32'd15) >> 4);
              root_dir_lba <= boot_lba + LBA_WIDTH'(le16(9'h00e))
                  + LBA_WIDTH'(sector_buf[9'h010]) * LBA_WIDTH'(le16(9'h016));
              data_start_lba <= boot_lba + LBA_WIDTH'(le16(9'h00e))
                  + LBA_WIDTH'(sector_buf[9'h010]) * LBA_WIDTH'(le16(9'h016))
                  + LBA_WIDTH'((32'(le16(9'h011)) + 32'd15) >> 4);
              fixed_root_sector_offset <= '0;
              request_sector({1'b0, boot_lba + LBA_WIDTH'(le16(9'h00e))
                  + LBA_WIDTH'(sector_buf[9'h010]) * LBA_WIDTH'(le16(9'h016))}, CTX_DIR);
            end else if (le32(9'h024) != 32'd0) begin
              fat32 <= 1'b1;
              root_dir_sectors <= '0;
              root_cluster <= le32(9'h02c);
              dir_cluster <= le32(9'h02c);
              data_start_lba <= boot_lba + LBA_WIDTH'(le16(9'h00e))
                  + LBA_WIDTH'(sector_buf[9'h010]) * LBA_WIDTH'(le32(9'h024));
              cluster_sector_offset <= '0;
              request_sector({1'b0, boot_lba + LBA_WIDTH'(le16(9'h00e))
                  + LBA_WIDTH'(sector_buf[9'h010]) * LBA_WIDTH'(le32(9'h024))
                  + LBA_WIDTH'((le32(9'h02c) - 32'd2) * sector_buf[9'h00d])}, CTX_DIR);
            end else begin
              error_code <= ERROR_UNSUPPORTED_BPB;
              state <= STATE_ERROR;
            end
          end
        end

        STATE_SCAN_DIR: begin
          if (sector_buf[dir_entry_index * 32] == 8'h00) begin
            error_code <= ERROR_FILE_NOT_FOUND;
            state <= STATE_ERROR;
          end else if (entry_is_file && entry_matches) begin
            file_found <= 1'b1;
            file_cluster <= entry_cluster;
            file_size_bytes <= entry_size;
            file_bytes_remaining <= entry_size;
            bytes_read <= '0;
            cluster_sector_offset <= '0;
            if (entry_size == 32'd0) begin
              state <= STATE_DONE;
            end else if (entry_cluster < 32'd2) begin
              error_code <= ERROR_BAD_CLUSTER;
              state <= STATE_ERROR;
            end else begin
              request_sector(cluster_lba(entry_cluster, 8'd0), CTX_FILE);
            end
          end else if (dir_entry_index != 4'd15) begin
            dir_entry_index <= dir_entry_index + 4'd1;
          end else if (!fat32) begin
            if (fixed_root_sector_offset + 16'd1 == root_dir_sectors) begin
              error_code <= ERROR_FILE_NOT_FOUND;
              state <= STATE_ERROR;
            end else begin
              fixed_root_sector_offset <= fixed_root_sector_offset + 16'd1;
              request_sector({1'b0, root_dir_lba + LBA_WIDTH'(32'(fixed_root_sector_offset) + 32'd1)}, CTX_DIR);
            end
          end else if (cluster_sector_offset + 8'd1 != sectors_per_cluster) begin
            cluster_sector_offset <= cluster_sector_offset + 8'd1;
            request_sector(cluster_lba(dir_cluster, cluster_sector_offset + 8'd1), CTX_DIR);
          end else begin
            lookup_next_cluster(dir_cluster, CTX_DIR_FAT);
          end
        end

        STATE_EMIT_FILE: begin
          if (file_byte_valid && file_byte_ready) begin
            emit_index <= emit_index + 9'd1;
            file_bytes_remaining <= file_bytes_remaining - 32'd1;
            bytes_read <= bytes_read + 32'd1;
            if (file_bytes_remaining == 32'd1) begin
              state <= STATE_DONE;
            end else if (emit_index == 9'd511) begin
              if (cluster_sector_offset + 8'd1 != sectors_per_cluster) begin
                cluster_sector_offset <= cluster_sector_offset + 8'd1;
                request_sector(cluster_lba(file_cluster, cluster_sector_offset + 8'd1), CTX_FILE);
              end else begin
                lookup_next_cluster(file_cluster, CTX_FILE_FAT);
              end
            end
          end
        end

        STATE_DONE: begin
          if (start)
            request_sector({1'b0, LBA_WIDTH'(0)}, CTX_MBR);
        end

        STATE_ERROR: begin
          if (start)
            request_sector({1'b0, LBA_WIDTH'(0)}, CTX_MBR);
        end

        default: state <= STATE_ERROR;
      endcase
    end
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_root_cluster;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_root_cluster = ^root_cluster;
endmodule
