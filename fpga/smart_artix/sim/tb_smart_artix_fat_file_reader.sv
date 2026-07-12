module tb_smart_artix_fat_file_reader;
  localparam int LBA_WIDTH = 32;

  logic clk;
  logic rst;
  logic start;
  logic busy;
  logic file_found;
  logic done;
  logic [3:0] status_state;
  logic [7:0] error_code;
  logic [31:0] file_size_bytes;
  logic [31:0] bytes_read;
  logic [LBA_WIDTH-1:0] current_lba;
  logic sd_req_valid;
  logic sd_req_ready;
  logic [LBA_WIDTH-1:0] sd_req_lba;
  logic sd_byte_valid;
  logic sd_byte_ready;
  logic [7:0] sd_byte_data;
  logic sd_byte_last;
  logic file_byte_valid;
  logic file_byte_ready;
  logic [7:0] file_byte_data;
  logic file_byte_last;
  int errors;
  int file_bytes_seen;

  smart_artix_fat_file_reader #(
    .LBA_WIDTH(LBA_WIDTH),
    .TARGET_NAME_11("MT6276  SF2")
  ) dut (
    .clk,
    .rst,
    .start,
    .busy,
    .file_found,
    .done,
    .status_state,
    .error_code,
    .file_size_bytes,
    .bytes_read,
    .current_lba,
    .sd_req_valid,
    .sd_req_ready,
    .sd_req_lba,
    .sd_byte_valid,
    .sd_byte_ready,
    .sd_byte_data,
    .sd_byte_last,
    .file_byte_valid,
    .file_byte_ready,
    .file_byte_data,
    .file_byte_last
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

  function automatic logic [7:0] fat32_image_byte(input logic [31:0] lba,
                                                  input int index);
    begin
      fat32_image_byte = 8'd0;
      unique case (lba)
        32'd0: begin
          unique case (index)
            0: fat32_image_byte = 8'heb;
            1: fat32_image_byte = 8'h58;
            2: fat32_image_byte = 8'h90;
            11: fat32_image_byte = 8'h00;
            12: fat32_image_byte = 8'h02;
            13: fat32_image_byte = 8'h01;
            14: fat32_image_byte = 8'h01;
            16: fat32_image_byte = 8'h01;
            36: fat32_image_byte = 8'h01;
            44: fat32_image_byte = 8'h02;
            510: fat32_image_byte = 8'h55;
            511: fat32_image_byte = 8'haa;
            default: fat32_image_byte = 8'd0;
          endcase
        end

        32'd1: begin
          unique case (index)
            8: fat32_image_byte = 8'hff;
            9: fat32_image_byte = 8'hff;
            10: fat32_image_byte = 8'hff;
            11: fat32_image_byte = 8'h0f;
            20: fat32_image_byte = 8'h06;
            24: fat32_image_byte = 8'hff;
            25: fat32_image_byte = 8'hff;
            26: fat32_image_byte = 8'hff;
            27: fat32_image_byte = 8'h0f;
            default: fat32_image_byte = 8'd0;
          endcase
        end

        32'd2: begin
          unique case (index)
            0: fat32_image_byte = "M";
            1: fat32_image_byte = "T";
            2: fat32_image_byte = "6";
            3: fat32_image_byte = "2";
            4: fat32_image_byte = "7";
            5: fat32_image_byte = "6";
            6: fat32_image_byte = " ";
            7: fat32_image_byte = " ";
            8: fat32_image_byte = "S";
            9: fat32_image_byte = "F";
            10: fat32_image_byte = "2";
            11: fat32_image_byte = 8'h20;
            26: fat32_image_byte = 8'h05;
            28: fat32_image_byte = 8'h08;
            29: fat32_image_byte = 8'h02;
            32: fat32_image_byte = 8'h00;
            default: fat32_image_byte = 8'd0;
          endcase
        end

        32'd5: fat32_image_byte = 8'(index[7:0]);
        32'd6: fat32_image_byte = 8'(index[7:0]) ^ 8'h80;
        default: fat32_image_byte = 8'd0;
      endcase
    end
  endfunction

  task automatic accept_request(input logic [LBA_WIDTH-1:0] expected_lba);
    begin
      wait (sd_req_valid);
      @(negedge clk);
      check(sd_req_lba == expected_lba, "FAT reader requested unexpected LBA");
      sd_req_ready = 1'b1;
      @(negedge clk);
      sd_req_ready = 1'b0;
    end
  endtask

  task automatic send_sector(input logic [LBA_WIDTH-1:0] expected_lba);
    begin
      accept_request(expected_lba);
      for (int i = 0; i < 512; i++) begin
        @(negedge clk);
        sd_byte_data = fat32_image_byte(expected_lba, i);
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
      file_bytes_seen <= 0;
    end else if (file_byte_valid && file_byte_ready) begin
      if (file_bytes_seen < 512)
        check(file_byte_data == 8'(file_bytes_seen[7:0]), "first FAT file cluster data mismatch");
      else
        check(file_byte_data == (8'(file_bytes_seen - 512) ^ 8'h80), "second FAT file cluster data mismatch");

      if (file_bytes_seen == 519)
        check(file_byte_last, "FAT reader did not mark final file byte");
      else
        check(!file_byte_last, "FAT reader marked early final file byte");
      file_bytes_seen <= file_bytes_seen + 1;
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    start = 1'b0;
    sd_req_ready = 1'b0;
    sd_byte_valid = 1'b0;
    sd_byte_data = 8'd0;
    sd_byte_last = 1'b0;
    file_byte_ready = 1'b1;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    send_sector(32'd0);
    send_sector(32'd2);
    send_sector(32'd5);
    send_sector(32'd1);
    send_sector(32'd6);

    wait (done);
    @(posedge clk);
    check(file_found, "FAT reader did not find target file");
    check(error_code == 8'd0, "FAT reader reported unexpected error");
    check(file_size_bytes == 32'd520, "FAT reader file size mismatch");
    check(bytes_read == 32'd520, "FAT reader bytes_read mismatch");
    check(file_bytes_seen == 520, "FAT reader emitted wrong byte count");
    check(!busy, "FAT reader stayed busy after done");
    check(status_state == 4'd4, "FAT reader status did not report done");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_fat_file_reader errors=%0d", errors);

    $display("PASS: smart_artix_fat_file_reader");
    $finish;
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_current_lba;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_current_lba = ^current_lba;
endmodule
