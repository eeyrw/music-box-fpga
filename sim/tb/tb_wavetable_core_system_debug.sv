module tb_wavetable_core_system_debug;
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
  logic platform_ddr_init_calib_complete;
  logic platform_ddr_ui_rst;
  logic [11:0] platform_ddr_device_temp;
  logic platform_mig_app_rdy;
  logic platform_mig_app_wdf_rdy;
  logic platform_mig_app_rd_data_valid;
  logic platform_mig_app_rd_data_end;
  logic platform_sd_initialized;
  logic platform_asset_loaded;
  logic platform_asset_loader_busy;
  logic [3:0] platform_asset_loader_state;
  logic [7:0] platform_sd_error_code;
  logic [7:0] platform_loader_error_code;
  logic [63:0] platform_bytes_loaded;
  logic [63:0] platform_sf2_size_bytes;
  logic [31:0] platform_current_lba;
  logic platform_ddr_debug_start;
  logic platform_ddr_debug_write;
  logic [31:0] platform_ddr_debug_addr;
  logic [127:0] platform_ddr_debug_wdata;
  logic [15:0] platform_ddr_debug_byte_enable;
  logic platform_ddr_debug_ready;
  logic platform_ddr_debug_busy;
  logic platform_ddr_debug_done;
  logic platform_ddr_debug_error;
  logic [127:0] platform_ddr_debug_rdata;
  int errors = 0;

  always #5 clk = ~clk;

  wavetable_core_system #(
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
    .platform_ddr_init_calib_complete,
    .platform_ddr_ui_rst,
    .platform_ddr_device_temp,
    .platform_mig_app_rdy,
    .platform_mig_app_wdf_rdy,
    .platform_mig_app_rd_data_valid,
    .platform_mig_app_rd_data_end,
    .platform_sd_initialized,
    .platform_asset_loaded,
    .platform_asset_loader_busy,
    .platform_asset_loader_state,
    .platform_sd_error_code,
    .platform_loader_error_code,
    .platform_bytes_loaded,
    .platform_sf2_size_bytes,
    .platform_current_lba,
    .platform_ddr_debug_start,
    .platform_ddr_debug_write,
    .platform_ddr_debug_addr,
    .platform_ddr_debug_wdata,
    .platform_ddr_debug_byte_enable,
    .platform_ddr_debug_ready,
    .platform_ddr_debug_busy,
    .platform_ddr_debug_done,
    .platform_ddr_debug_error,
    .platform_ddr_debug_rdata
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
    platform_ddr_init_calib_complete = 1'b1;
    platform_ddr_ui_rst = 1'b0;
    platform_ddr_device_temp = 12'h2a5;
    platform_mig_app_rdy = 1'b1;
    platform_mig_app_wdf_rdy = 1'b0;
    platform_mig_app_rd_data_valid = 1'b1;
    platform_mig_app_rd_data_end = 1'b0;
    platform_sd_initialized = 1'b1;
    platform_asset_loaded = 1'b1;
    platform_asset_loader_busy = 1'b0;
    platform_asset_loader_state = 4'ha;
    platform_sd_error_code = 8'h12;
    platform_loader_error_code = 8'h34;
    platform_bytes_loaded = 64'h1122_3344_5566_7788;
    platform_sf2_size_bytes = 64'h99aa_bbcc_ddee_ff00;
    platform_current_lba = 32'h1234_5678;
    platform_ddr_debug_ready = 1'b1;
    platform_ddr_debug_busy = 1'b0;
    platform_ddr_debug_done = 1'b0;
    platform_ddr_debug_error = 1'b0;
    platform_ddr_debug_rdata = 128'hfedc_ba98_7654_3210_89ab_cdef_0123_4567;
    core_rst = 1'b0;

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (5) @(negedge clk);

    core_rst = 1'b1;
    platform_asset_loaded = 1'b0;
    platform_asset_loader_busy = 1'b1;
    platform_asset_loader_state = 4'h5;
    platform_bytes_loaded = 64'h0000_0000_0000_1000;
    expect_read(16'h3040, 32'h0000_2ad7);
    expect_read(16'h3048, 32'h0000_1000);
    spi_write_word(16'h0000, 32'h0000_0001);
    if (!spi_error) begin
      $error("core register write during core reset did not report error");
      errors++;
    end

    core_rst = 1'b0;
    platform_asset_loaded = 1'b1;
    platform_asset_loader_busy = 1'b0;
    platform_asset_loader_state = 4'ha;
    platform_bytes_loaded = 64'h1122_3344_5566_7788;
    repeat (2) @(negedge clk);

    expect_read(16'h3000, 32'h0005_0000);
    expect_read(16'h3010, 32'h0000_0050);
    expect_read(16'h3014, 32'h0000_0000);
    expect_read(16'h3018, 32'h0000_0000);
    expect_read(16'h3024, 32'h0000_0000);
    expect_read(16'h3040, 32'h0000_52b7);
    expect_read(16'h3044, 32'h000a_3412);
    expect_read(16'h3048, 32'h5566_7788);
    expect_read(16'h304c, 32'h1122_3344);
    expect_read(16'h3050, 32'hddee_ff00);
    expect_read(16'h3054, 32'h99aa_bbcc);
    expect_read(16'h3058, 32'h1234_5678);
    expect_read(16'h305c, 32'h02a5_0015);
    expect_read(16'h3064, 32'h0000_0003);
    spi_write_word(16'h3068, 32'h0000_0100);
    spi_write_word(16'h306c, 32'h0000_00ff);
    spi_write_word(16'h3070, 32'h0123_4567);
    spi_write_word(16'h3074, 32'h89ab_cdef);
    spi_write_word(16'h3078, 32'h7654_3210);
    spi_write_word(16'h307c, 32'hfedc_ba98);
    spi_write_word(16'h3060, 32'h0000_0003);
    if (!platform_ddr_debug_write || platform_ddr_debug_addr != 32'h0000_0100 ||
        platform_ddr_debug_byte_enable != 16'h00ff ||
        platform_ddr_debug_wdata != 128'hfedc_ba98_7654_3210_89ab_cdef_0123_4567) begin
      $error("DDR debug register write state mismatch write=%0b addr=0x%08x be=0x%04x wdata=0x%032x",
             platform_ddr_debug_write, platform_ddr_debug_addr,
             platform_ddr_debug_byte_enable, platform_ddr_debug_wdata);
      errors++;
    end
    platform_ddr_debug_ready = 1'b0;
    platform_ddr_debug_busy = 1'b1;
    expect_read(16'h3064, 32'h0000_0025);
    platform_ddr_debug_ready = 1'b1;
    platform_ddr_debug_busy = 1'b0;
    platform_ddr_debug_done = 1'b1;
    @(negedge clk);
    platform_ddr_debug_done = 1'b0;
    expect_read(16'h3064, 32'h0000_002b);
    expect_read(16'h3070, 32'h0123_4567);
    expect_read(16'h3074, 32'h89ab_cdef);
    expect_read(16'h3078, 32'h7654_3210);
    expect_read(16'h307c, 32'hfedc_ba98);
    spi_write_word(16'h3060, 32'h0000_0004);
    expect_read(16'h3064, 32'h0000_0023);
    spi_write_word(16'h3014, 32'h0000_003f);
    if (spi_error) begin
      $error("system debug flag clear unexpectedly reported error");
      errors++;
    end
    expect_read(16'h3014, 32'h0000_0000);

    if (errors != 0)
      $fatal(1, "FAIL: wavetable_core_system_debug errors=%0d", errors);

    $display("PASS: wavetable_core_system_debug");
    $finish;
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_outputs;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_outputs = ext_req_valid | (|ext_req_addr) | i2s_bclk | i2s_lrclk | i2s_sdata |
      underrun_pulse | sample_drop_pulse | mem_debug_hit_pulse | mem_debug_miss_pulse |
      mem_debug_response_pulse | (|mem_debug_response_latency) | (|output_fifo_level) |
      render_deadline_miss_pulse | (|render_latency_cycles) | platform_ddr_debug_start;
endmodule
