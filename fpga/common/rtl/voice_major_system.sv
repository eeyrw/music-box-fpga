module voice_major_system #(
  parameter int LINE_WORDS = synth_pkg::BLOCK_LINE_WORDS,
  parameter int OUTPUT_FIFO_DEPTH = 64,
  parameter int TARGET_LEVEL = 48,
  parameter int START_LEVEL = TARGET_LEVEL,
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000,
  parameter bit PLATFORM_REGS_PRESENT = 1'b0
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     core_rst,
  input  logic                     spi_sclk,
  input  logic                     spi_cs_n,
  input  logic                     spi_mosi,
  output logic                     spi_miso,
  output logic                     spi_error,
  output logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  output logic [31:0]              ext_req_addr,
  input  logic                     ext_rsp_valid,
  output logic                     ext_rsp_ready,
  input  logic [LINE_WORDS*16-1:0] ext_rsp_data,
  output logic                     i2s_bclk,
  output logic                     i2s_lrclk,
  output logic                     i2s_sdata,
  output logic                     underrun_pulse,
  output logic                     sample_drop_pulse,
  output logic                     mem_response_trace_pulse,
  output logic [15:0]              mem_response_trace_latency,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic                     playback_started,
  output logic                     render_inflight,
  output logic [31:0]              render_sample_counter,
  output logic [31:0]              played_sample_counter,
  output logic [31:0]              audio_lead,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] minimum_fifo_level,
  output logic                     render_deadline_miss_pulse,
  output logic [15:0]              render_latency_cycles,
  output logic                     platform_regs_bus_valid,
  output logic                     platform_regs_bus_write,
  output logic [15:0]              platform_regs_bus_address,
  output logic [31:0]              platform_regs_bus_wdata,
  input  logic [31:0]              platform_regs_bus_rdata,
  input  logic                     platform_regs_bus_ready,
  input  logic                     platform_regs_bus_error
);
  import synth_pkg::*;

  localparam int OUTPUT_LEVEL_WIDTH = $clog2(OUTPUT_FIFO_DEPTH + 1);

  reg_bus_req_t spi_bus_req;
  reg_bus_rsp_t spi_bus_rsp;
  reg_bus_req_t core_bus_req;
  reg_bus_rsp_t core_bus_rsp;
  reg_bus_req_t common_status_bus_req;
  reg_bus_rsp_t common_status_bus_rsp;
  reg_bus_req_t platform_regs_bus_req;
  reg_bus_rsp_t platform_regs_bus_rsp;
  logic spi_cmd_valid;
  logic [31:0] spi_cmd_data;
  logic spi_cmd_ready;
  logic core_reset;

  logic block_req_valid;
  logic block_req_ready;
  render_block_req_t block_req;
  logic renderer_busy;
  logic block_complete_valid;
  logic block_complete_ready;
/* verilator lint_off UNUSEDSIGNAL */
  // The output scheduler advances its own timeline and consumes only buffer ID
  // and frame count from the completion payload.
  render_block_complete_t block_complete;
