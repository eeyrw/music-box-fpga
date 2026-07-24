module tb_spi_register_bridge;
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
  logic [31:0] received_commands [0:15];
  int received_count = 0;
  int errors = 0;
  logic unused_address_alignment;

  assign unused_address_alignment = |bus_address[1:0];

  always #5 clk <= ~clk;

  spi_register_bridge dut (.*);

  assign bus_ready = bus_valid;
  assign bus_error = bus_valid && (bus_address[15:8] != 8'h00);
  assign bus_rdata = registers[bus_address[7:2]];

  always_ff @(posedge clk) begin
    if (bus_valid && bus_ready && bus_write && !bus_error)
      registers[bus_address[7:2]] <= bus_wdata;
    if (cmd_valid && cmd_ready) begin
      received_commands[received_count] <= cmd_data;
      received_count <= received_count + 1;
    end
  end

  task automatic spi_clock_bit(input logic bit_value);
    begin
      spi_mosi = bit_value;
      repeat (2) @(negedge clk);
      spi_sclk = 1'b1;
      repeat (2) @(negedge clk);
      spi_sclk = 1'b0;
      repeat (2) @(negedge clk);
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

  task automatic begin_transaction(input logic [7:0] opcode);
    begin
      spi_cs_n = 1'b0;
      repeat (3) @(negedge clk);
      spi_send_byte(opcode);
    end
  endtask

  task automatic end_transaction;
    begin
      repeat (4) @(negedge clk);
      spi_cs_n = 1'b1;
      repeat (4) @(negedge clk);
    end
  endtask

  task automatic spi_write_word(input logic [15:0] address, input logic [31:0] value);
    begin
      begin_transaction(8'h80);
      spi_send_byte(address[15:8]);
      spi_send_byte(address[7:0]);
      spi_send_word(value);
      end_transaction();
    end
  endtask

  task automatic spi_read_word(input logic [15:0] address, output logic [31:0] value);
    begin
      value = '0;
      begin_transaction(8'h00);
      spi_send_byte(address[15:8]);
      spi_send_byte(address[7:0]);
      repeat (6) @(negedge clk);
      for (int bit_index = 31; bit_index >= 0; bit_index--) begin
        repeat (2) @(negedge clk);
        spi_sclk = 1'b1;
        repeat (2) @(negedge clk);
        value[bit_index] = spi_miso;
        spi_sclk = 1'b0;
        repeat (2) @(negedge clk);
      end
      end_transaction();
    end
  endtask

  task automatic spi_command_stream5(
    input logic [31:0] word0,
    input logic [31:0] word1,
    input logic [31:0] word2,
    input logic [31:0] word3,
    input logic [31:0] word4
  );
    begin
      begin_transaction(8'ha5);
      spi_send_word(word0);
      spi_send_word(word1);
      spi_send_word(word2);
      spi_send_word(word3);
      spi_send_word(word4);
      end_transaction();
    end
  endtask

  initial begin
    logic [31:0] read_value;
    for (int index = 0; index < 64; index++)
      registers[index] = '0;
    rst = 1'b1;
    spi_sclk = 1'b0;
    spi_cs_n = 1'b1;
    spi_mosi = 1'b0;
    cmd_ready = 1'b1;
    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (5) @(negedge clk);

    spi_write_word(16'h0010, 32'h1234_5678);
    spi_read_word(16'h0010, read_value);
    if (spi_error || read_value != 32'h1234_5678) begin
      $error("register transaction failed: error=%0b data=%08x", spi_error, read_value);
      errors++;
    end

    spi_command_stream5(32'h1001_0203, 32'h1112_1314, 32'h2122_2324,
                        32'h3132_3334, 32'h4142_4344);
    repeat (4) @(negedge clk);
    if (spi_error || received_count != 5 ||
        received_commands[0] != 32'h1001_0203 ||
        received_commands[1] != 32'h1112_1314 ||
        received_commands[2] != 32'h2122_2324 ||
        received_commands[3] != 32'h3132_3334 ||
        received_commands[4] != 32'h4142_4344) begin
      $error("command stream failed: error=%0b count=%0d", spi_error, received_count);
      errors++;
    end

    cmd_ready = 1'b0;
    begin_transaction(8'ha5);
    spi_send_word(32'hdead_beef);
    end_transaction();
    if (!spi_error || received_count != 5) begin
      $error("command overflow was not reported");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: SPI bridge errors=%0d", errors);
    $display("PASS: SPI register and command-stream bridge");
    $finish;
  end
endmodule
