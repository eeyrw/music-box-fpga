module tb_smart_artix_sd_native_pin_phy;
  logic clk;
  logic rst;
  logic [3:0] clk_div;
  logic cmd_valid;
  logic cmd_ready;
  logic [5:0] cmd_index;
  logic [31:0] cmd_arg;
  logic [1:0] cmd_resp_type;
  logic cmd_data_read;
  logic [15:0] cmd_block_len;
  logic [15:0] cmd_block_count;
  logic rsp_valid;
  logic [2:0] rsp_status;
  logic [119:0] rsp_data;
  logic data_valid;
  logic data_ready;
  logic [7:0] data;
  logic data_last;
  logic [2:0] data_status;
  logic sd_clk;
  logic sd_cmd_o;
  logic sd_cmd_oe;
  logic sd_cmd_i;
  logic [3:0] sd_dat_i;
  int errors;
  int phase;
  int cmd_bits_seen;
  logic [47:0] cmd_seen;
  int data_seen;
  logic [15:0] crc_dat [0:3];

  smart_artix_sd_native_pin_phy #(
    .DIV_WIDTH(4),
    .RESPONSE_TIMEOUT_CYCLES(32),
    .DATA_TIMEOUT_CYCLES(64),
    .POWER_UP_CLOCKS(4),
    .POST_TRANSACTION_CLOCKS(2)
  ) dut (
    .clk,
    .rst,
    .clk_div,
    .cmd_valid,
    .cmd_ready,
    .cmd_index,
    .cmd_arg,
    .cmd_resp_type,
    .cmd_data_read,
    .cmd_block_len,
    .cmd_block_count,
    .rsp_valid,
    .rsp_status,
    .rsp_data,
    .data_valid,
    .data_ready,
    .data,
    .data_last,
    .data_status,
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i,
    .sd_dat_i
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

  function automatic logic [6:0] crc7_next(input logic [6:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[6];
      crc7_next = {crc[5:3], crc[2] ^ feedback, crc[1:0], feedback};
    end
  endfunction

  function automatic logic [6:0] crc7_command(input logic [5:0] index, input logic [31:0] arg);
    logic [6:0] crc;
    logic [39:0] payload;
    begin
      crc = 7'd0;
      payload = {2'b01, index, arg};
      for (int i = 39; i >= 0; i--)
        crc = crc7_next(crc, payload[i]);
      crc7_command = crc;
    end
  endfunction

  function automatic logic [15:0] crc16_next(input logic [15:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[15];
      crc16_next = {crc[14:12], crc[11] ^ feedback, crc[10:5], crc[4] ^ feedback, crc[3:0], feedback};
    end
  endfunction

  task automatic drive_data_nibble(input logic [3:0] nibble);
    begin
      @(negedge sd_clk);
      sd_dat_i = nibble;
      for (int line = 0; line < 4; line++)
        crc_dat[line] = crc16_next(crc_dat[line], nibble[line]);
    end
  endtask

/* verilator lint_off BLKSEQ */
  always @(posedge sd_clk) begin
    if (sd_cmd_oe && cmd_bits_seen < 48) begin
      cmd_seen = {cmd_seen[46:0], sd_cmd_o};
      cmd_bits_seen++;
    end
  end
/* verilator lint_on BLKSEQ */

  always_ff @(posedge clk) begin
    if (rst) begin
      data_seen <= 0;
    end else if (data_valid && data_ready) begin
      check(data == 8'({4'(data_seen[3:0]), 4'(data_seen[3:0] ^ 4'hf)}), "native pin PHY data mismatch");
      if (data_seen == 3)
        check(data_last, "native pin PHY final data byte missing last");
      else
        check(!data_last, "native pin PHY early data last");
      data_seen <= data_seen + 1;
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    clk_div = 4'd0;
    cmd_valid = 1'b0;
    cmd_index = 6'd0;
    cmd_arg = 32'd0;
    cmd_resp_type = 2'd0;
    cmd_data_read = 1'b0;
    cmd_block_len = 16'd0;
    cmd_block_count = 16'd0;
    data_ready = 1'b1;
    sd_cmd_i = 1'b1;
    sd_dat_i = 4'hf;
    errors = 0;
    phase = 0;
    cmd_bits_seen = 0;
    cmd_seen = 48'd0;
    for (int line = 0; line < 4; line++)
      crc_dat[line] = 16'd0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    phase = 1;
    repeat (2) @(posedge clk);
    check(!cmd_ready, "native pin PHY command ready before power-up clocks complete");
    wait (cmd_ready);
    @(negedge clk);
    cmd_index = 6'd8;
    cmd_arg = 32'h0000_01aa;
    cmd_resp_type = 2'd0;
    cmd_data_read = 1'b0;
    cmd_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cmd_valid = 1'b0;
    phase = 2;
    wait (rsp_valid);
    check(!cmd_ready, "native pin PHY command ready before post-command clocks complete");
    @(negedge clk);
    check(rsp_status == 3'd0, "native pin PHY no-response command status mismatch");
    check(cmd_bits_seen == 48, "native pin PHY did not emit 48 command bits");
    check(cmd_seen == {2'b01, 6'd8, 32'h0000_01aa, crc7_command(6'd8, 32'h0000_01aa), 1'b1},
          "native pin PHY command frame mismatch");

    cmd_bits_seen = 0;
    cmd_seen = 48'd0;
    phase = 3;
    wait (cmd_ready);
    @(negedge clk);
    cmd_index = 6'd17;
    cmd_arg = 32'h0000_0004;
    cmd_resp_type = 2'd0;
    cmd_data_read = 1'b1;
    cmd_block_len = 16'd4;
    cmd_block_count = 16'd1;
    cmd_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    cmd_valid = 1'b0;

    phase = 4;
    wait (rsp_valid);
    @(negedge clk);
    sd_dat_i = 4'h0;
    @(posedge sd_clk);
    for (int i = 0; i < 4; i++) begin
      drive_data_nibble(4'(i));
      drive_data_nibble(4'(i[3:0] ^ 4'hf));
    end

    for (int bit_index = 15; bit_index >= 0; bit_index--) begin
      @(negedge sd_clk);
      for (int line = 0; line < 4; line++)
        sd_dat_i[line] = crc_dat[line][bit_index];
    end
    @(negedge sd_clk);
    sd_dat_i = 4'hf;

    phase = 5;
    wait (data_seen == 4);
    repeat (2) @(posedge clk);

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_native_pin_phy errors=%0d", errors);

    $display("PASS: smart_artix_sd_native_pin_phy");
    $finish;
  end

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "FAIL: smart_artix_sd_native_pin_phy timed out phase=%0d data_seen=%0d cmd_bits_seen=%0d", phase, data_seen, cmd_bits_seen);
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_observed;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_observed = cmd_ready ^ (^rsp_data) ^ (^data_status);
endmodule
