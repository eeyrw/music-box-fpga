module tb_render_wavetable_core;
  import synth_pkg::*;

`include "render_config.svh"

  logic clk = 1'b0;
  logic rst;
  logic bus_valid;
  logic bus_write;
  logic [15:0] bus_address;
  logic [31:0] bus_wdata;
  logic [31:0] bus_rdata;
  logic bus_ready;
  logic bus_error;
  logic sample_tick;
  logic sample_valid;
  pcm_t sample_l;
  pcm_t sample_r;
  logic busy;
  logic mem_req_valid;
  logic [31:0] mem_req_addr;
  logic mem_req_ready;
  logic mem_rsp_valid;
  pcm_t mem_rsp_data;
  logic unused_status;
  int pcm_fd;
  int produced;

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
/* verilator lint_on BLKSEQ */

  assign unused_status = |bus_rdata | busy;

  wavetable_core dut (.*);

  wave_memory_model #(.DEPTH(RENDER_MEMORY_DEPTH)) memory_model (
    .clk,
    .rst,
    .req_valid(mem_req_valid),
    .req_ready(mem_req_ready),
    .req_addr(mem_req_addr),
    .rsp_valid(mem_rsp_valid),
    .rsp_data(mem_rsp_data)
  );

  task automatic bus_write_word(input logic [15:0] address, input logic [31:0] data);
    @(negedge clk);
    bus_valid = 1'b1;
    bus_write = 1'b1;
    bus_address = address;
    bus_wdata = data;
    @(negedge clk);
    if (!bus_ready || bus_error)
      $fatal(1, "bus write failed at 0x%04x", address);
    bus_valid = 1'b0;
    bus_write = 1'b0;
  endtask

  task automatic write_pcm16(input pcm_t sample);
    logic [15:0] word;
    begin
      word = sample;
      $fwrite(pcm_fd, "%c%c", word[7:0], word[15:8]);
    end
  endtask

  task automatic request_sample;
    int timeout;
    begin
      @(negedge clk);
      sample_tick = 1'b1;
      @(negedge clk);
      sample_tick = 1'b0;
      timeout = 0;
      while (!sample_valid && timeout < 64) begin
        @(negedge clk);
        timeout++;
      end
      if (!sample_valid)
        $fatal(1, "sample response timed out at output sample %0d", produced);
      write_pcm16(sample_l);
      write_pcm16(sample_r);
      produced++;
    end
  endtask

  initial begin
    rst = 1'b1;
    bus_valid = 1'b0;
    bus_write = 1'b0;
    bus_address = '0;
    bus_wdata = '0;
    sample_tick = 1'b0;
    produced = 0;

    $readmemh(RENDER_MEMH, memory_model.memory);
    pcm_fd = $fopen(RENDER_PCM, "wb");
    if (pcm_fd == 0)
      $fatal(1, "failed to open %s", RENDER_PCM);

    repeat (3) @(negedge clk);
    rst = 1'b0;

    bus_write_word(16'h0100, (RENDER_STEREO != 0) ? 32'h0000_0003 : 32'h0000_0001);
    bus_write_word(16'h0104, RENDER_BASE_ADDR);
    bus_write_word(16'h0108, RENDER_LENGTH);
    bus_write_word(16'h010c, RENDER_LOOP_START);
    bus_write_word(16'h0110, RENDER_LOOP_END);
    bus_write_word(16'h0114, 32'h0000_0000);
    bus_write_word(16'h0118, RENDER_PHASE_INC);
    bus_write_word(16'h011c, RENDER_GAIN_L);
    bus_write_word(16'h0120, RENDER_GAIN_R);
    bus_write_word(16'h0124, 32'd1);
    repeat (2) @(negedge clk);

    while (produced < RENDER_SAMPLE_COUNT)
      request_sample();

    $fclose(pcm_fd);
    $display("PASS: rendered %0d stereo samples to %s", produced, RENDER_PCM);
    $finish;
  end
endmodule
