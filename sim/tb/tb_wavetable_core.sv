module tb_wavetable_core;
  import synth_pkg::*;

  // Self-checking unit test for the wavetable datapath. It uses tiny synthetic
  // memories so expected interpolation, envelope, gain, and mix results are exact.
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
  int errors = 0;

  // Testbench clock only; production RTL still uses one rising-edge system
  // clock and synchronous reset.
  always #5 clk = ~clk;

  wavetable_core dut (.*);

  wave_memory_model #(.DEPTH(256)) memory_model (
    .clk,
    .rst,
    .req_valid(mem_req_valid),
    .req_ready(mem_req_ready),
    .req_addr(mem_req_addr),
    .rsp_valid(mem_rsp_valid),
    .rsp_data(mem_rsp_data)
  );

  task automatic bus_write_word(input logic [15:0] address, input logic [31:0] data);
    // The register bus is single-beat: present valid/write/address/data for one
    // cycle, then verify the slave accepted it without an address error.
    @(negedge clk);
    bus_valid = 1'b1;
    bus_write = 1'b1;
    bus_address = address;
    bus_wdata = data;
    @(negedge clk);
    if (!bus_ready || bus_error) begin
      $error("bus write failed at 0x%04x", address);
      errors++;
    end
    bus_valid = 1'b0;
    bus_write = 1'b0;
  endtask

  task automatic request_and_check(input integer expected_l, input integer expected_r);
    int timeout;
    // sample_tick requests one rendered output sample. The voice pipeline needs
    // several cycles to fetch endpoints from memory before sample_valid rises.
    @(negedge clk);
    sample_tick = 1'b1;
    @(negedge clk);
    sample_tick = 1'b0;
    timeout = 0;
    while (!sample_valid && timeout < 30) begin
      @(negedge clk);
      timeout++;
    end
    if (!sample_valid) begin
      $error("sample response timed out");
      errors++;
    end else begin
      if ($signed(sample_l) !== expected_l) begin
        $error("left sample got %0d expected %0d", $signed(sample_l), expected_l);
        errors++;
      end
      if ($signed(sample_r) !== expected_r) begin
        $error("right sample got %0d expected %0d", $signed(sample_r), expected_r);
        errors++;
      end
    end
  endtask

  task automatic configure_mono;
    // Four mono frames: 0, 1000, 2000, 3000. phase_init=0.5 frame and gain=0.5,
    // so the first sample is interpolate(0,1000,0.5)*0.5 = 250.
    bus_write_word(16'h0100, 32'h0000_0001);
    bus_write_word(16'h0104, 32'd0);
    bus_write_word(16'h0108, 32'd4);
    bus_write_word(16'h010c, 32'd0);
    bus_write_word(16'h0110, 32'd4);
    bus_write_word(16'h0114, 32'h0000_8000);
    bus_write_word(16'h0118, 32'h0001_0000);
    bus_write_word(16'h011c, 32'h0000_4000);
    bus_write_word(16'h0120, 32'h0000_4000);
    bus_write_word(16'h012c, 32'h0000_7fff);
    bus_write_word(16'h0124, 32'd1);
    repeat (2) @(negedge clk);
  endtask

  task automatic configure_stereo_loop;
    // Stereo memory starts at word 16 and loops over frames [1,3). phase_init=2.5
    // uses frame2 and wraps frame3's interpolation endpoint back to frame1.
    bus_write_word(16'h0100, 32'h0000_0003);
    bus_write_word(16'h0104, 32'd16);
    bus_write_word(16'h0108, 32'd4);
    bus_write_word(16'h010c, 32'd1);
    bus_write_word(16'h0110, 32'd3);
    bus_write_word(16'h0114, 32'h0002_8000);
    bus_write_word(16'h0118, 32'h0001_0000);
    bus_write_word(16'h011c, 32'h0000_4000);
    bus_write_word(16'h0120, 32'h0000_4000);
    bus_write_word(16'h012c, 32'h0000_7fff);
    bus_write_word(16'h0124, 32'd1);
    repeat (2) @(negedge clk);
  endtask

  task automatic configure_mono_slot(
    input int voice,
    input int base_addr,
    input logic [31:0] phase_init,
    input logic signed [15:0] gain,
    input logic signed [15:0] envelope_level
  );
    logic [15:0] addr;
    begin
      addr = 16'h0100 + (voice * 16'h0040);
      bus_write_word(addr + 16'h0000, 32'h0000_0001);
      bus_write_word(addr + 16'h0004, base_addr[31:0]);
      bus_write_word(addr + 16'h0008, 32'd4);
      bus_write_word(addr + 16'h000c, 32'd0);
      bus_write_word(addr + 16'h0010, 32'd4);
      bus_write_word(addr + 16'h0014, phase_init);
      bus_write_word(addr + 16'h0018, 32'h0001_0000);
      bus_write_word(addr + 16'h001c, {{16{gain[15]}}, gain});
      bus_write_word(addr + 16'h0020, {{16{gain[15]}}, gain});
      bus_write_word(addr + 16'h002c, {{16{envelope_level[15]}}, envelope_level});
      bus_write_word(addr + 16'h0024, 32'd1);
      repeat (2) @(negedge clk);
    end
  endtask

  initial begin
    rst = 1'b1;
    bus_valid = 1'b0;
    bus_write = 1'b0;
    bus_address = '0;
    bus_wdata = '0;
    sample_tick = 1'b0;

    // Mono test wave: one signed word per sample frame.
    memory_model.memory[0] = 16'sd0;
    memory_model.memory[1] = 16'sd1000;
    memory_model.memory[2] = 16'sd2000;
    memory_model.memory[3] = 16'sd3000;

    // Stereo test wave: left/right interleaved words per frame.
    memory_model.memory[16] = 16'sd1000;
    memory_model.memory[17] = -16'sd1000;
    memory_model.memory[18] = 16'sd2000;
    memory_model.memory[19] = -16'sd2000;
    memory_model.memory[20] = 16'sd3000;
    memory_model.memory[21] = -16'sd3000;
    memory_model.memory[22] = 16'sd4000;
    memory_model.memory[23] = -16'sd4000;

    // Second mono test wave for multi-voice mixing. With gain=0.5 and
    // envelope=0.5 each frame contributes 500 to the mix.
    memory_model.memory[32] = 16'sd2000;
    memory_model.memory[33] = 16'sd2000;
    memory_model.memory[34] = 16'sd2000;
    memory_model.memory[35] = 16'sd2000;

    repeat (3) @(negedge clk);
    rst = 1'b0;

    // Check mono interpolation, gain, and the fact that mono is duplicated to
    // left/right before channel gains are applied.
    configure_mono();
    request_and_check(250, 250);
    request_and_check(750, 750);

    // A shadow-only base-address write must not disturb active playback.
    bus_write_word(16'h0104, 32'd16);
    request_and_check(1250, 1250);

    // The MCU owns envelope progression. A runtime envelope write must affect
    // the next rendered sample without committing or resetting voice phase.
    bus_write_word(16'h012c, 32'h0000_4000);
    request_and_check(375, 375);

    // Check stereo addressing and exclusive loop wrapping.
    configure_stereo_loop();
    request_and_check(1250, -1250);
    request_and_check(1250, -1250);

    // Check that two active voice slots render in one output request and the
    // mixer adds their current enveloped samples with saturation at the end.
    configure_mono_slot(0, 0, 32'h0000_8000, 16'sh4000, 16'sh7fff);
    configure_mono_slot(1, 32, 32'h0000_0000, 16'sh4000, 16'sh4000);
    request_and_check(750, 750);

    if (errors != 0)
      $fatal(1, "FAIL: %0d errors", errors);
    $display("PASS: multi-voice wavetable core");
    $finish;
  end
endmodule
