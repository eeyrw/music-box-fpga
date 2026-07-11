module tb_render_midi_core;
  import synth_pkg::*;

`include "midi_render_config.svh"

  localparam int ENV_SILENT  = 0;
  localparam int ENV_ATTACK  = 1;
  localparam int ENV_DECAY   = 2;
  localparam int ENV_SUSTAIN = 3;
  localparam int ENV_RELEASE = 4;
  localparam int Q15_FULL = 32'd32767;
  localparam int SUSTAIN_NUM = 100;
  localparam int SUSTAIN_DEN = 128;

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
  int event_index;
  int next_adsr_sample;
  int alloc_stamp;
  int voice_note [NUM_VOICES];
  int voice_state [NUM_VOICES];
  int voice_level [NUM_VOICES];
  int voice_target [NUM_VOICES];
  int voice_sustain [NUM_VOICES];
  int voice_stamp [NUM_VOICES];

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
/* verilator lint_on BLKSEQ */

  assign unused_status = |bus_rdata | busy;

  wavetable_core dut (.*);

  wave_memory_model #(.DEPTH(MIDI_MEMORY_DEPTH)) memory_model (
    .clk,
    .rst,
    .req_valid(mem_req_valid),
    .req_ready(mem_req_ready),
    .req_addr(mem_req_addr),
    .rsp_valid(mem_rsp_valid),
    .rsp_data(mem_rsp_data)
  );

  function automatic logic [15:0] voice_addr(input int voice, input int offset);
    voice_addr = 16'(32'h0000_0100 + (voice * 32'h0000_0040) + offset);
  endfunction

  function automatic int clamp_q15(input int value);
    if (value <= 0)
      clamp_q15 = 0;
    else if (value >= Q15_FULL)
      clamp_q15 = Q15_FULL;
    else
      clamp_q15 = value;
  endfunction

  function automatic int velocity_target(input int velocity);
    int vel;
    begin
      vel = velocity;
      if (vel < 0)
        vel = 0;
      else if (vel > 127)
        vel = 127;
      velocity_target = (vel * Q15_FULL + 63) / 127;
    end
  endfunction

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

  task automatic set_envelope(input int voice, input int q15_level);
    logic [15:0] level_word;
    begin
      level_word = 16'(clamp_q15(q15_level));
      bus_write_word(voice_addr(voice, 32'h0000_002c), {16'd0, level_word});
    end
  endtask

  task automatic commit_voice(input int voice, input int enable, input int phase_inc);
    bus_write_word(voice_addr(voice, 32'h0000_0000), (MIDI_STEREO != 0) ? {30'd0, 1'b1, (enable != 0)} : {31'd0, (enable != 0)});
    bus_write_word(voice_addr(voice, 32'h0000_0004), MIDI_BASE_ADDR);
    bus_write_word(voice_addr(voice, 32'h0000_0008), MIDI_LENGTH);
    bus_write_word(voice_addr(voice, 32'h0000_000c), MIDI_LOOP_START);
    bus_write_word(voice_addr(voice, 32'h0000_0010), MIDI_LOOP_END);
    bus_write_word(voice_addr(voice, 32'h0000_0014), 32'h0000_0000);
    bus_write_word(voice_addr(voice, 32'h0000_0018), phase_inc[31:0]);
    bus_write_word(voice_addr(voice, 32'h0000_001c), MIDI_GAIN_L);
    bus_write_word(voice_addr(voice, 32'h0000_0020), MIDI_GAIN_R);
    bus_write_word(voice_addr(voice, 32'h0000_0024), 32'd1);
  endtask

  task automatic note_off(input int note);
    for (int v = 0; v < NUM_VOICES; v++) begin
      if (voice_state[v] != ENV_SILENT && voice_note[v] == (note & 32'h0000_007f))
        voice_state[v] = ENV_RELEASE;
    end
  endtask

  task automatic note_on(input int note, input int velocity, input int phase_inc);
    int idx;
    int best;
    begin
      if (velocity == 0) begin
        note_off(note);
      end else begin
        idx = -1;
        for (int v = 0; v < NUM_VOICES; v++) begin
          if (idx < 0 && voice_state[v] == ENV_SILENT)
            idx = v;
        end
        if (idx < 0) begin
          best = 0;
          for (int v = 1; v < NUM_VOICES; v++) begin
            if (((voice_stamp[v] - voice_stamp[best]) & 32'h0000_00ff) >= 128)
              best = v;
          end
          idx = best;
        end

        alloc_stamp = (alloc_stamp + 1) & 32'h0000_00ff;
        if (alloc_stamp == 0)
          alloc_stamp = 1;

        voice_note[idx] = note & 32'h0000_007f;
        voice_state[idx] = ENV_ATTACK;
        voice_level[idx] = 0;
        voice_target[idx] = velocity_target(velocity);
        voice_sustain[idx] = (voice_target[idx] * SUSTAIN_NUM) / SUSTAIN_DEN;
        voice_stamp[idx] = alloc_stamp;
        set_envelope(idx, 0);
        commit_voice(idx, 1, phase_inc);
      end
    end
  endtask

  task automatic envelope_tick;
    int next_level;
    begin
      for (int v = 0; v < NUM_VOICES; v++) begin
        next_level = voice_level[v];
        if (voice_state[v] == ENV_ATTACK) begin
          next_level = voice_level[v] + MIDI_ADSR_ATTACK_STEP;
          if (next_level >= voice_target[v]) begin
            next_level = voice_target[v];
            voice_state[v] = ENV_DECAY;
          end
        end else if (voice_state[v] == ENV_DECAY) begin
          next_level = voice_level[v] - MIDI_ADSR_DECAY_STEP;
          if (next_level <= voice_sustain[v]) begin
            next_level = voice_sustain[v];
            voice_state[v] = ENV_SUSTAIN;
          end
        end else if (voice_state[v] == ENV_RELEASE) begin
          next_level = voice_level[v] - MIDI_ADSR_RELEASE_STEP;
          if (next_level <= 0) begin
            next_level = 0;
            voice_state[v] = ENV_SILENT;
            commit_voice(v, 0, 0);
          end
        end

        if (voice_state[v] != ENV_SILENT || voice_level[v] != 0) begin
          voice_level[v] = clamp_q15(next_level);
          set_envelope(v, voice_level[v]);
        end
      end
    end
  endtask

  task automatic process_events;
    while (event_index < MIDI_EVENT_COUNT && MIDI_EVENT_SAMPLE[event_index] <= produced) begin
      if (MIDI_EVENT_ON[event_index] != 0)
        note_on(MIDI_EVENT_KEY[event_index], MIDI_EVENT_VELOCITY[event_index], MIDI_EVENT_PHASE_INC[event_index]);
      else
        note_off(MIDI_EVENT_KEY[event_index]);
      event_index++;
    end
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
      while (!sample_valid && timeout < 160) begin
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
    event_index = 0;
    next_adsr_sample = 0;
    alloc_stamp = 0;
    for (int v = 0; v < NUM_VOICES; v++) begin
      voice_note[v] = 0;
      voice_state[v] = ENV_SILENT;
      voice_level[v] = 0;
      voice_target[v] = 0;
      voice_sustain[v] = 0;
      voice_stamp[v] = 0;
    end

    $readmemh(MIDI_MEMH, memory_model.memory);
    pcm_fd = $fopen(MIDI_PCM, "wb");
    if (pcm_fd == 0)
      $fatal(1, "failed to open %s", MIDI_PCM);

    repeat (3) @(negedge clk);
    rst = 1'b0;

    while (produced < MIDI_SAMPLE_COUNT) begin
      process_events();
      while (produced >= next_adsr_sample) begin
        envelope_tick();
        next_adsr_sample += MIDI_ADSR_TICK_SAMPLES;
      end
      request_sample();
    end

    $fclose(pcm_fd);
    $display("PASS: rendered %0d MIDI-driven stereo samples to %s", produced, MIDI_PCM);
    $finish;
  end
endmodule
