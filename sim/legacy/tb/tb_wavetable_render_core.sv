module tb_wavetable_render_core;
  import synth_pkg::*;
  import synth_register_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic bus_valid;
  logic bus_write;
  logic [15:0] bus_address;
  logic [31:0] bus_wdata;
  logic [31:0] bus_rdata;
  logic bus_ready;
  logic bus_error;
  logic cmd_stream_valid;
  logic [31:0] cmd_stream_data;
  logic cmd_stream_ready;
  logic sample_tick;
  logic sample_valid;
  pcm_t sample_l;
  pcm_t sample_r;
  logic busy;
  mix_t mix_l;
  mix_t mix_r;
  global_audio_config_t audio_config;
  logic [1:0] effect_clear;
  wave_word_req_t mem_req;
  logic mem_req_ready;
  wave_word_rsp_t mem_rsp;
  logic ext_req_valid;
  logic ext_req_ready;
  logic [31:0] ext_req_addr;
  logic ext_rsp_valid;
  localparam int LINE_WORDS = 32;
  logic [LINE_WORDS*16-1:0] ext_rsp_data;
  cache_diagnostics_t cache_diagnostics;
  voice_pipeline_diagnostics_t voice_diagnostics;
  int errors = 0;
  int last_latency_cycles = 0;
  int memory_request_count = 0;
  string current_case = "startup";
  localparam int SAMPLE_TIMEOUT_CYCLES = 512 + (NUM_VOICES * 16);

  always #5 clk <= ~clk;

  always_ff @(posedge clk) begin
    if (rst)
      memory_request_count <= 0;
    else if (mem_req.valid && mem_req_ready)
      memory_request_count <= memory_request_count + 1;
  end

  wavetable_render_core dut (.*);

  voice_line_cache #(.LINE_WORDS(LINE_WORDS), .LINES_PER_VOICE(2)) memory_subsystem (
    .clk, .rst, .req(mem_req), .req_ready(mem_req_ready), .rsp(mem_rsp),
    .ext_req_valid, .ext_req_ready, .ext_req_addr, .ext_rsp_valid, .ext_rsp_data,
    .diagnostics_o(cache_diagnostics)
  );

  line_memory_model #(.DEPTH(256), .LINE_WORDS(LINE_WORDS), .LATENCY(4)) memory_model (
    .clk, .rst, .req_valid(ext_req_valid), .req_ready(ext_req_ready),
    .req_addr(ext_req_addr), .rsp_valid(ext_rsp_valid), .rsp_data(ext_rsp_data)
  );

  function automatic logic [31:0] header(
    input command_opcode_t opcode,
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic [7:0] words
  );
    header = {opcode, voice, seq, words};
  endfunction

  task automatic begin_case(input string name);
    current_case = name;
    $display("CASE: %s", current_case);
  endtask

  task automatic reset_core;
    rst = 1'b1;
    cmd_stream_valid = 1'b0;
    sample_tick = 1'b0;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
  endtask

  task automatic push_word(input logic [31:0] data);
    @(negedge clk);
    while (!cmd_stream_ready) @(negedge clk);
    cmd_stream_data = data;
    cmd_stream_valid = 1'b1;
    @(negedge clk);
    cmd_stream_valid = 1'b0;
  endtask

  task automatic wait_command_parse;
    repeat (40) @(negedge clk);
  endtask

  task automatic bus_write_word(input logic [15:0] address, input logic [31:0] data);
    @(negedge clk);
    bus_address = address;
    bus_wdata = data;
    bus_write = 1'b1;
    bus_valid = 1'b1;
    @(negedge clk);
    if (!bus_ready || bus_error) begin
      $error("debug bus write failed at %h", address);
      errors++;
    end
    bus_valid = 1'b0;
    bus_write = 1'b0;
  endtask

  task automatic bus_read_word(input logic [15:0] address, output logic [31:0] data);
    @(negedge clk);
    bus_address = address;
    bus_write = 1'b0;
    bus_valid = 1'b1;
    @(negedge clk);
    data = bus_rdata;
    if (!bus_ready || bus_error) begin
      $error("debug bus read failed at %h", address);
      errors++;
    end
    bus_valid = 1'b0;
  endtask

  task automatic define_mono(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input int base_addr,
    input int length,
    input int loop_start,
    input int loop_end,
    input logic [31:0] phase_init,
    input logic [1:0] loop_mode,
    input logic filter_enable,
    input logic signed [15:0] b0,
    input logic signed [15:0] b1,
    input logic signed [15:0] b2,
    input logic signed [15:0] a1,
    input logic signed [15:0] a2
  );
    push_word(header(VOICE_DEFINE_MONO, voice, seq, 8'd11));
    push_word(base_addr[31:0]);
    push_word(length[31:0]);
    push_word(loop_start[31:0]);
    push_word(loop_end[31:0]);
    push_word(phase_init);
    push_word({30'd0, loop_mode});
    push_word({b1, b0});
    push_word({a1, b2});
    push_word({15'd0, filter_enable, a2});
    push_word(32'd0);
    push_word(32'd0);
  endtask

  task automatic define_stereo(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input int base_l,
    input int base_r,
    input int length_l,
    input int length_r,
    input int loop_start_l,
    input int loop_start_r,
    input int loop_end_l,
    input int loop_end_r,
    input logic [31:0] phase_init,
    input logic [1:0] loop_mode
  );
    push_word(header(VOICE_DEFINE_STEREO, voice, seq, 8'd15));
    push_word(base_l[31:0]);
    push_word(base_r[31:0]);
    push_word(length_l[31:0]);
    push_word(length_r[31:0]);
    push_word(loop_start_l[31:0]);
    push_word(loop_start_r[31:0]);
    push_word(loop_end_l[31:0]);
    push_word(loop_end_r[31:0]);
    push_word(phase_init);
    push_word({30'd0, loop_mode});
    push_word(32'h0000_4000);
    push_word(32'd0);
    push_word(32'd0);
    push_word(32'd0);
    push_word(32'd0);
  endtask

  task automatic start_voice(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic signed [15:0] gain_l,
    input logic signed [15:0] gain_r,
    input logic [31:0] phase_inc
  );
    start_voice_envelope(voice, seq, gain_l, gain_r, phase_inc,
                         24'd0, 32'd0, 24'd0, 32'd0, 32'd0,
                         32'h0100_0000);
  endtask

  task automatic start_voice_envelope(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic signed [15:0] gain_l,
    input logic signed [15:0] gain_r,
    input logic [31:0] phase_inc,
    input logic [23:0] delay_samples,
    input logic [31:0] attack_step,
    input logic [23:0] hold_samples,
    input logic [31:0] decay_step,
    input logic [31:0] sustain_cb,
    input logic [31:0] release_step
  );
    push_word(header(VOICE_START, voice, seq, 8'd8));
    push_word({gain_r, gain_l});
    push_word(phase_inc);
    push_word({8'd0, delay_samples});
    push_word(attack_step);
    push_word({8'd0, hold_samples});
    push_word(decay_step);
    push_word(sustain_cb);
    push_word(release_step);
  endtask

  task automatic define_start_mono(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input int base_addr,
    input int length,
    input int loop_start,
    input int loop_end,
    input logic [31:0] phase_init,
    input logic [31:0] phase_inc,
    input logic [1:0] loop_mode,
    input logic signed [15:0] gain,
    input logic filter_enable,
    input logic signed [15:0] b0,
    input logic signed [15:0] b1,
    input logic signed [15:0] b2,
    input logic signed [15:0] a1,
    input logic signed [15:0] a2
  );
    define_mono(voice, seq, base_addr, length, loop_start, loop_end, phase_init,
                loop_mode, filter_enable, b0, b1, b2, a1, a2);
    start_voice(voice, seq, gain, gain, phase_inc);
    wait_command_parse();
  endtask

  task automatic gain_phase(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic signed [15:0] gain_l,
    input logic signed [15:0] gain_r,
    input logic [31:0] phase_inc
  );
    push_word(header(VOICE_GAIN_PHASE, voice, seq, 8'd2));
    push_word({gain_r, gain_l});
    push_word(phase_inc);
    wait_command_parse();
  endtask

  task automatic update_filter(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic enable,
    input logic signed [15:0] b0,
    input logic signed [15:0] b1,
    input logic signed [15:0] b2,
    input logic signed [15:0] a1,
    input logic signed [15:0] a2
  );
    push_word(header(VOICE_FILTER, voice, seq, 8'd3));
    push_word({b1, b0});
    push_word({a1, b2});
    push_word({15'd0, enable, a2});
    wait_command_parse();
  endtask

  task automatic release_voice(
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic [31:0] release_step
  );
    push_word(header(VOICE_RELEASE, voice, seq, 8'd1));
    push_word(release_step);
    wait_command_parse();
  endtask

  task automatic request_and_check(input integer expected_l, input integer expected_r);
    int timeout;
    @(negedge clk);
    sample_tick = 1'b1;
    @(negedge clk);
    sample_tick = 1'b0;
    timeout = 0;
    while (!sample_valid && timeout < SAMPLE_TIMEOUT_CYCLES) begin
      @(negedge clk);
      timeout++;
    end
    last_latency_cycles = timeout;
    if (!sample_valid) begin
      $error("[%s] sample response timed out", current_case);
      errors++;
    end else begin
      if ($signed(sample_l) !== expected_l) begin
        $error("[%s] left sample got %0d expected %0d", current_case, $signed(sample_l), expected_l);
        errors++;
      end
      if ($signed(sample_r) !== expected_r) begin
        $error("[%s] right sample got %0d expected %0d", current_case, $signed(sample_r), expected_r);
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    bus_valid = 1'b0;
    bus_write = 1'b0;
    bus_address = '0;
    bus_wdata = '0;
    cmd_stream_valid = 1'b0;
    cmd_stream_data = '0;
    sample_tick = 1'b0;

    memory_model.memory[0] = 16'sd0;
    memory_model.memory[1] = 16'sd1000;
    memory_model.memory[2] = 16'sd2000;
    memory_model.memory[3] = 16'sd3000;
    memory_model.memory[16] = 16'sd1000;
    memory_model.memory[17] = 16'sd2000;
    memory_model.memory[18] = 16'sd3000;
    memory_model.memory[19] = 16'sd4000;
    memory_model.memory[24] = -16'sd1000;
    memory_model.memory[25] = -16'sd2000;
    memory_model.memory[26] = -16'sd3000;
    memory_model.memory[27] = -16'sd4000;
    memory_model.memory[28] = -16'sd5000;
    for (int a = 32; a < 68; a++)
      memory_model.memory[a] = 16'sd2000;
    for (int a = 72; a < 76; a++)
      memory_model.memory[a] = 16'sd30000;

    begin_case("mono command start and interpolation");
    reset_core();
    define_start_mono(0, 8'h01, 0, 4, 0, 4, 32'h0000_0080, 32'h0000_0100,
                      LOOP_MODE_CONTINUOUS, 16'sh4000, 1'b0,
                      16'sh4000, 0, 0, 0, 0);
    request_and_check(250, 250);
    request_and_check(750, 750);

    begin_case("define isolation from active voice");
    define_mono(0, 8'h02, 32, 4, 0, 4, 0, LOOP_MODE_CONTINUOUS,
                1'b0, 16'sh4000, 0, 0, 0, 0);
    wait_command_parse();
    request_and_check(1250, 1250);

    begin_case("atomic gain phase update without phase reload");
    reset_core();
    define_start_mono(0, 8'h11, 0, 4, 0, 4, 0, 32'h0000_0100,
                      LOOP_MODE_CONTINUOUS, 16'sh7fff, 1'b0,
                      16'sh4000, 0, 0, 0, 0);
    request_and_check(0, 0);
    gain_phase(0, 8'h11, 16'sh4000, 16'sh4000, 32'h0000_0200);
    request_and_check(500, 500);
    request_and_check(1500, 1500);

    begin_case("stereo independent exclusive loops");
    reset_core();
    define_stereo(0, 8'h21, 16, 24, 4, 5, 1, 2, 3, 5,
                  32'h0000_0200, LOOP_MODE_CONTINUOUS);
    start_voice(0, 8'h21, 16'sh7fff, 16'sh7fff, 32'h0000_0100);
    wait_command_parse();
    request_and_check(2999, -3000);
    request_and_check(1999, -4000);
    request_and_check(2999, -5000);

    begin_case("no-loop completion");
    reset_core();
    define_start_mono(0, 8'h31, 0, 2, 0, 0, 0, 32'h0000_0100,
                      LOOP_MODE_NONE, 16'sh7fff, 1'b0,
                      16'sh4000, 0, 0, 0, 0);
    request_and_check(0, 0);
    request_and_check(999, 999);
    request_and_check(0, 0);

    begin_case("loop until release command");
    reset_core();
    define_start_mono(0, 8'h41, 0, 4, 1, 3, 32'h0000_0200, 32'h0000_0100,
                      LOOP_MODE_UNTIL_RELEASE, 16'sh7fff, 1'b0,
                      16'sh4000, 0, 0, 0, 0);
    request_and_check(1999, 1999);
    request_and_check(999, 999);
    release_voice(0, 8'h41, 32'd1);
    request_and_check(1999, 1999);
    request_and_check(2999, 2999);
    request_and_check(0, 0);

    begin_case("filter command and runtime replacement");
    reset_core();
    define_start_mono(0, 8'h51, 32, 4, 0, 4, 0, 32'h0000_0100,
                      LOOP_MODE_CONTINUOUS, 16'sh7fff, 1'b1,
                      16'sh2000, 16'sh2000, 0, 0, 0);
    request_and_check(999, 999);
    request_and_check(1999, 1999);
    update_filter(0, 8'h51, 1'b1, 16'sh4000, 0, 0, 0, 0);
    request_and_check(2999, 2999);

    begin_case("filter output remains wide until gain");
    reset_core();
    define_start_mono(0, 8'h61, 72, 4, 0, 4, 0, 32'h0000_0100,
                      LOOP_MODE_CONTINUOUS, 16'sh4000, 1'b1,
                      16'sh6000, 0, 0, 0, 0);
    request_and_check(22500, 22500);

    begin_case("silent delay advances phase without memory or filter work");
    begin
      int requests_before;
      logic signed [FILTER_STATE_WIDTH-1:0] prior_filter_z2;
      logic [31:0] debug_status;
      logic [31:0] debug_envelope;

      reset_core();
      memory_model.memory[2] = 16'sd3000;
      memory_model.memory[3] = 16'sd6000;
      define_start_mono(0, 8'h68, 0, 4, 1, 3, 32'h0000_0080,
                        32'h0000_0100, LOOP_MODE_CONTINUOUS, 16'sh7fff, 1'b1,
                        16'sh2000, 0, 16'sh2000, 0, 0);
      request_and_check(249, 249);
      prior_filter_z2 = dut.voices.filter_z2_l[0];
      if (prior_filter_z2 == '0) begin
        $error("[%s] filter setup did not create history", current_case);
        errors++;
      end

      define_mono(0, 8'h69, 0, 4, 1, 3, 32'h0000_0240,
                  LOOP_MODE_CONTINUOUS, 1'b1,
                  16'sh2000, 0, 16'sh2000, 0, 0);
      start_voice_envelope(0, 8'h69, 16'sh7fff, 16'sh7fff,
                           32'h0000_0100, 24'd2, 32'h8000_0000,
                           24'd0, 32'd0, 32'd0, 32'h0100_0000);
      wait_command_parse();

      requests_before = memory_request_count;
      request_and_check(0, 0);
      if (memory_request_count != requests_before) begin
        $error("[%s] delay issued %0d memory requests", current_case,
               memory_request_count - requests_before);
        errors++;
      end
      if (dut.voices.phase[0] != 32'h0000_0140) begin
        $error("[%s] delay phase did not advance and wrap: %h", current_case,
               dut.voices.phase[0]);
        errors++;
      end
      if (dut.voices.filter_z2_l[0] != prior_filter_z2) begin
        $error("[%s] delay changed filter history", current_case);
        errors++;
      end

      bus_write_word(REG_DEBUG_VOICE_INDEX, 32'd0);
      bus_write_word(REG_DEBUG_VOICE_CAPTURE, 32'd1);
      debug_status = 32'd1;
      while (debug_status[0])
        bus_read_word(REG_DEBUG_VOICE_STATUS, debug_status);
      if (!debug_status[3] || !debug_status[4] ||
          debug_status[8:6] != ENV_DELAY) begin
        $error("[%s] delayed voice was not active and audible: %h",
               current_case, debug_status);
        errors++;
      end
      bus_read_word(REG_DEBUG_VOICE_ENVELOPE, debug_envelope);
      if (!debug_envelope[19] || debug_envelope[18:16] != ENV_DELAY) begin
        $error("[%s] delayed envelope debug state mismatch: %h",
               current_case, debug_envelope);
        errors++;
      end

      requests_before = memory_request_count;
      request_and_check(0, 0);
      if (memory_request_count == requests_before) begin
        $error("[%s] first Attack sample did not enter the sample pipeline",
               current_case);
        errors++;
      end
      if (dut.voices.phase[0] != 32'h0000_0240) begin
        $error("[%s] first Attack phase mismatch: %h", current_case,
               dut.voices.phase[0]);
        errors++;
      end
      request_and_check(624, 624);
    end

    begin_case("highest voice command addressing");
    reset_core();
    define_start_mono(8'(NUM_VOICES - 1), 8'h71, 32, 4, 0, 4, 0, 32'h0000_0100,
                      LOOP_MODE_CONTINUOUS, 16'sh4000, 1'b0,
                      16'sh4000, 0, 0, 0, 0);
    request_and_check(1000, 1000);

    begin_case("low-cost voice debug snapshot");
    begin
      logic [31:0] debug_status;
      logic [31:0] debug_data;
      bus_write_word(REG_DEBUG_VOICE_INDEX, 32'(NUM_VOICES - 1));
      bus_write_word(REG_DEBUG_VOICE_CAPTURE, 32'd1);
      debug_status = 32'd1;
      while (debug_status[0])
        bus_read_word(REG_DEBUG_VOICE_STATUS, debug_status);
      if (!debug_status[1] || !debug_status[2] || !debug_status[3] ||
          !debug_status[4] || debug_status[24:17] != 8'h71) begin
        $error("debug snapshot status mismatch: %h", debug_status);
        errors++;
      end
      bus_read_word(REG_DEBUG_VOICE_BASE_L, debug_data);
      if (debug_data != 32'd32) begin
        $error("debug snapshot base mismatch: %h", debug_data);
        errors++;
      end
      bus_read_word(REG_DEBUG_VOICE_PHASE_INC, debug_data);
      if (debug_data != 32'h0000_0100) begin
        $error("debug snapshot phase increment mismatch: %h", debug_data);
        errors++;
      end
      bus_read_word(REG_DEBUG_VOICE_GAIN, debug_data);
      if (debug_data != 32'h4000_4000) begin
        $error("debug snapshot gain mismatch: %h", debug_data);
        errors++;
      end
      bus_read_word(REG_DEBUG_VOICE_ENVELOPE, debug_data);
      if (debug_data[15:0] != 16'h0000 || !debug_data[19] ||
          debug_data[18:16] != ENV_SUSTAIN) begin
        $error("debug snapshot envelope mismatch: %h", debug_data);
        errors++;
      end
      bus_read_word(REG_DEBUG_ENV_ATTENUATION, debug_data);
      if (debug_data != 32'd0) begin
        $error("debug snapshot attenuation mismatch: %h", debug_data);
        errors++;
      end
    end

    begin_case("two voice command mix");
    reset_core();
    define_mono(0, 8'h81, 0, 4, 0, 4, 32'h0000_0080, LOOP_MODE_CONTINUOUS,
                1'b0, 16'sh4000, 0, 0, 0, 0);
    start_voice(0, 8'h81, 16'sh4000, 16'sh4000, 32'h0000_0100);
    define_mono(1, 8'h82, 32, 4, 0, 4, 0, LOOP_MODE_CONTINUOUS,
                1'b0, 16'sh4000, 0, 0, 0, 0);
    start_voice(1, 8'h82, 16'sh4000, 16'sh4000, 32'h0000_0100);
    wait_command_parse();
    request_and_check(1250, 1250);

    if (errors != 0)
      $fatal(1, "FAIL: %0d errors", errors);
    $display("PASS: transactional multi-voice wavetable core");
    $finish;
  end
endmodule
