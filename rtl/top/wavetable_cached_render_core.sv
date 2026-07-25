module wavetable_cached_render_core #(
  parameter int LINE_WORDS = 32,
  parameter int LINES_PER_VOICE = 2,
  parameter int CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE = 48_000
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     bus_valid,
  input  logic                     bus_write,
  input  logic [15:0]              bus_address,
  input  logic [31:0]              bus_wdata,
  output logic [31:0]              bus_rdata,
  output logic                     bus_ready,
  output logic                     bus_error,
  input  logic                     cmd_stream_valid,
  input  logic [31:0]              cmd_stream_data,
  output logic                     cmd_stream_ready,
  input  logic                     sample_tick,
  output logic                     sample_valid,
  output synth_pkg::pcm_t          sample_l,
  output synth_pkg::pcm_t          sample_r,
  output logic                     busy,
  output logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  output logic [31:0]              ext_req_addr,
  input  logic                     ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0] ext_rsp_data,
  output synth_pkg::cache_diagnostics_t cache_diagnostics,
  output synth_pkg::render_timing_diagnostics_t render_diagnostics,
  output synth_pkg::voice_pipeline_diagnostics_t voice_diagnostics
);
  localparam int FRAME_BUDGET_CYCLES = CLK_HZ / SAMPLE_RATE;

  logic mem_req_ready;
  synth_pkg::wave_word_req_t mem_req;
  synth_pkg::wave_word_rsp_t mem_rsp;
  logic sample_tick_accepted;
  synth_pkg::mix_t unused_mix_l;
  synth_pkg::mix_t unused_mix_r;
  synth_pkg::global_audio_config_t unused_audio_config;
  logic [1:0] unused_effect_clear;

  assign sample_tick_accepted = sample_tick && !busy;

  wavetable_render_core #(
    .LINE_WORDS(LINE_WORDS)
  ) core (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .cmd_stream_valid,
    .cmd_stream_data,
    .cmd_stream_ready,
    .sample_tick,
    .sample_valid,
    .sample_l,
    .sample_r,
    .mix_l(unused_mix_l),
    .mix_r(unused_mix_r),
    .audio_config(unused_audio_config),
    .effect_clear(unused_effect_clear),
    .busy,
    .mem_req,
    .mem_req_ready,
    .mem_rsp,
    .voice_diagnostics
  );

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_wide_mix_and_compressor;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_wide_mix_and_compressor = (|unused_mix_l) | (|unused_mix_r) |
                                          (|unused_audio_config) |
                                          (|unused_effect_clear);

  voice_line_cache #(
    .LINE_WORDS(LINE_WORDS),
    .LINES_PER_VOICE(LINES_PER_VOICE)
  ) memory (
    .clk,
    .rst,
    .req(mem_req),
    .req_ready(mem_req_ready),
    .rsp(mem_rsp),
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .diagnostics_o(cache_diagnostics)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      render_diagnostics <= '0;
    end else begin
      if (sample_tick && render_diagnostics.active && !sample_valid)
        render_diagnostics.deadline_miss_count <=
            render_diagnostics.deadline_miss_count + 64'd1;

      if (sample_valid && render_diagnostics.active) begin
        render_diagnostics.last_cycles <= render_diagnostics.cycle_counter;
        render_diagnostics.cycle_sum <= render_diagnostics.cycle_sum +
                                        64'(render_diagnostics.cycle_counter);
        render_diagnostics.frame_count <= render_diagnostics.frame_count + 64'd1;
        if (render_diagnostics.cycle_counter > render_diagnostics.max_cycles)
          render_diagnostics.max_cycles <= render_diagnostics.cycle_counter;
        if (render_diagnostics.cycle_counter > 32'(FRAME_BUDGET_CYCLES)) begin
          render_diagnostics.over_budget_frames <=
              render_diagnostics.over_budget_frames + 64'd1;
          if ((render_diagnostics.cycle_counter - 32'(FRAME_BUDGET_CYCLES)) >
              render_diagnostics.over_budget_max_cycles)
            render_diagnostics.over_budget_max_cycles <=
                render_diagnostics.cycle_counter - 32'(FRAME_BUDGET_CYCLES);
        end
      end

      if (sample_valid) begin
        render_diagnostics.active <= sample_tick_accepted;
        render_diagnostics.cycle_counter <= sample_tick_accepted ? 32'd1 : 32'd0;
      end else if (sample_tick_accepted) begin
        render_diagnostics.active <= 1'b1;
        render_diagnostics.cycle_counter <= 32'd1;
      end else if (render_diagnostics.active &&
                   render_diagnostics.cycle_counter != 32'hffff_ffff) begin
        render_diagnostics.cycle_counter <= render_diagnostics.cycle_counter + 32'd1;
      end
    end
  end
endmodule
