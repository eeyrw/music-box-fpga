module smart_artix_top (
  input  logic clk_in,
  input  logic rst_n,

  input  logic spi_sclk,
  input  logic spi_cs_n,
  input  logic spi_mosi,
  output logic spi_miso,

  output logic i2s_bclk,
  output logic i2s_lrclk,
  output logic i2s_sdata,

  output logic led_spi_error,
  output logic led_underrun,
  output logic led_sample_drop,
  output logic led_deadline_miss
);
  localparam int LINE_WORDS = 8;
  localparam int OUTPUT_FIFO_DEPTH = 8;
  localparam int MIG_ADDR_WIDTH = 28;
  localparam int MIG_DATA_WIDTH = LINE_WORDS * 16;
  localparam int SYS_CLK_HZ = 49_152_000;
  localparam int SAMPLE_RATE_HZ = 48_000;

  logic clk_sys;
  logic rst_sys;

  // Replace this direct assignment with an MMCM/PLL once the board oscillator is
  // confirmed. wavetable_core_system assumes SYS_CLK_HZ for audio tick timing.
  assign clk_sys = clk_in;
  assign rst_sys = !rst_n;

  logic                     ext_req_valid;
  logic                     ext_req_ready;
  logic [31:0]              ext_req_addr;
  logic                     ext_rsp_valid;
  logic [LINE_WORDS*16-1:0] ext_rsp_data;
  logic                     underrun_pulse;
  logic                     sample_drop_pulse;
  logic                     render_deadline_miss_pulse;
  logic [15:0]              render_latency_cycles;
  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level;
  logic                     mem_debug_hit_pulse;
  logic                     mem_debug_miss_pulse;
  logic                     mem_debug_response_pulse;
  logic [15:0]              mem_debug_response_latency;
  logic                     mig_init_calib_complete;
  logic [MIG_ADDR_WIDTH-1:0] mig_app_addr;
  logic [2:0]               mig_app_cmd;
  logic                     mig_app_en;
  logic                     mig_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] mig_app_rd_data;
  logic                     mig_app_rd_data_valid;
  logic                     mig_app_rd_data_end;

  // Replace this read-path stub with the generated MIG DDR3 controller once
  // Vivado is available. The stub lets the board wrapper lint and simulate
  // without vendor IP.
  smart_artix_mig_stub #(
    .ADDR_WIDTH(MIG_ADDR_WIDTH),
    .DATA_WIDTH(MIG_DATA_WIDTH),
    .INIT_CALIB_CYCLES(16),
    .READ_LATENCY_CYCLES(6)
  ) mig_stub (
    .clk(clk_sys),
    .rst(rst_sys),
    .init_calib_complete(mig_init_calib_complete),
    .app_addr(mig_app_addr),
    .app_cmd(mig_app_cmd),
    .app_en(mig_app_en),
    .app_rdy(mig_app_rdy),
    .app_rd_data(mig_app_rd_data),
    .app_rd_data_valid(mig_app_rd_data_valid),
    .app_rd_data_end(mig_app_rd_data_end)
  );

  smart_artix_ddr3_line_reader #(
    .LINE_WORDS(LINE_WORDS),
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH),
    .WORD_ADDR_SHIFT(1)
  ) ddr3_line_reader (
    .clk(clk_sys),
    .rst(rst_sys),
    .line_req_valid(ext_req_valid),
    .line_req_ready(ext_req_ready),
    .line_req_addr(ext_req_addr),
    .line_rsp_valid(ext_rsp_valid),
    .line_rsp_data(ext_rsp_data),
    .mig_init_calib_complete(mig_init_calib_complete),
    .mig_app_addr(mig_app_addr),
    .mig_app_cmd(mig_app_cmd),
    .mig_app_en(mig_app_en),
    .mig_app_rdy(mig_app_rdy),
    .mig_app_rd_data(mig_app_rd_data),
    .mig_app_rd_data_valid(mig_app_rd_data_valid),
    .mig_app_rd_data_end(mig_app_rd_data_end)
  );

  wavetable_core_system #(
    .LINE_WORDS(LINE_WORDS),
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) core_system (
    .clk(clk_sys),
    .rst(rst_sys),
    .spi_sclk(spi_sclk),
    .spi_cs_n(spi_cs_n),
    .spi_mosi(spi_mosi),
    .spi_miso(spi_miso),
    .spi_error(led_spi_error),
    .ext_req_valid(ext_req_valid),
    .ext_req_ready(ext_req_ready),
    .ext_req_addr(ext_req_addr),
    .ext_rsp_valid(ext_rsp_valid),
    .ext_rsp_data(ext_rsp_data),
    .i2s_bclk(i2s_bclk),
    .i2s_lrclk(i2s_lrclk),
    .i2s_sdata(i2s_sdata),
    .underrun_pulse(underrun_pulse),
    .sample_drop_pulse(sample_drop_pulse),
    .mem_debug_hit_pulse(mem_debug_hit_pulse),
    .mem_debug_miss_pulse(mem_debug_miss_pulse),
    .mem_debug_response_pulse(mem_debug_response_pulse),
    .mem_debug_response_latency(mem_debug_response_latency),
    .output_fifo_level(output_fifo_level),
    .render_deadline_miss_pulse(render_deadline_miss_pulse),
    .render_latency_cycles(render_latency_cycles)
  );

  assign led_underrun = underrun_pulse;
  assign led_sample_drop = sample_drop_pulse;
  assign led_deadline_miss = render_deadline_miss_pulse;

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_debug;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_debug = ext_req_valid ^ (^ext_req_addr) ^ (^output_fifo_level)
      ^ (^render_latency_cycles) ^ mem_debug_hit_pulse ^ mem_debug_miss_pulse
      ^ mem_debug_response_pulse ^ (^mem_debug_response_latency) ^ (^mig_app_addr)
      ^ (^mig_app_cmd) ^ mig_app_en;
endmodule
