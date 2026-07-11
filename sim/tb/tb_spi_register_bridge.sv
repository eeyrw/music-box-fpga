module tb_spi_register_bridge;
  import synth_pkg::*;

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
  voice_config_t active_config [NUM_VOICES];
  logic [NUM_VOICES-1:0] config_valid;
  logic [NUM_VOICES-1:0] commit_pulse;
  int errors = 0;

  always #5 clk = ~clk;

  spi_register_bridge bridge (
    .clk,
    .rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso,
    .spi_error,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error
  );

  voice_register_bank registers (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .active_config,
    .config_valid,
    .commit_pulse
  );

  task automatic spi_clock_bit(input logic bit_value);
    spi_mosi = bit_value;
    repeat (2) @(negedge clk);
    spi_sclk = 1'b1;
    repeat (2) @(negedge clk);
    spi_sclk = 1'b0;
    repeat (2) @(negedge clk);
  endtask

  task automatic spi_send_byte(input logic [7:0] value);
    for (int b = 7; b >= 0; b--)
      spi_clock_bit(value[b]);
  endtask

  task automatic spi_write_word(input logic [15:0] address, input logic [31:0] data);
    spi_cs_n = 1'b0;
    repeat (3) @(negedge clk);
    spi_send_byte(8'h80);
    spi_send_byte(address[15:8]);
    spi_send_byte(address[7:0]);
    spi_send_byte(data[31:24]);
    spi_send_byte(data[23:16]);
    spi_send_byte(data[15:8]);
    spi_send_byte(data[7:0]);
    repeat (4) @(negedge clk);
    spi_cs_n = 1'b1;
    repeat (4) @(negedge clk);
  endtask

  task automatic spi_read_word(input logic [15:0] address, output logic [31:0] data);
    data = '0;
    spi_cs_n = 1'b0;
    repeat (3) @(negedge clk);
    spi_send_byte(8'h00);
    spi_send_byte(address[15:8]);
    spi_send_byte(address[7:0]);
    repeat (6) @(negedge clk);
    for (int b = 31; b >= 0; b--) begin
      repeat (2) @(negedge clk);
      spi_sclk = 1'b1;
      repeat (2) @(negedge clk);
      data[b] = spi_miso;
      spi_sclk = 1'b0;
      repeat (2) @(negedge clk);
    end
    repeat (4) @(negedge clk);
    spi_cs_n = 1'b1;
    repeat (4) @(negedge clk);
  endtask

  task automatic expect_read(input logic [15:0] address, input logic [31:0] expected);
    logic [31:0] actual;
    spi_read_word(address, actual);
    if (actual !== expected) begin
      $error("SPI read 0x%04x got 0x%08x expected 0x%08x", address, actual, expected);
      errors++;
    end
    if (spi_error) begin
      $error("SPI read 0x%04x unexpectedly reported error", address);
      errors++;
    end
  endtask

  initial begin
    rst = 1'b1;
    spi_sclk = 1'b0;
    spi_cs_n = 1'b1;
    spi_mosi = 1'b0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (5) @(negedge clk);

    spi_write_word(16'h0104, 32'h1234_5678);
    if (spi_error) begin
      $error("SPI write unexpectedly reported error");
      errors++;
    end
    expect_read(16'h0104, 32'h1234_5678);
    expect_read(16'h3000, 32'h0002_0000);

    spi_write_word(16'h0108, 32'h0000_0004);
    spi_write_word(16'h0134, 32'h0000_0000);
    spi_write_word(16'h0124, 32'h0000_0001);
    if (!config_valid[0] || (active_config[0].length !== 16'd4)) begin
      $error("SPI commit did not update active voice configuration");
      errors++;
    end
    if (^commit_pulse === 1'bx) begin
      $error("commit_pulse contains unknown bits");
      errors++;
    end

    spi_write_word(16'hffff, 32'h0000_0001);
    if (!spi_error) begin
      $error("invalid SPI write did not report error");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: %0d errors", errors);
    $display("PASS: SPI register bridge");
    $finish;
  end
endmodule
