module tb_smart_artix_asset_loader;
  localparam int LBA_WIDTH = 32;

  logic clk;
  logic rst;
  logic start;
  logic ddr_init_calib_complete;
  logic busy;
  logic asset_loaded;
  logic [3:0] status_state;
  logic [7:0] error_code;
  logic [31:0] bytes_loaded;
  logic [31:0] sf2_size_bytes;
  logic [LBA_WIDTH-1:0] current_lba;
  logic sd_req_valid;
  logic sd_req_ready;
  logic [LBA_WIDTH-1:0] sd_req_lba;
  logic sd_byte_valid;
  logic sd_byte_ready;
  logic [7:0] sd_byte_data;
  logic sd_byte_last;
  logic writer_start;
  logic [63:0] writer_base_byte_addr;
  logic [31:0] writer_total_bytes;
  logic writer_byte_valid;
  logic writer_byte_ready;
  logic [7:0] writer_byte_data;
  logic writer_busy;
  logic writer_done_pulse;
  logic writer_error_pulse;
  int errors;
  int writer_bytes_seen;

  smart_artix_asset_loader #(.LBA_WIDTH(LBA_WIDTH)) dut (
    .clk,
    .rst,
    .start,
    .ddr_init_calib_complete,
    .busy,
    .asset_loaded,
    .status_state,
    .error_code,
    .bytes_loaded,
    .sf2_size_bytes,
    .current_lba,
    .sd_req_valid,
    .sd_req_ready,
    .sd_req_lba,
    .sd_byte_valid,
    .sd_byte_ready,
    .sd_byte_data,
    .sd_byte_last,
    .writer_start,
    .writer_base_byte_addr,
    .writer_total_bytes,
    .writer_byte_valid,
    .writer_byte_ready,
    .writer_byte_data,
    .writer_busy,
    .writer_done_pulse,
    .writer_error_pulse
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

  function automatic logic [7:0] header_byte(input int index);
    logic [63:0] sf2_lba;
    logic [31:0] sf2_size;
    logic [63:0] ddr_base;
    begin
      sf2_lba = 64'd7;
      sf2_size = 32'd20;
      ddr_base = 64'h40;
      header_byte = 8'd0;
      unique case (index)
        0: header_byte = "W";
        1: header_byte = "T";
        2: header_byte = "S";
        3: header_byte = "F";
        4: header_byte = 8'd1;
        16,17,18,19,20,21,22,23: header_byte = sf2_lba[(index - 16) * 8 +: 8];
        24,25,26,27: header_byte = sf2_size[(index - 24) * 8 +: 8];
        32,33,34,35,36,37,38,39: header_byte = ddr_base[(index - 32) * 8 +: 8];
        default: header_byte = 8'd0;
      endcase
    end
  endfunction

  task automatic accept_request(input logic [LBA_WIDTH-1:0] expected_lba);
    begin
      wait (sd_req_valid);
      @(negedge clk);
      check(sd_req_lba == expected_lba, "SD request LBA mismatch");
      sd_req_ready = 1'b1;
      @(negedge clk);
      sd_req_ready = 1'b0;
    end
  endtask

  task automatic send_header_sector;
    begin
      accept_request(32'd0);
      for (int i = 0; i < 512; i++) begin
        @(negedge clk);
        sd_byte_data = header_byte(i);
        sd_byte_last = i == 511;
        sd_byte_valid = 1'b1;
        wait (sd_byte_ready);
      end
      @(negedge clk);
      sd_byte_valid = 1'b0;
      sd_byte_last = 1'b0;
    end
  endtask

  task automatic send_data_sector(input logic [LBA_WIDTH-1:0] expected_lba);
    begin
      accept_request(expected_lba);
      for (int i = 0; i < 512; i++) begin
        @(negedge clk);
        sd_byte_data = 8'(i);
        sd_byte_last = i == 511;
        sd_byte_valid = 1'b1;
        wait (sd_byte_ready);
      end
      @(negedge clk);
      sd_byte_valid = 1'b0;
      sd_byte_last = 1'b0;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      writer_busy <= 1'b0;
      writer_done_pulse <= 1'b0;
      writer_bytes_seen <= 0;
    end else begin
      writer_done_pulse <= 1'b0;
      if (writer_start) begin
        writer_busy <= 1'b1;
        check(writer_base_byte_addr == 64'h40, "writer base byte address mismatch");
        check(writer_total_bytes == 32'd20, "writer total byte count mismatch");
      end
      if (writer_byte_valid && writer_byte_ready) begin
        check(writer_byte_data == 8'(writer_bytes_seen), "writer byte data mismatch");
        writer_bytes_seen <= writer_bytes_seen + 1;
        if (writer_bytes_seen == 19) begin
          writer_done_pulse <= 1'b1;
          writer_busy <= 1'b0;
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    start = 1'b0;
    ddr_init_calib_complete = 1'b0;
    sd_req_ready = 1'b0;
    sd_byte_valid = 1'b0;
    sd_byte_data = 8'd0;
    sd_byte_last = 1'b0;
    writer_byte_ready = 1'b1;
    writer_error_pulse = 1'b0;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;
    repeat (2) @(posedge clk);
    check(status_state == 4'd1, "loader did not wait for DDR calibration");

    ddr_init_calib_complete = 1'b1;
    send_header_sector();
    send_data_sector(32'd7);

    wait (asset_loaded);
    @(posedge clk);
    check(!busy, "loader stayed busy after asset_loaded");
    check(error_code == 8'd0, "loader reported unexpected error");
    check(bytes_loaded == 32'd20, "loader bytes_loaded mismatch");
    check(sf2_size_bytes == 32'd20, "loader sf2_size_bytes mismatch");
    check(current_lba == 32'd7, "loader current_lba mismatch");
    check(writer_bytes_seen == 20, "loader did not stream expected writer bytes");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_asset_loader errors=%0d", errors);

    $display("PASS: smart_artix_asset_loader");
    $finish;
  end
endmodule
