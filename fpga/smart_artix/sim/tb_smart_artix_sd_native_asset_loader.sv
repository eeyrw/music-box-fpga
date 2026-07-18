module tb_smart_artix_sd_native_asset_loader;
  localparam int LBA_WIDTH = 32;
  localparam int BEAT_BYTES = smart_artix_pkg::MIG_MASK_WIDTH;

  logic clk;
  logic rst;
  logic start;
  logic ddr_init_calib_complete;
  logic busy;
  logic asset_loaded;
  logic sd_initialized;
  logic [3:0] status_state;
  logic [7:0] sd_error_code;
  logic [7:0] loader_error_code;
  logic [31:0] bytes_loaded;
  logic [31:0] sf2_size_bytes;
  logic [LBA_WIDTH-1:0] current_lba;
  logic sd_cmd_valid;
  logic sd_cmd_ready;
  logic [5:0] sd_cmd_index;
  logic [31:0] sd_cmd_arg;
  logic [1:0] sd_cmd_resp_type;
  logic sd_cmd_data_read;
  logic [15:0] sd_cmd_block_len;
  logic [15:0] sd_cmd_block_count;
  logic sd_rsp_valid;
  logic [2:0] sd_rsp_status;
  logic [119:0] sd_rsp_data;
  logic sd_data_valid;
  logic sd_data_ready;
  logic [7:0] sd_data;
  logic sd_data_last;
  logic [2:0] sd_data_status;
  smart_artix_pkg::mig_app_command_t mig_app_command;
  smart_artix_pkg::mig_app_write_data_t mig_app_write_data;
  smart_artix_pkg::mig_app_response_t mig_app_response;
  logic [7:0] illegal_command_count;
  logic [31:0] last_read_lba;
  logic selected;
  logic wide_bus;
  int errors;
  int byte_index;

  smart_artix_sd_native_asset_loader #(
    .LBA_WIDTH(LBA_WIDTH)
  ) dut (
    .clk,
    .rst,
    .start,
    .ddr_init_calib_complete,
    .busy,
    .asset_loaded,
    .sd_initialized,
    .status_state,
    .sd_error_code,
    .loader_error_code,
    .bytes_loaded,
    .sf2_size_bytes,
    .current_lba,
    .sd_cmd_valid,
    .sd_cmd_ready,
    .sd_cmd_index,
    .sd_cmd_arg,
    .sd_cmd_resp_type,
    .sd_cmd_data_read,
    .sd_cmd_block_len,
    .sd_cmd_block_count,
    .sd_rsp_valid,
    .sd_rsp_status,
    .sd_rsp_data,
    .sd_data_valid,
    .sd_data_ready,
    .sd_data,
    .sd_data_last,
    .sd_data_status,
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );

  fake_sd_native_phy_model #(
    .DATA_DELAY_CYCLES(1),
    .INIT_BUSY_RESPONSES(1)
  ) sd_model (
    .clk,
    .rst,
    .cmd_valid(sd_cmd_valid),
    .cmd_ready(sd_cmd_ready),
    .cmd_index(sd_cmd_index),
    .cmd_arg(sd_cmd_arg),
    .cmd_resp_type(sd_cmd_resp_type),
    .cmd_data_read(sd_cmd_data_read),
    .cmd_block_len(sd_cmd_block_len),
    .cmd_block_count(sd_cmd_block_count),
    .rsp_valid(sd_rsp_valid),
    .rsp_status(sd_rsp_status),
    .rsp_data(sd_rsp_data),
    .data_valid(sd_data_valid),
    .data_ready(sd_data_ready),
    .data(sd_data),
    .data_last(sd_data_last),
    .data_status(sd_data_status),
    .illegal_command_count,
    .last_read_lba,
    .selected,
    .wide_bus
  );

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
/* verilator lint_on BLKSEQ */

/* verilator lint_off BLKSEQ */
  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask
/* verilator lint_on BLKSEQ */

  function automatic logic [7:0] expected_byte(input logic [15:0] index);
    logic [31:0] lba;
    logic [15:0] byte_offset;
    begin
      lba = 32'd7;
      byte_offset = index;
      expected_byte = lba[7:0] ^ lba[15:8] ^ lba[23:16] ^ lba[31:24]
          ^ byte_offset[7:0] ^ byte_offset[15:8];
    end
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      byte_index <= 0;
    end else if (mig_app_command.en && mig_app_response.rdy) begin
      check(mig_app_command.cmd == 3'b000, "native asset loader emitted non-write MIG command");
      check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(byte_index),
            "native asset loader MIG address mismatch");
      check(mig_app_write_data.wren && mig_app_write_data.end_,
            "native asset loader missing write-data beat");
      for (int i = 0; i < BEAT_BYTES; i++) begin
        if (byte_index + i < 20) begin
          check(!mig_app_write_data.mask[i], "native asset loader masked valid byte");
          check(mig_app_write_data.data[i * 8 +: 8] == expected_byte(16'(byte_index + i)),
                "native asset loader write data mismatch");
        end else begin
          check(mig_app_write_data.mask[i], "native asset loader did not mask padding byte");
        end
      end
      byte_index <= byte_index + BEAT_BYTES;
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    start = 1'b0;
    ddr_init_calib_complete = 1'b0;
    mig_app_response = '0;
    mig_app_response.rdy = 1'b1;
    mig_app_response.wdf_rdy = 1'b1;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    start = 1'b1;
    ddr_init_calib_complete = 1'b1;
    @(negedge clk);
    start = 1'b0;

    wait (asset_loaded || loader_error_code != 8'd0 || sd_error_code != 8'd0);
    repeat (2) @(posedge clk);

    check(asset_loaded, "native asset loader did not complete from one start pulse");
    check(sd_initialized, "native asset loader did not initialize SD card");
    check(wide_bus, "native asset loader did not switch SD card to 4-bit mode");
    check(illegal_command_count == 8'd0, "native asset loader sent illegal SD command");
    check(sd_error_code == 8'd0, "native asset loader reported SD error");
    check(loader_error_code == 8'd0, "native asset loader reported loader error");
    check(bytes_loaded == 32'd20, "native asset loader bytes_loaded mismatch");
    check(sf2_size_bytes == 32'd20, "native asset loader sf2_size_bytes mismatch");
    check(current_lba == 32'd7, "native asset loader current_lba mismatch");
    check(byte_index == 32, "native asset loader did not emit expected MIG beats");
    check(!busy, "native asset loader stayed busy after load");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_native_asset_loader errors=%0d", errors);

    $display("PASS: smart_artix_sd_native_asset_loader");
    $finish;
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_status;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_status = (^status_state) ^ (^last_read_lba) ^ selected;
endmodule