/* verilator lint_on UNUSEDSIGNAL */
  logic block_read_req_valid;
  logic block_read_req_ready;
  render_block_read_req_t block_read_req;
  logic block_read_rsp_valid;
  logic block_read_rsp_ready;
  render_block_read_rsp_t block_read_rsp;
  logic block_release_valid;
  logic block_release_ready;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] block_release_buffer_id;
  logic line_req_valid;
  logic line_req_ready;
  ordered_line_req_t line_req;
  logic line_rsp_valid;
  logic line_rsp_ready;
  ordered_line_rsp_t line_rsp;
  logic [31:0] command_error_count;
  logic [31:0] stale_generation_count;
  sample_window_diagnostics_t sample_window_diagnostics;
  global_audio_config_t audio_config;
  logic [1:0] effect_clear;

  logic output_fifo_room;
  logic scheduler_sample_valid;
  logic core_sample_valid;
  logic core_sample_ready;
  pcm_t core_sample_l;
  pcm_t core_sample_r;
  logic effects_input_ready;
  logic effects_busy;
  logic i2s_sample_ready;
  logic fifo_sample_valid;
  audio_diagnostics_t audio_diagnostics;

  logic ext_rsp_pending_q;
  logic [LINE_WORDS*16-1:0] ext_rsp_data_q;
  logic [15:0] memory_latency_q;
  logic memory_request_pending_q;

  initial begin
    if (LINE_WORDS != BLOCK_LINE_WORDS)
      $error("voice_major_system requires an eight-word line interface");
    if (TARGET_LEVEL < MAX_BLOCK_FRAMES)
      $error("TARGET_LEVEL must hold at least one render block");
  end

  assign core_reset = rst || core_rst;
  assign platform_regs_bus_valid = platform_regs_bus_req.valid;
  assign platform_regs_bus_write = platform_regs_bus_req.write;
  assign platform_regs_bus_address = platform_regs_bus_req.address;
  assign platform_regs_bus_wdata = platform_regs_bus_req.wdata;
  assign platform_regs_bus_rsp.rdata = platform_regs_bus_rdata;
  assign platform_regs_bus_rsp.ready = platform_regs_bus_ready;
  assign platform_regs_bus_rsp.error = platform_regs_bus_error;

  assign output_fifo_room = output_fifo_level <=
      OUTPUT_LEVEL_WIDTH'(TARGET_LEVEL - MAX_BLOCK_FRAMES);
  // One elastic response register decouples the board reader from the ordered
  // window interface. External backpressure prevents response overwrite.
  assign ext_req_valid = line_req_valid;
  assign ext_req_addr = line_req.aligned_line_addr;
  assign line_req_ready = ext_req_ready;
  assign ext_rsp_ready = !ext_rsp_pending_q || line_rsp_ready;
  assign line_rsp_valid = ext_rsp_pending_q;
  assign line_rsp.words = ext_rsp_data_q;

  spi_register_bridge spi_bridge (
    .clk,
    .rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso,
    .spi_error,
    .bus_valid(spi_bus_req.valid),
    .bus_write(spi_bus_req.write),
    .bus_address(spi_bus_req.address),
    .bus_wdata(spi_bus_req.wdata),
    .bus_rdata(spi_bus_rsp.rdata),
    .bus_ready(spi_bus_rsp.ready),
    .bus_error(spi_bus_rsp.error),
    .cmd_valid(spi_cmd_valid),
    .cmd_data(spi_cmd_data),
    .cmd_ready(spi_cmd_ready)
  );

  wavetable_register_fabric #(
    .PLATFORM_REGS_PRESENT(PLATFORM_REGS_PRESENT)
  ) register_fabric (
    .master_req(spi_bus_req),
    .core_reset,
    .master_rsp(spi_bus_rsp),
    .core_req(core_bus_req),
    .core_rsp(core_bus_rsp),
    .common_status_req(common_status_bus_req),
    .common_status_rsp(common_status_bus_rsp),
    .platform_regs_req(platform_regs_bus_req),
    .platform_regs_rsp(platform_regs_bus_rsp)
  );

  wavetable_common_status_regs #(
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
  ) common_status_regs (
    .clk,
    .rst,
    .core_reset,
    .bus_req(common_status_bus_req),
    .bus_rsp(common_status_bus_rsp),
    .core_sample_valid,
    .core_busy(renderer_busy),
    .render_inflight,
    .render_deadline_miss_pulse,
    .render_latency_cycles,
    .ext_req_valid,
    .ext_req_ready,
    .ext_rsp_valid,
    .i2s_sample_ready,
    .fifo_sample_valid,
    .underrun_pulse,
    .sample_drop_pulse,
    .mem_response_trace_pulse,
    .mem_response_trace_latency,
    .output_fifo_level,
    .audio_diagnostics,
    .sample_window_diagnostics
  );

  voice_major_render_core core (
    .clk,
    .rst(core_reset),
    .bus_req(core_bus_req),
    .bus_rsp(core_bus_rsp),
    .cmd_stream_valid(spi_cmd_valid),
    .cmd_stream_data(spi_cmd_data),
    .cmd_stream_ready(spi_cmd_ready),
    .command_error_count,
    .stale_generation_count,
    .audio_config,
    .effect_clear,
    .block_req_valid,
    .block_req_ready,
    .block_req,
    .render_busy(renderer_busy),
    .line_req_valid,
    .line_req_ready,
    .line_req,
    .line_rsp_valid,
    .line_rsp_ready,
    .line_rsp,
    .block_complete_valid,
    .block_complete_ready,
    .block_complete,
    .block_read_req_valid,
    .block_read_req_ready,
    .block_read_req,
    .block_read_rsp_valid,
    .block_read_rsp_ready,
    .block_read_rsp,
    .block_release_valid,
    .block_release_ready,
    .block_release_buffer_id,
    .sample_window_diagnostics
  );

  voice_major_output_scheduler #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) output_scheduler (
    .clk,
    .rst(core_reset),
    .output_fifo_room,
    .block_req_valid,
    .block_req_ready,
    .block_req,
    .renderer_busy,
    .block_complete_valid,
    .block_complete_ready,
    .block_complete,
    .block_read_req_valid,
    .block_read_req_ready,
    .block_read_req,
    .block_read_rsp_valid,
    .block_read_rsp_ready,
    .block_release_valid,
    .block_release_ready,
    .block_release_buffer_id,
    .sample_valid(scheduler_sample_valid),
    .sample_ready(effects_input_ready),
    .effects_busy,
    .render_inflight,
    .render_deadline_miss_pulse,
    .render_latency_cycles
  );

  global_audio_effects_chain effects (
    .clk,
    .rst(core_reset),
    .effect_clear_i(effect_clear),
    .config_i(audio_config),
    .in_valid(scheduler_sample_valid),
    .in_ready(effects_input_ready),
    .in_l(block_read_rsp.sample.l),
    .in_r(block_read_rsp.sample.r),
    .out_valid(core_sample_valid),
    .out_ready(core_sample_ready),
    .out_l(core_sample_l),
    .out_r(core_sample_r),
    .busy(effects_busy),
    .diagnostics_o(audio_diagnostics)
  );

  wavetable_i2s_output #(
    .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
    .START_LEVEL(START_LEVEL),
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) audio_output (
    .clk,
    .rst(core_reset),
    .sample_valid(core_sample_valid),
    .sample_ready(core_sample_ready),
    .sample_l(core_sample_l),
    .sample_r(core_sample_r),
    .i2s_sample_ready,
    .fifo_sample_valid,
    .underrun_pulse,
    .sample_drop_pulse,
    .output_fifo_level,
    .playback_started,
    .render_sample_counter,
    .played_sample_counter,
    .audio_lead,
    .minimum_fifo_level,
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata
  );

  always_ff @(posedge clk) begin
    if (core_reset) begin
      ext_rsp_pending_q <= 1'b0;
      ext_rsp_data_q <= '0;
      memory_latency_q <= '0;
      memory_request_pending_q <= 1'b0;
      mem_response_trace_pulse <= 1'b0;
      mem_response_trace_latency <= '0;
    end else begin
      mem_response_trace_pulse <= 1'b0;
      if (line_rsp_valid && line_rsp_ready)
        ext_rsp_pending_q <= 1'b0;
      if (ext_rsp_valid && ext_rsp_ready) begin
        ext_rsp_pending_q <= 1'b1;
        ext_rsp_data_q <= ext_rsp_data;
        mem_response_trace_pulse <= 1'b1;
        mem_response_trace_latency <= memory_latency_q;
        memory_request_pending_q <= 1'b0;
      end
      if (ext_req_valid && ext_req_ready) begin
        memory_request_pending_q <= 1'b1;
        memory_latency_q <= '0;
      end else if (memory_request_pending_q && memory_latency_q != 16'hffff) begin
        memory_latency_q <= memory_latency_q + 1'b1;
      end
    end
  end

  logic unused_control_status;
  assign unused_control_status = (|command_error_count) |
      (|stale_generation_count);
endmodule
