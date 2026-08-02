module tb_spi_register_bridge;
  timeunit 1ns;
  timeprecision 1ps;

  localparam time SPI_HALF_PERIOD = 16ns;

  logic clk = 1'b0;
  logic rst;
  logic spi_sclk;
  logic spi_cs_n;
  logic spi_mosi;
  logic spi_miso;
  logic spi_error;
  logic bus_valid;
  logic bus_write;
  logic [15:0] bus_address;
  logic [31:0] bus_wdata;
  logic [31:0] bus_rdata;
  logic bus_ready;
  logic bus_error;
  logic cmd_valid;
  logic [31:0] cmd_data;
  logic cmd_ready;
  logic [31:0] registers [0:63];
  logic bus_allow;
  int bus_access_count = 0;
  logic [31:0] received_commands [0:127];
  int received_count = 0;
  logic spi_miso_no_crc;
  logic spi_error_no_crc;
  logic bus_valid_no_crc;
  logic bus_write_no_crc;
  logic [15:0] bus_address_no_crc;
  logic [31:0] bus_wdata_no_crc;
  logic cmd_valid_no_crc;
  logic [31:0] cmd_data_no_crc;
  logic [31:0] received_commands_no_crc [0:127];
  int received_count_no_crc = 0;
  int bus_access_count_no_crc = 0;
  int errors = 0;
  time last_spi_fall;
  time max_miso_delay;
  logic unused_address_alignment;
  logic unused_no_crc_outputs;

  assign unused_address_alignment = |bus_address[1:0];
  assign unused_no_crc_outputs = spi_miso_no_crc ^ bus_valid_no_crc ^
      bus_write_no_crc ^ (^bus_address_no_crc) ^ (^bus_wdata_no_crc);

  always #5 clk <= ~clk;

  /* verilator lint_off BLKSEQ */
  always @(negedge spi_sclk)
    last_spi_fall = $time;

  always @(spi_miso) begin
    time miso_delay;
    if (last_spi_fall != 0) begin
      miso_delay = $time - last_spi_fall;
      if (miso_delay > max_miso_delay)
        max_miso_delay = miso_delay;
    end
  end
  /* verilator lint_on BLKSEQ */

  spi_register_bridge dut (.*);

  spi_register_bridge #(
    .CHECK_COMMAND_CRC(1'b0),
    .CHECK_REGISTER_CRC(1'b0)
  ) dut_no_crc (
    .clk,
    .rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso(spi_miso_no_crc),
    .spi_error(spi_error_no_crc),
    .bus_valid(bus_valid_no_crc),
    .bus_write(bus_write_no_crc),
    .bus_address(bus_address_no_crc),
    .bus_wdata(bus_wdata_no_crc),
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .cmd_valid(cmd_valid_no_crc),
    .cmd_data(cmd_data_no_crc),
    .cmd_ready
  );

  assign bus_ready = bus_allow && (bus_valid || bus_valid_no_crc);
  assign bus_error = bus_valid && (bus_address[15:8] != 8'h00);
  assign bus_rdata = registers[bus_address[7:2]];

  always_ff @(posedge clk) begin
    if (bus_valid && bus_ready) begin
      bus_access_count <= bus_access_count + 1;
      if (bus_write && !bus_error)
        registers[bus_address[7:2]] <= bus_wdata;
    end
    if (bus_valid_no_crc && bus_ready)
      bus_access_count_no_crc <= bus_access_count_no_crc + 1;
    if (cmd_valid && cmd_ready) begin
      received_commands[received_count] <= cmd_data;
      received_count <= received_count + 1;
    end
    if (cmd_valid_no_crc && cmd_ready) begin
      received_commands_no_crc[received_count_no_crc] <= cmd_data_no_crc;
      received_count_no_crc <= received_count_no_crc + 1;
    end
  end

  function automatic logic [15:0] crc16_byte(
    input logic [15:0] crc_in,
    input logic [7:0] data
  );
    logic [15:0] crc;
    begin
      crc = crc_in ^ {data, 8'd0};
      for (int bit_index = 0; bit_index < 8; bit_index++)
        crc = crc[15] ? ((crc << 1) ^ 16'h1021) : (crc << 1);
      crc16_byte = crc;
    end
  endfunction

  function automatic logic [15:0] crc16_word(
    input logic [15:0] crc_in,
    input logic [31:0] data
  );
    logic [15:0] crc;
    begin
      crc = crc16_byte(crc_in, data[31:24]);
      crc = crc16_byte(crc, data[23:16]);
      crc = crc16_byte(crc, data[15:8]);
      crc16_word = crc16_byte(crc, data[7:0]);
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

  function automatic logic [31:0] register_crc32(
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
      register_crc32 = crc ^ 32'hffff_ffff;
    end
  endfunction

  task automatic spi_clock_bit(input logic bit_value);
    begin
      spi_mosi = bit_value;
      #(SPI_HALF_PERIOD);
      spi_sclk = 1'b1;
      #(SPI_HALF_PERIOD);
      spi_sclk = 1'b0;
    end
  endtask

  task automatic spi_send_byte(input logic [7:0] value);
    for (int bit_index = 7; bit_index >= 0; bit_index--)
      spi_clock_bit(value[bit_index]);
  endtask

  task automatic spi_send_word(input logic [31:0] value);
    begin
      spi_send_byte(value[31:24]);
      spi_send_byte(value[23:16]);
      spi_send_byte(value[15:8]);
      spi_send_byte(value[7:0]);
    end
  endtask

  task automatic spi_read_word_bits(output logic [31:0] value);
    begin
      value = '0;
      for (int bit_index = 31; bit_index >= 0; bit_index--) begin
        #(SPI_HALF_PERIOD);
        spi_sclk = 1'b1;
        #(SPI_HALF_PERIOD);
        value[bit_index] = spi_miso;
        spi_sclk = 1'b0;
      end
    end
  endtask

  task automatic begin_transaction(input logic [7:0] opcode);
    begin
      spi_cs_n = 1'b0;
      #(SPI_HALF_PERIOD);
      spi_send_byte(opcode);
    end
  endtask

  task automatic begin_command_transaction(
    input logic [7:0] word_count,
    input logic [15:0] crc
  );
    begin
      begin_transaction(8'ha5);
      spi_send_byte(word_count);
      spi_send_byte(crc[15:8]);
      spi_send_byte(crc[7:0]);
    end
  endtask

  task automatic end_transaction;
    begin
      #(SPI_HALF_PERIOD);
      last_spi_fall = 0;
      spi_cs_n = 1'b1;
      #(SPI_HALF_PERIOD * 2);
    end
  endtask

  task automatic spi_mailbox_request(
    input logic [7:0] operation,
    input logic [15:0] address,
    input logic [31:0] value,
    input logic corrupt_crc
  );
    logic [31:0] crc;
    begin
      crc = register_crc32(8'h5a, operation, address, value);
      if (corrupt_crc)
        crc = crc ^ 32'h0000_0001;
      begin_transaction(8'h5a);
      spi_send_byte(operation);
      spi_send_byte(address[15:8]);
      spi_send_byte(address[7:0]);
      spi_send_word(value);
      spi_send_word(crc);
      end_transaction();
    end
  endtask

  task automatic spi_mailbox_fetch(output logic [95:0] response);
    logic [31:0] word;
    begin
      response = '0;
      begin_transaction(8'h5b);
      spi_send_byte(8'h00);
      spi_send_byte(8'h00);
      spi_send_byte(8'h00);
      spi_read_word_bits(word);
      response[95:64] = word;
      spi_read_word_bits(word);
      response[63:32] = word;
      spi_read_word_bits(word);
      response[31:0] = word;
      end_transaction();
    end
  endtask

  task automatic spi_command_stream3(
    input logic [31:0] word0,
    input logic [31:0] word1,
    input logic [31:0] word2,
    input logic corrupt_crc
  );
    logic [15:0] crc;
    begin
      crc = crc16_byte(16'hffff, 8'd3);
      crc = crc16_word(crc, word0);
      crc = crc16_word(crc, word1);
      crc = crc16_word(crc, word2);
      if (corrupt_crc)
        crc = crc ^ 16'h0001;
      begin_command_transaction(8'd3, crc);
      spi_send_word(word0);
      spi_send_word(word1);
      spi_send_word(word2);
      end_transaction();
    end
  endtask

  task automatic spi_flush_transaction(input logic [7:0] word_count);
    logic [15:0] crc;
    begin
      crc = crc16_byte(16'hffff, word_count);
      for (int index = 0; index < word_count; index++)
        crc = crc16_word(crc, 32'h7f00_0000);
      begin_command_transaction(word_count, crc);
      for (int index = 0; index < word_count; index++)
        spi_send_word(32'h7f00_0000);
      end_transaction();
    end
  endtask

  initial begin
    logic [95:0] mailbox_response;
    logic [31:0] response_crc;
    int accesses_before;
    for (int index = 0; index < 64; index++)
      registers[index] = '0;
    rst = 1'b1;
    spi_sclk = 1'b0;
    spi_cs_n = 1'b1;
    spi_mosi = 1'b0;
    bus_allow = 1'b1;
    cmd_ready = 1'b1;
    last_spi_fall = 0;
    max_miso_delay = 0;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (5) @(negedge clk);

    spi_mailbox_request(8'h01, 16'h0010, 32'h1234_5678, 1'b0);
    repeat (4) @(negedge clk);
    spi_mailbox_fetch(mailbox_response);
    response_crc = register_crc32(
        mailbox_response[95:88], mailbox_response[87:80],
        mailbox_response[79:64], mailbox_response[63:32]);
    if (spi_error || mailbox_response[95:88] != 8'h00 ||
        mailbox_response[87:80] != 8'h01 ||
        mailbox_response[79:64] != 16'h0010 ||
        mailbox_response[63:32] != 32'd0 ||
        mailbox_response[31:0] != response_crc ||
        registers[4] != 32'h1234_5678) begin
      $error("mailbox register write failed: response=%024x", mailbox_response);
      errors++;
    end

    spi_mailbox_request(8'h00, 16'h0010, 32'd0, 1'b0);
    repeat (4) @(negedge clk);
    spi_mailbox_fetch(mailbox_response);
    if (spi_error || mailbox_response[95:88] != 8'h00 ||
        mailbox_response[87:80] != 8'h00 ||
        mailbox_response[79:64] != 16'h0010 ||
        mailbox_response[63:32] != 32'h1234_5678 ||
        mailbox_response[31:0] != register_crc32(
            8'h00, 8'h00, 16'h0010, 32'h1234_5678)) begin
      $error("mailbox register read failed: response=%024x", mailbox_response);
      errors++;
    end

    // The completed response is retained, allowing a CRC-failed fetch to retry.
    spi_mailbox_fetch(mailbox_response);
    if (mailbox_response[95:88] != 8'h00 ||
        mailbox_response[63:32] != 32'h1234_5678) begin
      $error("mailbox response was not retained");
      errors++;
    end

    // Register latency is decoupled from SPI. Fetch reports BUSY until ready.
    bus_allow = 1'b0;
    spi_mailbox_request(8'h00, 16'h0010, 32'd0, 1'b0);
    repeat (4) @(negedge clk);
    if (!bus_valid || bus_address != 16'h0010) begin
      $error("mailbox request did not hold while register bus stalled");
      errors++;
    end
    spi_mailbox_fetch(mailbox_response);
    if (mailbox_response[95:88] != 8'h02 ||
        mailbox_response[79:64] != 16'h0010) begin
      $error("mailbox did not report BUSY: response=%024x", mailbox_response);
      errors++;
    end
    bus_allow = 1'b1;
    repeat (4) @(negedge clk);
    spi_mailbox_fetch(mailbox_response);
    if (mailbox_response[95:88] != 8'h00 ||
        mailbox_response[63:32] != 32'h1234_5678) begin
      $error("stalled mailbox request did not complete");
      errors++;
    end

    // A corrupt request has no primary-bus side effect. CRC checking can be
    // disabled without changing the wire format on the second DUT.
    accesses_before = bus_access_count;
    spi_mailbox_request(8'h01, 16'h0014, 32'hdead_beef, 1'b1);
    repeat (4) @(negedge clk);
    if (!spi_error || bus_access_count != accesses_before ||
        bus_access_count_no_crc == 0) begin
      $error("mailbox request CRC configuration mismatch");
      errors++;
    end
    spi_mailbox_fetch(mailbox_response);
    if (mailbox_response[95:88] != 8'h03) begin
      $error("rejected mailbox request did not return EMPTY");
      errors++;
    end

    // A request ending partway through its CRC is rejected before bus access.
    accesses_before = bus_access_count;
    begin_transaction(8'h5a);
    spi_send_byte(8'h01);
    spi_send_byte(8'h00);
    spi_send_byte(8'h18);
    spi_send_word(32'hcafe_babe);
    spi_send_byte(8'h00);
    spi_send_byte(8'h00);
    end_transaction();
    if (!spi_error || bus_access_count != accesses_before) begin
      $error("partial mailbox request reached the register bus");
      errors++;
    end
    spi_mailbox_fetch(mailbox_response);
    if (mailbox_response[95:88] != 8'h03) begin
      $error("partial mailbox request did not clear the prior response");
      errors++;
    end

    // The removed direct/burst register opcodes must not reach the bus.
    accesses_before = bus_access_count;
    begin_transaction(8'hc0);
    spi_send_byte(8'h00);
    spi_send_byte(8'h10);
    spi_send_word(32'hffff_ffff);
    end_transaction();
    if (!spi_error || bus_access_count != accesses_before) begin
      $error("removed burst opcode was not rejected");
      errors++;
    end

    // Register decode failures are returned through the retained response.
    spi_mailbox_request(8'h00, 16'h0100, 32'd0, 1'b0);
    repeat (4) @(negedge clk);
    spi_mailbox_fetch(mailbox_response);
    if (mailbox_response[95:88] != 8'h01 ||
        mailbox_response[79:64] != 16'h0100 ||
        mailbox_response[63:32] != 32'd0) begin
      $error("mailbox bus error response mismatch: %024x", mailbox_response);
      errors++;
    end

    // One transaction may contain multiple complete commands.
    spi_command_stream3(32'h7f00_0000, 32'h1500_0001, 32'h0000_0001,
                        1'b0);
    repeat (8) @(negedge clk);
    if (spi_error || received_count != 3 ||
        received_commands[0] != 32'h7f00_0000 ||
        received_commands[1] != 32'h1500_0001 ||
        received_commands[2] != 32'h0000_0001) begin
      $error("command stream failed: error=%0b count=%0d", spi_error, received_count);
      errors++;
    end

    // A complete transaction remains staged while the downstream FIFO stalls.
    cmd_ready = 1'b0;
    spi_command_stream3(32'h7f00_0000, 32'h1500_0001, 32'h0000_0002,
                        1'b0);
    repeat (8) @(negedge clk);
    if (spi_error || received_count != 3 || !cmd_valid) begin
      $error("staged command transaction did not hold under backpressure");
      errors++;
    end
    cmd_ready = 1'b1;
    repeat (8) @(negedge clk);
    if (received_count != 6 ||
        received_commands[3] != 32'h7f00_0000 ||
        received_commands[4] != 32'h1500_0001 ||
        received_commands[5] != 32'h0000_0002) begin
      $error("staged command transaction did not commit in order");
      errors++;
    end

    // CRC checking is a build option; the wire header never changes.
    spi_command_stream3(32'h7f00_0000, 32'h1500_0001, 32'h0000_0003,
                        1'b1);
    repeat (8) @(negedge clk);
    if (!spi_error || received_count != 6 ||
        spi_error_no_crc || received_count_no_crc != 9 ||
        received_commands_no_crc[6] != 32'h7f00_0000 ||
        received_commands_no_crc[7] != 32'h1500_0001 ||
        received_commands_no_crc[8] != 32'h0000_0003) begin
      $error("configurable CRC checking mismatch: checked=%0d unchecked=%0d",
             received_count, received_count_no_crc);
      errors++;
    end

    // Ending CS after a partial payload word rejects the complete transaction.
    begin
      logic [15:0] crc;
      logic [31:0] partial_word;
      partial_word = 32'h0000_0004;
      crc = crc16_byte(16'hffff, 8'd2);
      crc = crc16_word(crc, 32'h1500_0001);
      crc = crc16_word(crc, partial_word);
      begin_command_transaction(8'd2, crc);
      spi_send_word(32'h1500_0001);
      for (int bit_index = 31; bit_index >= 21; bit_index--)
        spi_clock_bit(partial_word[bit_index]);
      end_transaction();
    end
    if (!spi_error || received_count != 6 || received_count_no_crc != 9) begin
      $error("partial command word was not rejected atomically");
      errors++;
    end

    // A legal word boundary with fewer words than declared is also rejected.
    begin_command_transaction(8'd3, 16'h0000);
    spi_send_word(32'h1500_0001);
    spi_send_word(32'h0000_0005);
    end_transaction();
    if (!spi_error || received_count != 6 || received_count_no_crc != 9) begin
      $error("short command transaction was not rejected atomically");
      errors++;
    end

    begin_command_transaction(8'd0, 16'hffff);
    end_transaction();
    if (!spi_error || received_count != 6 || received_count_no_crc != 9) begin
      $error("zero-length command transaction was not rejected");
      errors++;
    end

    begin_command_transaction(8'd64, 16'h0000);
    end_transaction();
    if (!spi_error || received_count != 6 || received_count_no_crc != 9) begin
      $error("overlength command transaction was not rejected");
      errors++;
    end

    spi_flush_transaction(8'd63);
    repeat (140) @(negedge clk);
    if (spi_error || received_count != 69 || received_count_no_crc != 72) begin
      $error("maximum command transaction failed: checked=%0d unchecked=%0d",
             received_count, received_count_no_crc);
      errors++;
    end

    if (max_miso_delay > 5ns) begin
      $error("SPI falling-edge-to-MISO delay exceeded 5 ns: %0t", max_miso_delay);
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: SPI bridge errors=%0d", errors);
    $display("PASS: SPI register and command-stream bridge");
    $finish;
  end
endmodule
