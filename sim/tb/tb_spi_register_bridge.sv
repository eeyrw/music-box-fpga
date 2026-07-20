module tb_spi_register_bridge;
  import synth_pkg::*;
  import synth_register_pkg::*;

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
  logic frame_boundary;
  logic [31:0] bus_rdata;
  logic bus_ready;
  logic bus_error;
  reg_bus_req_t bus_req;
  reg_bus_rsp_t bus_rsp;
  logic [$clog2(NUM_VOICES)-1:0] render_voice_index;
  voice_config_t render_config;
  voice_runtime_t render_runtime;
  logic [NUM_VOICES-1:0] config_valid;
  logic [NUM_VOICES-1:0] commit_pulse;
  logic unused_register_outputs;
  int errors = 0;
  localparam logic [15:0] INVALID_VERSION_NEIGHBOR_0 = REG_VERSION + 16'h0004;
  localparam logic [15:0] INVALID_VERSION_NEIGHBOR_1 = REG_VERSION + 16'h0008;

  always #5 clk <= ~clk;

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

  assign bus_req.valid = bus_valid;
  assign bus_req.write = bus_write;
  assign bus_req.address = bus_address;
  assign bus_req.wdata = bus_wdata;
  assign bus_rdata = bus_rsp.rdata;
  assign bus_ready = bus_rsp.ready;
  assign bus_error = bus_rsp.error;

  voice_register_bank registers (
    .clk,
    .rst,
    .bus_req,
    .frame_boundary,
    .bus_rsp,
    .render_voice_index,
    .render_config,
    .render_runtime,
    .config_valid,
    .commit_pulse
  );

  assign unused_register_outputs = (|render_voice_index) | (|render_runtime) |
                                   (|config_valid[NUM_VOICES-1:1]) |
                                   (|render_config) | (|commit_pulse);

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

  task automatic spi_write_burst4(input logic [15:0] address,
                                  input logic [31:0] data0,
                                  input logic [31:0] data1,
                                  input logic [31:0] data2,
                                  input logic [31:0] data3);
    spi_cs_n = 1'b0;
    repeat (3) @(negedge clk);
    spi_send_byte(8'hc0);
    spi_send_byte(address[15:8]);
    spi_send_byte(address[7:0]);
    spi_send_byte(data0[31:24]);
    spi_send_byte(data0[23:16]);
    spi_send_byte(data0[15:8]);
    spi_send_byte(data0[7:0]);
    repeat (8) @(negedge clk);
    spi_send_byte(data1[31:24]);
    spi_send_byte(data1[23:16]);
    spi_send_byte(data1[15:8]);
    spi_send_byte(data1[7:0]);
    repeat (8) @(negedge clk);
    spi_send_byte(data2[31:24]);
    spi_send_byte(data2[23:16]);
    spi_send_byte(data2[15:8]);
    spi_send_byte(data2[7:0]);
    repeat (8) @(negedge clk);
    spi_send_byte(data3[31:24]);
    spi_send_byte(data3[23:16]);
    spi_send_byte(data3[15:8]);
    spi_send_byte(data3[7:0]);
    repeat (8) @(negedge clk);
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

  task automatic spi_read_data_word(output logic [31:0] data);
    data = '0;
    for (int b = 31; b >= 0; b--) begin
      repeat (2) @(negedge clk);
      spi_sclk = 1'b1;
      repeat (2) @(negedge clk);
      data[b] = spi_miso;
      spi_sclk = 1'b0;
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic spi_read_burst4(input logic [15:0] address,
                                 output logic [31:0] data0,
                                 output logic [31:0] data1,
                                 output logic [31:0] data2,
                                 output logic [31:0] data3);
    spi_cs_n = 1'b0;
    repeat (3) @(negedge clk);
    spi_send_byte(8'h40);
    spi_send_byte(address[15:8]);
    spi_send_byte(address[7:0]);
    repeat (8) @(negedge clk);
    spi_read_data_word(data0);
    repeat (8) @(negedge clk);
    spi_read_data_word(data1);
    repeat (8) @(negedge clk);
    spi_read_data_word(data2);
    repeat (8) @(negedge clk);
    spi_read_data_word(data3);
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

  task automatic expect_burst_read4(input logic [15:0] address,
                                    input logic [31:0] expected0,
                                    input logic [31:0] expected1,
                                    input logic [31:0] expected2,
                                    input logic [31:0] expected3);
    logic [31:0] actual0;
    logic [31:0] actual1;
    logic [31:0] actual2;
    logic [31:0] actual3;
    spi_read_burst4(address, actual0, actual1, actual2, actual3);
    if ((actual0 !== expected0) || (actual1 !== expected1) ||
        (actual2 !== expected2) || (actual3 !== expected3)) begin
      $error("SPI burst read 0x%04x got 0x%08x 0x%08x 0x%08x 0x%08x expected 0x%08x 0x%08x 0x%08x 0x%08x",
             address, actual0, actual1, actual2, actual3,
             expected0, expected1, expected2, expected3);
      errors++;
    end
    if (spi_error) begin
      $error("SPI burst read 0x%04x unexpectedly reported error", address);
      errors++;
    end
  endtask

  task automatic expect_read_error(input logic [15:0] address);
    logic [31:0] actual;
    spi_read_word(address, actual);
    if (!spi_error) begin
      $error("SPI read 0x%04x got 0x%08x but did not report expected error", address, actual);
      errors++;
    end
  endtask

  task automatic publish_frame_boundary;
    @(negedge clk);
    frame_boundary = 1'b1;
    @(negedge clk);
    frame_boundary = 1'b0;
  endtask

  task automatic write_expect(input logic [15:0] address,
                              input logic [31:0] write_data,
                              input logic [31:0] expected_read);
    spi_write_word(address, write_data);
    if (spi_error) begin
      $error("SPI write 0x%04x unexpectedly reported error", address);
      errors++;
    end
    expect_read(address, expected_read);
  endtask

  initial begin
    rst = 1'b1;
    frame_boundary = 1'b0;
    spi_sclk = 1'b0;
    spi_cs_n = 1'b1;
    spi_mosi = 1'b0;
    render_voice_index = '0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (5) @(negedge clk);

    spi_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR), 32'h1234_5678);
    if (spi_error) begin
      $error("SPI write unexpectedly reported error");
      errors++;
    end
    expect_read(REG_VERSION, REG_VERSION_VALUE);
    expect_read(reg_voice_addr(0, REG_OFF_BASE_ADDR), 32'h1234_5678);
    expect_read_error(INVALID_VERSION_NEIGHBOR_0);
    expect_read_error(INVALID_VERSION_NEIGHBOR_1);
    expect_read_error(reg_voice_addr(1, 16'h0070));
    expect_read_error(reg_voice_addr(1, 16'h0074));

    expect_read(reg_voice_addr(1, REG_OFF_STATUS), 32'h0000_0000);
    write_expect(reg_voice_addr(1, REG_OFF_BASE_ADDR), 32'h89ab_cdef, 32'h89ab_cdef);
    write_expect(reg_voice_addr(1, REG_OFF_LENGTH), 32'hff12_3456, 32'h0012_3456);
    write_expect(reg_voice_addr(1, REG_OFF_LOOP_START), 32'hff00_0011, 32'h0000_0011);
    write_expect(reg_voice_addr(1, REG_OFF_LOOP_END), 32'hff00_0044, 32'h0000_0044);
    write_expect(reg_voice_addr(1, REG_OFF_PHASE_INIT), 32'h7654_3210, 32'h7654_3210);
    write_expect(reg_voice_addr(1, REG_OFF_PHASE_INC), 32'h0102_0304, 32'h0102_0304);
    write_expect(reg_voice_addr(1, REG_OFF_GAIN), 32'h7ffe_8001, 32'h7ffe_8001);
    write_expect(reg_voice_addr(1, REG_OFF_ENVELOPE), 32'h0000_8000, 32'hffff_8000);
    write_expect(reg_voice_addr(1, REG_OFF_PHASE_INC_RUNTIME), 32'h0100_0200, 32'h0100_0200);
    write_expect(reg_voice_addr(1, REG_OFF_VOICE_CONTROL), 32'hffff_ffff, REG_VOICE_CONTROL_MASK);
    write_expect(reg_voice_addr(1, REG_OFF_FILTER_CONTROL), 32'hffff_ffff, REG_FILTER_CONTROL_ENABLE_MASK);
    write_expect(reg_voice_addr(1, REG_OFF_FILTER_B0_B1), 32'h1111_2222, 32'h1111_2222);
    write_expect(reg_voice_addr(1, REG_OFF_FILTER_B2_A1), 32'h5555_6666, 32'h5555_6666);
    write_expect(reg_voice_addr(1, REG_OFF_FILTER_A2), 32'h9999_aaaa, 32'h0000_aaaa);
    write_expect(reg_voice_addr(1, REG_OFF_GAIN_RUNTIME), 32'h8001_7ffe, 32'h8001_7ffe);
    write_expect(reg_voice_addr(1, REG_OFF_RELEASE_CONTROL), 32'h0000_0001, 32'h0000_0001);
    write_expect(reg_voice_addr(1, REG_OFF_BASE_ADDR_R), 32'h0123_4567, 32'h0123_4567);
    write_expect(reg_voice_addr(1, REG_OFF_LENGTH_R), 32'hffab_cdef, 32'h00ab_cdef);
    write_expect(reg_voice_addr(1, REG_OFF_LOOP_START_R), 32'hff00_0022, 32'h0000_0022);
    write_expect(reg_voice_addr(1, REG_OFF_LOOP_END_R), 32'hff00_0055, 32'h0000_0055);

    spi_write_burst4(reg_voice_addr(2, REG_OFF_BASE_ADDR),
                     32'h1111_0000, 32'h2222_0004,
                     32'hff00_0008, 32'hff00_000c);
    if (spi_error) begin
      $error("SPI burst write unexpectedly reported error");
      errors++;
    end
    expect_burst_read4(reg_voice_addr(2, REG_OFF_BASE_ADDR),
                       32'h1111_0000, 32'h2222_0004,
                       32'h0000_0008, 32'h0000_000c);

    spi_write_word(reg_voice_addr(0, REG_OFF_LENGTH), 32'h0000_0004);
    spi_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE_RUNTIME), 32'h0000_4000);
    spi_write_word(reg_voice_addr(0, REG_OFF_FILTER_CONTROL), 32'h0000_0001);
    spi_write_word(reg_voice_addr(0, REG_OFF_FILTER_B0_B1), 32'h0000_2000);
    spi_write_word(reg_voice_addr(0, REG_OFF_VOICE_CONTROL), REG_VOICE_CONTROL_ENABLE_MASK);
    expect_read(reg_voice_addr(0, REG_OFF_LENGTH), 32'h0000_0004);
    expect_read(reg_voice_addr(0, REG_OFF_ENVELOPE_RUNTIME), 32'h0000_4000);
    expect_read(reg_voice_addr(0, REG_OFF_FILTER_CONTROL), 32'h0000_0001);
    expect_read(reg_voice_addr(0, REG_OFF_FILTER_B0_B1), 32'h0000_2000);
    spi_write_word(reg_voice_addr(0, REG_OFF_VOICE_CONTROL),
                   REG_VOICE_CONTROL_ENABLE_MASK | REG_VOICE_CONTROL_APPLY_MASK);
    repeat (80) @(negedge clk);
    publish_frame_boundary();
    @(negedge clk);
    if (!config_valid[0] || (render_config.length !== 24'd4)) begin
      $error("SPI commit did not update active voice configuration");
      errors++;
    end
    expect_read(reg_voice_addr(0, REG_OFF_STATUS), 32'h0000_0001);
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
