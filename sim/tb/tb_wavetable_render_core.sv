module tb_wavetable_render_core;
  import synth_pkg::*;
  import synth_register_pkg::*;

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
  wave_word_req_t core_mem_req;
  wave_word_rsp_t core_mem_rsp;
  logic ext_req_valid;
  logic ext_req_ready;
  logic [31:0] ext_req_addr;
  logic ext_rsp_valid;
  logic [8*16-1:0] ext_rsp_data;
  logic mem_response_trace_pulse;
  logic [15:0] mem_response_trace_latency;
  logic unused_mem_trace;
  int errors = 0;
  int last_latency_cycles = 0;
  string current_case = "startup";

  // Testbench clock only; production RTL still uses one rising-edge system
  // clock and synchronous reset.
  always #5 clk <= ~clk;

  wavetable_render_core dut (.*);

  assign core_mem_req.valid = mem_req_valid;
  assign core_mem_req.addr = mem_req_addr;
  assign mem_rsp_valid = core_mem_rsp.valid;
  assign mem_rsp_data = core_mem_rsp.data;

  assign unused_mem_trace = busy |
                            mem_response_trace_pulse | (|mem_response_trace_latency);

  wave_memory_subsystem #(.LINE_WORDS(8)) memory_subsystem (
    .clk,
    .rst,
    .core_req(core_mem_req),
    .core_req_ready(mem_req_ready),
    .core_rsp(core_mem_rsp),
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .response_trace_pulse(mem_response_trace_pulse),
    .response_trace_latency(mem_response_trace_latency)
  );

  line_memory_model #(.DEPTH(256), .LINE_WORDS(8), .LATENCY(4)) memory_model (
    .clk,
    .rst,
    .req_valid(ext_req_valid),
    .req_ready(ext_req_ready),
    .req_addr(ext_req_addr),
    .rsp_valid(ext_rsp_valid),
    .rsp_data(ext_rsp_data)
  );

  task automatic begin_case(input string name);
    current_case = name;
    $display("CASE: %s", current_case);
  endtask

  task automatic bus_write_word(input logic [15:0] address, input logic [31:0] data);
    // Hold the request until the register bank accepts it. Most writes complete
    // in one cycle; commit writes may take longer while shadow BRAM is read.
    @(negedge clk);
    bus_valid = 1'b1;
    bus_write = 1'b1;
    bus_address = address;
    bus_wdata = data;
    do begin
      @(negedge clk);
    end while (!bus_ready);
    if (!bus_ready || bus_error) begin
      $error("[%s] bus write failed at 0x%04x", current_case, address);
      errors++;
    end
    bus_valid = 1'b0;
    bus_write = 1'b0;
  endtask

  task automatic bus_read_word(input logic [15:0] address, input logic [31:0] expected);
    @(negedge clk);
    bus_valid = 1'b1;
    bus_write = 1'b0;
    bus_address = address;
    bus_wdata = '0;
    do begin
      @(negedge clk);
    end while (!bus_ready);
    if (!bus_ready || bus_error) begin
      $error("[%s] bus read failed at 0x%04x", current_case, address);
      errors++;
    end else if (bus_rdata !== expected) begin
      $error("[%s] bus read 0x%04x got 0x%08x expected 0x%08x",
             current_case, address, bus_rdata, expected);
      errors++;
    end
    bus_valid = 1'b0;
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
    while (!sample_valid && timeout < 1000) begin
      @(negedge clk);
      timeout++;
    end
    last_latency_cycles = timeout;
    if (!sample_valid) begin
      $error("[%s] sample response timed out", current_case);
      errors++;
    end else begin
      if ($signed({{16{sample_l[15]}}, sample_l}) !== expected_l) begin
        $error("[%s] left sample got %0d expected %0d",
               current_case, $signed(sample_l), expected_l);
        errors++;
      end
      if ($signed({{16{sample_r[15]}}, sample_r}) !== expected_r) begin
        $error("[%s] right sample got %0d expected %0d",
               current_case, $signed(sample_r), expected_r);
        errors++;
      end
    end
  endtask

  task automatic request_write_envelope_mid_render_and_check(
    input logic [31:0] envelope,
    input integer expected_l,
    input integer expected_r
  );
    int timeout;
    @(negedge clk);
    sample_tick = 1'b1;
    @(negedge clk);
    sample_tick = 1'b0;
    repeat (2) @(negedge clk);
    bus_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE_RUNTIME), envelope);
    timeout = 0;
    while (!sample_valid && timeout < 1000) begin
      @(negedge clk);
      timeout++;
    end
    last_latency_cycles = timeout;
    if (!sample_valid) begin
      $error("[%s] sample response timed out", current_case);
      errors++;
    end else begin
      if ($signed({{16{sample_l[15]}}, sample_l}) !== expected_l) begin
        $error("[%s] left sample got %0d expected %0d",
               current_case, $signed(sample_l), expected_l);
        errors++;
      end
      if ($signed({{16{sample_r[15]}}, sample_r}) !== expected_r) begin
        $error("[%s] right sample got %0d expected %0d",
               current_case, $signed(sample_r), expected_r);
        errors++;
      end
    end
  endtask

  function automatic logic [31:0] voice_control_word(
    input logic stereo,
    input logic [1:0] loop_mode,
    input logic enable,
    input logic apply
  );
    voice_control_word = {27'd0, apply, enable, loop_mode, stereo};
  endfunction

  task automatic configure_mono;
    // Four mono frames: 0, 1000, 2000, 3000. phase_init=0.5 frame and gain=0.5,
    // so the first sample is interpolate(0,1000,0.5)*0.5 = 250.
    bus_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR), 32'd0);
    bus_write_word(reg_voice_addr(0, REG_OFF_LENGTH), 32'd4);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_START), 32'd0);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_END), 32'd4);
    bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INIT), 32'h0000_0080);
    bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INC), 32'h0000_0100);
    bus_write_word(reg_voice_addr(0, REG_OFF_GAIN), 32'h4000_4000);
    bus_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE), 32'h0000_7fff);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_CONTROL), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B0_B1), 32'h0000_4000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B2_A1), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_A2), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_VOICE_CONTROL),
                   voice_control_word(1'b0, LOOP_MODE_CONTINUOUS, 1'b1, 1'b1));
    repeat (2) @(negedge clk);
  endtask

  task automatic configure_stereo_loop;
    // Stereo memory uses independent absolute left/right bases and loops over
    // frames [1,3). phase_init=2.5 uses frame2 and wraps frame3's interpolation
    // endpoint back to frame1.
    bus_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR), 32'd16);
    bus_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR_R), 32'd24);
    bus_write_word(reg_voice_addr(0, REG_OFF_LENGTH), 32'd4);
    bus_write_word(reg_voice_addr(0, REG_OFF_LENGTH_R), 32'd4);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_START), 32'd1);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_START_R), 32'd1);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_END), 32'd3);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_END_R), 32'd3);
    bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INIT), 32'h0000_0280);
    bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INC), 32'h0000_0100);
    bus_write_word(reg_voice_addr(0, REG_OFF_GAIN), 32'h4000_4000);
    bus_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE), 32'h0000_7fff);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_CONTROL), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B0_B1), 32'h0000_4000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B2_A1), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_A2), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_VOICE_CONTROL),
                   voice_control_word(1'b1, LOOP_MODE_CONTINUOUS, 1'b1, 1'b1));
    repeat (2) @(negedge clk);
  endtask

  task automatic configure_stereo_independent_right_loop;
    bus_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR), 32'd16);
    bus_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR_R), 32'd24);
    bus_write_word(reg_voice_addr(0, REG_OFF_LENGTH), 32'd4);
    bus_write_word(reg_voice_addr(0, REG_OFF_LENGTH_R), 32'd5);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_START), 32'd1);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_START_R), 32'd2);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_END), 32'd3);
    bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_END_R), 32'd5);
    bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INIT), 32'h0000_0200);
    bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INC), 32'h0000_0100);
    bus_write_word(reg_voice_addr(0, REG_OFF_GAIN), 32'h7fff_7fff);
    bus_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE), 32'h0000_7fff);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_CONTROL), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B0_B1), 32'h0000_4000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B2_A1), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_A2), 32'h0000_0000);
    bus_write_word(reg_voice_addr(0, REG_OFF_VOICE_CONTROL),
                   voice_control_word(1'b1, LOOP_MODE_CONTINUOUS, 1'b1, 1'b1));
    repeat (2) @(negedge clk);
  endtask

  task automatic configure_mono_slot(
    input logic [15:0] voice,
    input int base_addr,
    input logic [31:0] phase_init,
    input logic signed [15:0] gain,
    input logic signed [15:0] envelope_level
  );
    begin
      bus_write_word(reg_voice_addr(voice, REG_OFF_BASE_ADDR), base_addr[31:0]);
      bus_write_word(reg_voice_addr(voice, REG_OFF_LENGTH), 32'd4);
      bus_write_word(reg_voice_addr(voice, REG_OFF_LOOP_START), 32'd0);
      bus_write_word(reg_voice_addr(voice, REG_OFF_LOOP_END), 32'd4);
      bus_write_word(reg_voice_addr(voice, REG_OFF_PHASE_INIT), phase_init);
      bus_write_word(reg_voice_addr(voice, REG_OFF_PHASE_INC), 32'h0000_0100);
      bus_write_word(reg_voice_addr(voice, REG_OFF_GAIN), {gain, gain});
      bus_write_word(reg_voice_addr(voice, REG_OFF_ENVELOPE), {{16{envelope_level[15]}}, envelope_level});
      bus_write_word(reg_voice_addr(voice, REG_OFF_FILTER_CONTROL), 32'h0000_0000);
      bus_write_word(reg_voice_addr(voice, REG_OFF_FILTER_B0_B1), REG_FILTER_B0_UNITY_Q2_14);
      bus_write_word(reg_voice_addr(voice, REG_OFF_FILTER_B2_A1), 32'h0000_0000);
      bus_write_word(reg_voice_addr(voice, REG_OFF_FILTER_A2), 32'h0000_0000);
      bus_write_word(reg_voice_addr(voice, REG_OFF_VOICE_CONTROL),
                     voice_control_word(1'b0, LOOP_MODE_CONTINUOUS, 1'b1, 1'b1));
      repeat (2) @(negedge clk);
    end
  endtask

  task automatic configure_voice0_basic(
    input int base_addr,
    input int length,
    input int loop_start,
    input int loop_end,
    input logic [31:0] phase_init,
    input logic [31:0] phase_inc,
    input logic [1:0] loop_mode,
    input logic filter_enable,
    input logic signed [15:0] filter_b0,
    input logic signed [15:0] filter_b1,
    input logic signed [15:0] filter_b2,
    input logic signed [15:0] filter_a1,
    input logic signed [15:0] filter_a2
  );
    begin
      bus_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR), base_addr[31:0]);
      bus_write_word(reg_voice_addr(0, REG_OFF_LENGTH), length[31:0]);
      bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_START), loop_start[31:0]);
      bus_write_word(reg_voice_addr(0, REG_OFF_LOOP_END), loop_end[31:0]);
      bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INIT), phase_init);
      bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INC), phase_inc);
      bus_write_word(reg_voice_addr(0, REG_OFF_GAIN), 32'h7fff_7fff);
      bus_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE), 32'h0000_7fff);
      bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_CONTROL), {31'd0, filter_enable});
      bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B0_B1), {filter_b1, filter_b0});
      bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B2_A1), {filter_a1, filter_b2});
      bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_A2), {16'd0, filter_a2});
      bus_write_word(reg_voice_addr(0, REG_OFF_VOICE_CONTROL),
                     voice_control_word(1'b0, loop_mode, 1'b1, 1'b1));
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

    // Stereo test wave: independent absolute left and right sample regions.
    memory_model.memory[16] = 16'sd1000;
    memory_model.memory[17] = 16'sd2000;
    memory_model.memory[18] = 16'sd3000;
    memory_model.memory[19] = 16'sd4000;
    memory_model.memory[24] = -16'sd1000;
    memory_model.memory[25] = -16'sd2000;
    memory_model.memory[26] = -16'sd3000;
    memory_model.memory[27] = -16'sd4000;
    memory_model.memory[28] = -16'sd5000;

    // Second mono test wave for multi-voice mixing. With gain=0.5 and
    // envelope=0.5 each frame contributes 500 to the mix.
    memory_model.memory[32] = 16'sd2000;
    memory_model.memory[33] = 16'sd2000;
    memory_model.memory[34] = 16'sd2000;
    memory_model.memory[35] = 16'sd2000;

    for (int a = 36; a < 68; a++)
      memory_model.memory[a] = 16'sd2000;

    // Precision regression for combined gain/envelope scaling. The old two-step
    // PCM16 path produced 13; one wide product with a single final truncation
    // preserves 14.
    for (int a = 68; a < 72; a++)
      memory_model.memory[a] = 16'sd10000;

    repeat (3) @(negedge clk);
    rst = 1'b0;

    // Check mono interpolation, gain, and the fact that mono is duplicated to
    // left/right before channel gains are applied.
    begin_case("mono interpolation gain envelope");
    configure_mono();
    request_write_envelope_mid_render_and_check(32'h0000_4000, 250, 250);
    request_and_check(375, 375);
    bus_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE_RUNTIME), 32'h0000_7fff);

    // A shadow-only base-address write must not disturb active playback.
    begin_case("shadow write isolation");
    bus_write_word(reg_voice_addr(0, REG_OFF_BASE_ADDR), 32'd16);
    request_and_check(1250, 1250);

    // The MCU owns envelope progression. A runtime envelope write must affect
    // the next rendered sample without committing or resetting voice phase.
    begin_case("runtime envelope update");
    bus_write_word(reg_voice_addr(0, REG_OFF_ENVELOPE_RUNTIME), 32'h0000_4000);
    request_and_check(375, 375);

    // Runtime stereo gain writes affect both active channels atomically without a commit.
    begin_case("runtime gain update");
    bus_write_word(reg_voice_addr(0, REG_OFF_GAIN_RUNTIME), 32'h2000_2000);
    request_and_check(62, 62);

    // Channel gain and envelope are applied as one wide output gain so the
    // datapath does not lose precision to an intermediate PCM16 truncation.
    begin_case("combined gain envelope precision");
    configure_mono_slot(0, 68, 32'h0000_0000, 16'sh0100, 16'sh16f8);
    request_and_check(14, 14);

    // Check stereo addressing and exclusive loop wrapping.
    begin_case("stereo exclusive loop");
    configure_stereo_loop();
    request_and_check(1250, -1250);
    request_and_check(1250, -1250);

    // Linked stereo samples can carry different right-channel loop metadata.
    begin_case("stereo independent right loop");
    configure_stereo_independent_right_loop();
    request_and_check(2999, -3000);
    request_and_check(1999, -4000);
    request_and_check(2999, -5000);

    // Runtime PHASE_INC writes retune playback without reloading phase.
    begin_case("runtime phase increment update");
    configure_voice0_basic(0, 4, 0, 4, 32'h0000_0000, 32'h0000_0100, LOOP_MODE_CONTINUOUS,
                           1'b0, 16'sh4000, 16'sh0000, 16'sh0000, 16'sh0000, 16'sh0000);
    request_and_check(0, 0);
    bus_write_word(reg_voice_addr(0, REG_OFF_PHASE_INC_RUNTIME), 32'h0000_0200);
    request_and_check(999, 999);
    request_and_check(2999, 2999);

    // No-loop voices stop contributing once phase reaches the sample length.
    begin_case("no-loop voice completion");
    configure_voice0_basic(0, 2, 0, 0, 32'h0000_0000, 32'h0000_0100, LOOP_MODE_NONE,
                           1'b0, 16'sh4000, 16'sh0000, 16'sh0000, 16'sh0000, 16'sh0000);
    request_and_check(0, 0);
    request_and_check(999, 999);
    request_and_check(0, 0);

    // Loop-until-release wraps while held, then plays through to sample end.
    begin_case("loop until release");
    configure_voice0_basic(0, 4, 1, 3, 32'h0000_0200, 32'h0000_0100, LOOP_MODE_UNTIL_RELEASE,
                           1'b0, 16'sh4000, 16'sh0000, 16'sh0000, 16'sh0000, 16'sh0000);
    request_and_check(1999, 1999);
    request_and_check(999, 999);
    bus_write_word(reg_voice_addr(0, REG_OFF_RELEASE_CONTROL), 32'h0000_0001);
    request_and_check(1999, 1999);
    request_and_check(2999, 2999);
    request_and_check(0, 0);

    // Biquad IIR is applied after interpolation and before channel gain. This
    // coefficient set is a two-tap FIR case: y[n] = 0.5*x[n] + 0.5*x[n-1].
    begin_case("filter datapath");
    configure_voice0_basic(32, 4, 0, 4, 32'h0000_0000, 32'h0000_0100, LOOP_MODE_CONTINUOUS,
                           1'b1, 16'sh2000, 16'sh2000, 16'sh0000, 16'sh0000, 16'sh0000);
    request_and_check(999, 999);
    request_and_check(1999, 1999);

    // Runtime filter coefficients update as one committed group. Coefficient
    // writes alone update shadow state only; FILTER_A2[16] commits the packed
    // coefficient word and enable bit to the renderer-facing RAM.
    begin_case("runtime filter commit");
    configure_voice0_basic(0, 4, 0, 4, 32'h0000_0000, 32'h0000_0100, LOOP_MODE_CONTINUOUS,
                           1'b1, 16'sh2000, 16'sh0000, 16'sh0000, 16'sh0000, 16'sh0000);
    request_and_check(0, 0);
    request_and_check(499, 499);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_B0_B1), 32'sh0000_4000);
    request_and_check(999, 999);
    bus_write_word(reg_voice_addr(0, REG_OFF_FILTER_A2), REG_FILTER_A2_APPLY_MASK);
    request_and_check(2999, 2999);

    // Register decode must reach the expanded 32nd voice slot in the default
    // 32-voice build. Smaller NUM_VOICES configurations intentionally omit it.
    begin_case("highest voice register decode");
    if (NUM_VOICES >= 32) begin
      bus_write_word(reg_voice_addr(31, REG_OFF_BASE_ADDR_R), 32'h0000_0020);
    end

    // Check that two active voice slots render in one output request and the
    // mixer adds their current output-scaled samples with saturation at the end.
    begin_case("two-voice mix");
    configure_mono_slot(0, 0, 32'h0000_0080, 16'sh4000, 16'sh7fff);
    configure_mono_slot(1, 32, 32'h0000_0000, 16'sh4000, 16'sh4000);
    request_and_check(750, 750);

    // All configured voice slots can be addressed and mixed. Each contributes 15
    // after Q1.15 gain scaling.
    begin_case("all-voice mix latency");
    for (int v = 0; v < NUM_VOICES; v++)
      configure_mono_slot(16'(v), 32, 32'h0000_0000, 16'sh0100, 16'sh7fff);
    request_and_check(NUM_VOICES * 15, NUM_VOICES * 15);
    // The pipelined biquad and filter input stage spread filter math across
    // several states, so a full 32-voice active mono frame is expected to take
    // a little over 540 cycles.
    if (last_latency_cycles > (600 + NUM_VOICES)) begin
      $error("%0d-voice mono render latency got %0d cycles expected <= %0d",
             NUM_VOICES, last_latency_cycles, 600 + NUM_VOICES);
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: %0d errors", errors);
    $display("PASS: multi-voice wavetable core");
    $finish;
  end
endmodule
