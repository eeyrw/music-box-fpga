module fake_sd_native_pin_model (
  input  logic       sd_clk,
  input  logic       sd_cmd_o,
  input  logic       sd_cmd_oe,
  output logic       sd_cmd_i,
  output logic [3:0] sd_dat_i,
  output logic [5:0] last_cmd_index,
  output logic [31:0] last_cmd_arg,
  output logic       saw_cmd17
);
/* verilator lint_off BLKSEQ */
  logic [47:0] cmd_shift;
  int cmd_bits_seen;
  logic [15:0] crc_dat [0:3];

  function automatic logic [15:0] crc16_next(input logic [15:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[15];
      crc16_next = {crc[14:12], crc[11] ^ feedback, crc[10:5], crc[4] ^ feedback, crc[3:0], feedback};
    end
  endfunction

  function automatic logic [6:0] crc7_next(input logic [6:0] crc, input logic bit_in);
    logic feedback;
    begin
      feedback = bit_in ^ crc[6];
      crc7_next = {crc[5:3], crc[2] ^ feedback, crc[1:0], feedback};
    end
  endfunction

  function automatic logic [6:0] crc7_response(input logic [5:0] index, input logic [31:0] payload);
    logic [6:0] crc;
    logic [39:0] crc_payload;
    begin
      crc = 7'd0;
      crc_payload = {2'b00, index, payload};
      for (int i = 39; i >= 0; i--)
        crc = crc7_next(crc, crc_payload[i]);
      crc7_response = crc;
    end
  endfunction

  task automatic drive_response_short(input logic [31:0] payload);
    logic [47:0] response;
    begin
      response = {1'b0, 1'b0, last_cmd_index, payload, crc7_response(last_cmd_index, payload), 1'b1};
      for (int i = 47; i >= 0; i--) begin
        @(negedge sd_clk);
        sd_cmd_i = response[i];
      end
      @(negedge sd_clk);
      sd_cmd_i = 1'b1;
    end
  endtask

  task automatic drive_data_nibble(input logic [3:0] nibble);
    begin
      @(negedge sd_clk);
      sd_dat_i = nibble;
      @(negedge sd_clk);
      for (int line = 0; line < 4; line++)
        crc_dat[line] = crc16_next(crc_dat[line], nibble[line]);
    end
  endtask

  task automatic drive_block(input int byte_count);
    begin
      for (int line = 0; line < 4; line++)
        crc_dat[line] = 16'd0;

      @(negedge sd_clk);
      sd_dat_i = 4'h0;
      for (int i = 0; i < byte_count; i++) begin
        drive_data_nibble(4'hf);
        drive_data_nibble(4'hf);
      end

      for (int bit_index = 15; bit_index >= 0; bit_index--) begin
        @(negedge sd_clk);
        for (int line = 0; line < 4; line++)
          sd_dat_i[line] = crc_dat[line][bit_index];
        @(negedge sd_clk);
      end
      @(negedge sd_clk);
      sd_dat_i = 4'hf;
    end
  endtask

  task drive_idle_clocks(input integer count);
    integer i;
    begin
      sd_dat_i = 4'hf;
      for (i = 0; i < count; i = i + 1)
        @(negedge sd_clk);
    end
  endtask

  initial begin
    sd_cmd_i = 1'b1;
    sd_dat_i = 4'hf;
    last_cmd_index = '0;
    last_cmd_arg = '0;
    saw_cmd17 = 1'b0;
    cmd_shift = '0;
    cmd_bits_seen = 0;
  end

  always @(posedge sd_clk) begin
    if (sd_cmd_oe) begin
      cmd_shift = {cmd_shift[46:0], sd_cmd_o};
      cmd_bits_seen++;
      if (cmd_bits_seen == 48) begin
        last_cmd_index = cmd_shift[45:40];
        last_cmd_arg = cmd_shift[39:8];
        if (cmd_shift[45:40] == 6'd17) begin
          saw_cmd17 = 1'b1;
          fork
            begin
              drive_response_short(32'h1357_9bdf);
              drive_idle_clocks(24);
              drive_block(4);
            end
          join_none
        end
        cmd_bits_seen = 0;
      end
    end else begin
      cmd_bits_seen = 0;
    end
  end
/* verilator lint_on BLKSEQ */

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_cmd_shift_msb;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_cmd_shift_msb = cmd_shift[47];
endmodule
