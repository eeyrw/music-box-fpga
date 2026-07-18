module tb_wavetable_spi_audio_system_debug;
  import synth_register_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic core_rst;
  logic spi_sclk;
  logic spi_cs_n;
  logic spi_mosi;
  logic spi_miso;
  logic spi_error;
  logic ext_req_valid;
  logic ext_req_ready;
  logic [31:0] ext_req_addr;
  logic ext_rsp_valid;
  logic [8*16-1:0] ext_rsp_data;
  logic i2s_bclk;
  logic i2s_lrclk;
  logic i2s_sdata;
  logic underrun_pulse;
  logic sample_drop_pulse;
  logic mem_debug_hit_pulse;
  logic mem_debug_miss_pulse;
  logic mem_debug_response_pulse;
  logic [15:0] mem_debug_response_latency;
  logic [3:0] output_fifo_level;
  logic render_deadline_miss_pulse;
  logic [15:0] render_latency_cycles;
  logic debug_bus_valid;
  logic debug_bus_write;
  logic [15:0] debug_bus_address;
  logic [31:0] debug_bus_wdata;
  int errors = 0;

  always #5 clk = ~clk;

  wavetable_spi_audio_system #(
    .LINE_WORDS(8),
    .OUTPUT_FIFO_DEPTH(8),
    .SYS_CLK_HZ(1_000_000),
    .SAMPLE_RATE_HZ(1)
  ) dut (
    .clk,
    .rst,
    .core_rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso,
    .spi_error,
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata,
    .underrun_pulse,
    .sample_drop_pulse,
    .mem_debug_hit_pulse,
    .mem_debug_miss_pulse,
    .mem_debug_response_pulse,
    .mem_debug_response_latency,
    .output_fifo_level,
    .render_deadline_miss_pulse,
    .render_latency_cycles,
    .debug_bus_valid,
    .debug_bus_write,
    .debug_bus_address,
    .debug_bus_wdata,
    .debug_ext_access(1'b0),
    .debug_ext_rdata(32'd0)
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
      $error("system debug SPI read 0x%04x got 0x%08x expected 0x%08x", address, actual, expected);
      errors++;
    end
    if (spi_error) begin
      $error("system debug SPI read 0x%04x unexpectedly reported error", address);
      errors++;
    end
  endtask

  initial begin
    rst = 1'b1;
    spi_sclk = 1'b0;
    spi_cs_n = 1'b1;
    spi_mosi = 1'b0;
    ext_req_ready = 1'b1;
    ext_rsp_valid = 1'b0;
    ext_rsp_data = '0;
    core_rst = 1'b0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (5) @(negedge clk);

    core_rst = 1'b1;
    spi_write_word(16'h0000, 32'h0000_0001);
    if (!spi_error) begin
      $error("core register write during core reset did not report error");
      errors++;
    end

    core_rst = 1'b0;
    repeat (2) @(negedge clk);

    expect_read(REG_VERSION, REG_VERSION_VALUE);
    expect_read(REG_SYSTEM_STATUS, 32'h0000_0050);
    expect_read(REG_DEBUG_EVENT_FLAGS, 32'h0000_0000);
    expect_read(REG_AUDIO_STATUS, 32'h0000_0000);
    expect_read(REG_UNDERRUN_COUNT, 32'h0000_0000);
    spi_write_word(REG_DEBUG_EVENT_FLAGS,
                   REG_DEBUG_EVENT_FLAGS_UNDERRUN_MASK |
                   REG_DEBUG_EVENT_FLAGS_SAMPLE_DROP_MASK |
                   REG_DEBUG_EVENT_FLAGS_RENDER_DEADLINE_MISS_MASK |
                   REG_DEBUG_EVENT_FLAGS_MEM_HIT_MASK |
                   REG_DEBUG_EVENT_FLAGS_MEM_MISS_MASK |
                   REG_DEBUG_EVENT_FLAGS_MEM_RESPONSE_MASK);
    if (spi_error) begin
      $error("system debug flag clear unexpectedly reported error");
      errors++;
    end
    expect_read(REG_DEBUG_EVENT_FLAGS, 32'h0000_0000);

    if (errors != 0)
      $fatal(1, "FAIL: wavetable_spi_audio_system_debug errors=%0d", errors);

    $display("PASS: wavetable_spi_audio_system_debug");
    $finish;
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_outputs;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_outputs = ext_req_valid | (|ext_req_addr) | i2s_bclk | i2s_lrclk | i2s_sdata |
      underrun_pulse | sample_drop_pulse | mem_debug_hit_pulse | mem_debug_miss_pulse |
      mem_debug_response_pulse | (|mem_debug_response_latency) | (|output_fifo_level) |
      render_deadline_miss_pulse | (|render_latency_cycles) | debug_bus_valid |
      debug_bus_write | (|debug_bus_address) | (|debug_bus_wdata);
endmodule
