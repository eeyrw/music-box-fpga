module tb_sd_native_pin_phy;
  import sd_native_pkg::*;
  logic clk;
  logic rst;
  logic [3:0] clk_div;
  logic cmd_valid;
  logic cmd_ready;
  logic [5:0] cmd_index;
  logic [31:0] cmd_arg;
  sd_response_type_t cmd_resp_type;
  logic cmd_data_read;
  logic [15:0] cmd_block_len;
  logic [15:0] cmd_block_count;
  logic rsp_data_proceed;
  logic rsp_data_cancel;
  logic abort_request;
  logic rsp_valid;
  sd_transport_status_t rsp_status;
  logic [119:0] rsp_data;
  logic transaction_done;
  logic data_valid;
  logic data_ready;
  logic [7:0] data;
  logic data_last;
  sd_transport_status_t data_status;
  logic sd_clk;
  logic sd_cmd_o;
  logic sd_cmd_oe;
  logic sd_cmd_i;
  logic [3:0] sd_dat_i;
  int errors;
  int rsp_count;
  int done_count;
  int data_count;
  int data_last_count;
  sd_transport_status_t observed_rsp_status;
  logic [31:0] observed_rsp_data;
  sd_transport_status_t observed_final_status;
  time cmd_change_time;
  localparam logic [4:0] PHY_STATE_RESP_WAIT_LOW = 5'd5;
  localparam logic [4:0] PHY_STATE_DATA_WAIT_LOW = 5'd12;

  sd_native_pin_phy #(
    .DIV_WIDTH(4),
    .SYS_CLK_HZ(100),
    .RESPONSE_TIMEOUT_CYCLES(12),
    .DATA_TIMEOUT_CYCLES(40),
    .BUSY_TIMEOUT_CYCLES(40),
    .POWER_UP_CLOCKS(4),
    .POST_TRANSACTION_CLOCKS(8)
  ) dut (.*);

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;

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

  function automatic logic [6:0] crc7_40(input logic [39:0] payload);
    logic [6:0] crc;
    begin
      crc = '0;
      for (int i = 39; i >= 0; i--)
        crc = crc7_next(crc, payload[i]);
      crc7_40 = crc;
    end
  endfunction

  function automatic logic [6:0] crc7_120(input logic [119:0] payload);
    logic [6:0] crc;
    begin
      crc = '0;
      for (int i = 119; i >= 0; i--)
        crc = crc7_next(crc, payload[i]);
      crc7_120 = crc;
    end
  endfunction

  function automatic logic [15:0] crc16_next(input logic [15:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[15];
      crc16_next = {crc[14:12], crc[11] ^ feedback, crc[10:5],
                    crc[4] ^ feedback, crc[3:0], feedback};
    end
  endfunction

  task automatic launch_command(
      input logic [5:0] index,
      input logic [31:0] arg,
      input sd_response_type_t response_type,
      input logic data_read,
      input logic [15:0] block_len);
    begin
      wait (cmd_ready);
      @(negedge clk);
      cmd_index = index;
      cmd_arg = arg;
      cmd_resp_type = response_type;
      cmd_data_read = data_read;
      cmd_block_len = block_len;
      cmd_block_count = 16'd1;
      cmd_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cmd_valid = 1'b0;
      cmd_index = 6'h3f;
      cmd_arg = 32'hdead_beef;
      cmd_resp_type = SD_RESP_R2;
      cmd_data_read = !data_read;
      cmd_block_len = 16'hffff;
      cmd_block_count = 16'hffff;
    end
  endtask

  task automatic launch_multi_command(
      input logic [5:0] index,
      input logic [31:0] arg,
      input logic [15:0] block_len,
      input logic [15:0] block_count);
    begin
      wait (cmd_ready);
      @(negedge clk);
      cmd_index = index;
      cmd_arg = arg;
      cmd_resp_type = SD_RESP_R1;
      cmd_data_read = 1'b1;
      cmd_block_len = block_len;
      cmd_block_count = block_count;
      cmd_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      cmd_valid = 1'b0;
    end
  endtask

  task automatic drive_short_response(
      input logic [5:0] response_index,
      input logic [31:0] payload,
      input int idle_clocks,
      input logic corrupt_crc,
      input logic r3);
    logic [47:0] frame;
    logic [6:0] crc;
    begin
      wait (dut.state == PHY_STATE_RESP_WAIT_LOW);
      sd_cmd_i = 1'b1;
      repeat (idle_clocks) @(posedge sd_clk);
      crc = r3 ? 7'h7f : crc7_40({2'b00, response_index, payload});
      if (corrupt_crc)
        crc ^= 7'h01;
      frame = {2'b00, response_index, payload, crc, 1'b1};
      for (int i = 47; i >= 0; i--) begin
        @(negedge sd_clk);
        sd_cmd_i = frame[i];
      end
      @(negedge sd_clk);
      sd_cmd_i = 1'b1;
    end
  endtask

  task automatic drive_long_response(
      input logic [119:0] payload,
      input logic corrupt_crc);
    logic [135:0] frame;
    logic [6:0] crc;
    begin
      wait (dut.state == PHY_STATE_RESP_WAIT_LOW);
      crc = crc7_120(payload);
      if (corrupt_crc)
        crc ^= 7'h01;
      frame = {2'b00, 6'h3f, payload, crc, 1'b1};
      for (int i = 135; i >= 0; i--) begin
        @(negedge sd_clk);
        sd_cmd_i = frame[i];
      end
      @(negedge sd_clk);
      sd_cmd_i = 1'b1;
    end
  endtask

  task automatic decide_data(input logic proceed_transfer);
    begin
      @(negedge clk);
      rsp_data_proceed = proceed_transfer;
      rsp_data_cancel = !proceed_transfer;
      @(posedge clk);
      @(negedge clk);
      rsp_data_proceed = 1'b0;
      rsp_data_cancel = 1'b0;
    end
  endtask

  task automatic drive_block(input int byte_count, input int idle_clocks);
    logic [15:0] crc [0:3];
    logic [3:0] nibble;
    begin
      for (int line = 0; line < 4; line++)
        crc[line] = '0;
      wait (dut.state == PHY_STATE_DATA_WAIT_LOW);
      repeat (idle_clocks) @(posedge sd_clk);
      @(negedge sd_clk);
      sd_dat_i = 4'h0;
      for (int i = 0; i < byte_count; i++) begin
        nibble = 4'(i);
        @(negedge sd_clk);
        sd_dat_i = nibble;
        for (int line = 0; line < 4; line++)
          crc[line] = crc16_next(crc[line], nibble[line]);
        nibble = 4'(i) ^ 4'hf;
        @(negedge sd_clk);
        sd_dat_i = nibble;
        for (int line = 0; line < 4; line++)
          crc[line] = crc16_next(crc[line], nibble[line]);
      end
      for (int bit_index = 15; bit_index >= 0; bit_index--) begin
        @(negedge sd_clk);
        for (int line = 0; line < 4; line++)
          sd_dat_i[line] = crc[line][bit_index];
      end
      @(negedge sd_clk);
      sd_dat_i = 4'hf;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_count <= 0;
      done_count <= 0;
      data_count <= 0;
      data_last_count <= 0;
      observed_rsp_status <= SD_STATUS_OK;
      observed_rsp_data <= '0;
      observed_final_status <= SD_STATUS_OK;
    end else begin
      if (rsp_valid) begin
        rsp_count <= rsp_count + 1;
        observed_rsp_status <= rsp_status;
        observed_rsp_data <= rsp_data[31:0];
      end
      if (transaction_done)
        done_count <= done_count + 1;
      if (data_valid && data_ready) begin
        if (data_status == SD_STATUS_OK)
          check(data == {4'(data_count % 4), 4'(data_count % 4) ^ 4'hf},
                "payload byte mismatch");
        if (data_last) begin
          observed_final_status <= data_status;
          data_last_count <= data_last_count + 1;
        end
        data_count <= data_count + 1;
      end
    end
  end

  always @(sd_cmd_o)
    if (sd_cmd_oe)
      cmd_change_time = $time;

  always @(posedge sd_clk)
    if (sd_cmd_oe)
      check($time > cmd_change_time, "CMD changed on the sampling edge");

  initial begin
    int before_rsp;
    int before_done;
    clk = 1'b0;
    rst = 1'b1;
    clk_div = 4'd0;
    cmd_valid = 1'b0;
    cmd_index = '0;
    cmd_arg = '0;
    cmd_resp_type = SD_RESP_NONE;
    cmd_data_read = 1'b0;
    cmd_block_len = '0;
    cmd_block_count = '0;
    rsp_data_proceed = 1'b0;
    rsp_data_cancel = 1'b0;
    abort_request = 1'b0;
    data_ready = 1'b1;
    sd_cmd_i = 1'b1;
    sd_dat_i = 4'hf;
    errors = 0;
    cmd_change_time = 0;
    repeat (3) @(posedge clk);
    rst = 1'b0;
    wait (cmd_ready);

    before_done = done_count;
    launch_command(6'd0, 32'h0, SD_RESP_NONE, 1'b0, 16'd0);
    wait (done_count == before_done + 1);
    check(observed_rsp_status == SD_STATUS_OK, "no-response command failed");

    before_rsp = rsp_count;
    launch_command(6'd8, 32'h1aa, SD_RESP_R7, 1'b0, 16'd0);
    drive_short_response(6'd8, 32'h1aa, 4, 1'b0, 1'b0);
    wait (rsp_count == before_rsp + 1);
    check(observed_rsp_status == SD_STATUS_OK, "delayed R7 response rejected");
    check(observed_rsp_data == 32'h1aa, "R7 payload mismatch");

    before_rsp = rsp_count;
    launch_command(6'd17, 32'h4, SD_RESP_R1, 1'b0, 16'd0);
    drive_short_response(6'd18, 32'h900, 1, 1'b0, 1'b0);
    wait (rsp_count == before_rsp + 1);
    check(observed_rsp_status == SD_STATUS_WRONG_INDEX, "wrong response index not detected");

    before_rsp = rsp_count;
    launch_command(6'd2, 32'h0, SD_RESP_R2, 1'b0, 16'd0);
    drive_long_response(120'h0123_4567_89ab_cdef_0123_4567_89ab_cd, 1'b0);
    wait (rsp_count == before_rsp + 1);
    check(observed_rsp_status == SD_STATUS_OK, "valid R2 response rejected");

    before_rsp = rsp_count;
    sd_dat_i = 4'he;
    launch_command(6'd7, 32'h1234_0000, SD_RESP_R1B, 1'b0, 16'd0);
    drive_short_response(6'd7, 32'h700, 1, 1'b0, 1'b0);
    repeat (3) @(posedge sd_clk);
    check(rsp_count == before_rsp, "R1b completed while DAT0 was busy");
    @(negedge sd_clk);
    sd_dat_i = 4'hf;
    wait (rsp_count == before_rsp + 1);
    check(observed_rsp_status == SD_STATUS_OK, "R1b busy release failed");

    before_rsp = rsp_count;
    launch_command(6'd17, 32'h8, SD_RESP_R1, 1'b1, 16'd4);
    drive_short_response(6'd17, 32'h900, 2, 1'b0, 1'b0);
    wait (rsp_count == before_rsp + 1);
    decide_data(1'b1);
    drive_block(4, 5);
    wait (data_count == 4);
    check(observed_final_status == SD_STATUS_OK, "valid data block failed CRC/framing");

    before_rsp = rsp_count;
    before_done = done_count;
    launch_multi_command(6'd18, 32'h20, 16'd4, 16'd2);
    drive_short_response(6'd18, 32'h900, 1, 1'b0, 1'b0);
    wait (rsp_count == before_rsp + 1);
    decide_data(1'b1);
    drive_block(4, 1);
    wait (data_count == 8);
    check(data_last_count == 2, "first CMD18 block boundary was not reported");
    drive_block(4, 2);
    wait (data_count == 12);
    wait (done_count == before_done + 1);
    check(data_last_count == 3, "second CMD18 block boundary was not reported");

    before_rsp = rsp_count;
    launch_command(6'd17, 32'h9, SD_RESP_R1, 1'b1, 16'd4);
    drive_short_response(6'd17, 32'h900, 1, 1'b0, 1'b0);
    wait (rsp_count == before_rsp + 1);
    decide_data(1'b1);
    wait (dut.state == PHY_STATE_DATA_WAIT_LOW);
    @(negedge sd_clk);
    sd_dat_i = 4'b1110;
    @(negedge sd_clk);
    sd_dat_i = 4'hf;
    wait (data_valid && data_last);
    check(data_status == SD_STATUS_FRAMING_ERROR, "malformed four-bit start token not rejected");
    @(posedge clk);

    clk_div = 4'd2;
    before_rsp = rsp_count;
    launch_command(6'd17, 32'ha, SD_RESP_R1, 1'b1, 16'd4);
    drive_short_response(6'd17, 32'h900, 1, 1'b0, 1'b0);
    wait (rsp_count == before_rsp + 1);
    decide_data(1'b1);
    wait (data_valid && data_last);
    check(data_status == SD_STATUS_TIMEOUT, "data timeout did not expire by system-clock budget");
    sd_dat_i = 4'hf;

    repeat (20) @(posedge clk);
    if (errors != 0)
      $fatal(1, "FAIL: sd_native_pin_phy errors=%0d", errors);
    $display("PASS: sd_native_pin_phy");
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "FAIL: sd_native_pin_phy timeout state=%0d", dut.state);
  end
endmodule
