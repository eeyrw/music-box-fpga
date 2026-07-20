module voice_runtime_store (
  input  logic                                  clk,
  input  logic                                  rst,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] render_voice_index,
  output synth_pkg::voice_runtime_t             render_runtime,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] inspect_voice,
  output logic [31:0]                           inspect_phase_inc,
  output logic [31:0]                           inspect_gain,
  output logic [31:0]                           inspect_envelope,
  output logic [31:0]                           inspect_release,
  input  logic                                  bus_phase_write,
  input  logic                                  bus_gain_write,
  input  logic                                  bus_envelope_write,
  input  logic                                  bus_release_write,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] bus_write_voice,
  input  logic [31:0]                           bus_wdata,
  input  logic                                  commit_phase_write,
  input  logic                                  commit_gain_write,
  input  logic                                  commit_envelope_write,
  input  logic                                  commit_release_clear,
  input  logic                                  commit_filter_write,
  input  logic                                  commit_filter_enable_write,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] commit_write_voice,
  input  logic [31:0]                           commit_phase_data,
  input  logic [31:0]                           commit_gain_data,
  input  logic [15:0]                           commit_envelope_data,
  input  logic [(5*synth_pkg::FILTER_COEFF_WIDTH)-1:0] commit_filter_data,
  input  logic                                  commit_filter_enable_data
);
  import synth_pkg::*;

  localparam int FILTER_COEFF_WORD_WIDTH = 5 * FILTER_COEFF_WIDTH;
  localparam int FILTER_B0_LSB = 4 * FILTER_COEFF_WIDTH;
  localparam int FILTER_B1_LSB = 3 * FILTER_COEFF_WIDTH;
  localparam int FILTER_B2_LSB = 2 * FILTER_COEFF_WIDTH;
  localparam int FILTER_A1_LSB = 1 * FILTER_COEFF_WIDTH;
  localparam int FILTER_A2_LSB = 0;
  localparam logic [FILTER_COEFF_WORD_WIDTH-1:0] DEFAULT_FILTER_COEFF = {
    16'sh4000,
    16'sh0000,
    16'sh0000,
    16'sh0000,
    16'sh0000
  };

  (* ram_style = "distributed" *) logic runtime_released [NUM_VOICES];
  (* ram_style = "distributed" *) logic runtime_filter_enable [NUM_VOICES];
  logic [VOICE_ID_WIDTH-1:0] runtime_write_voice;
  logic [31:0] runtime_phase_write_data;
  logic [31:0] runtime_gain_write_data;
  logic [15:0] runtime_envelope_write_data;
  logic runtime_phase_write;
  logic runtime_gain_write;
  logic runtime_envelope_write;
  logic [31:0] runtime_phase_render_data;
  logic [31:0] runtime_gain_render_data;
  logic [15:0] runtime_envelope_render_data;
  logic [31:0] runtime_phase_inspect_data;
  logic [31:0] runtime_gain_inspect_data;
  logic [15:0] runtime_envelope_inspect_data;
  logic [FILTER_COEFF_WORD_WIDTH-1:0] runtime_filter_render_word;
  int i;

  assign runtime_write_voice = (commit_phase_write || commit_gain_write ||
                                commit_envelope_write || commit_filter_write) ?
                               commit_write_voice : bus_write_voice;
  assign runtime_phase_write = commit_phase_write || bus_phase_write;
  assign runtime_gain_write = commit_gain_write || bus_gain_write;
  assign runtime_envelope_write = commit_envelope_write || bus_envelope_write;
  assign runtime_phase_write_data = commit_phase_write ? commit_phase_data : bus_wdata;
  assign runtime_gain_write_data = commit_gain_write ? commit_gain_data : bus_wdata;
  assign runtime_envelope_write_data = commit_envelope_write ? commit_envelope_data : bus_wdata[15:0];

  assign inspect_phase_inc = runtime_phase_inspect_data;
  assign inspect_gain = runtime_gain_inspect_data;
  assign inspect_envelope = {{16{runtime_envelope_inspect_data[15]}}, runtime_envelope_inspect_data};
  voice_bram_1w2r #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(32),
    .DEFAULT_WORD(32'd0)
  ) runtime_phase_ram (
    .clk(clk),
    .write_en(runtime_phase_write),
    .write_addr(runtime_write_voice),
    .write_data(runtime_phase_write_data),
    .read_addr_a(render_voice_index),
    .read_data_a(runtime_phase_render_data),
    .read_addr_b(inspect_voice),
    .read_data_b(runtime_phase_inspect_data)
  );

  voice_bram_1w2r #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(32),
    .DEFAULT_WORD(32'd0)
  ) runtime_gain_ram (
    .clk(clk),
    .write_en(runtime_gain_write),
    .write_addr(runtime_write_voice),
    .write_data(runtime_gain_write_data),
    .read_addr_a(render_voice_index),
    .read_data_a(runtime_gain_render_data),
    .read_addr_b(inspect_voice),
    .read_data_b(runtime_gain_inspect_data)
  );

  voice_bram_1w2r #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(16),
    .DEFAULT_WORD(16'h0000)
  ) runtime_envelope_ram (
    .clk(clk),
    .write_en(runtime_envelope_write),
    .write_addr(runtime_write_voice),
    .write_data(runtime_envelope_write_data),
    .read_addr_a(render_voice_index),
    .read_data_a(runtime_envelope_render_data),
    .read_addr_b(inspect_voice),
    .read_data_b(runtime_envelope_inspect_data)
  );

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(FILTER_COEFF_WORD_WIDTH),
    .DEFAULT_WORD(DEFAULT_FILTER_COEFF)
  ) runtime_filter_ram (
    .clk(clk),
    .write_en(commit_filter_write),
    .write_addr(commit_write_voice),
    .write_data(commit_filter_data),
    .read_addr(render_voice_index),
    .read_data(runtime_filter_render_word)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < NUM_VOICES; i++) begin
        runtime_released[i] <= 1'b0;
        runtime_filter_enable[i] <= 1'b0;
      end
      render_runtime <= '0;
      render_runtime.envelope_level <= '0;
      render_runtime.filter_b0 <= 16'sh4000;
      inspect_release <= 32'd0;
    end else begin
      render_runtime.phase_inc <= runtime_phase_render_data;
      render_runtime.gain_l <= $signed(runtime_gain_render_data[15:0]);
      render_runtime.gain_r <= $signed(runtime_gain_render_data[31:16]);
      render_runtime.envelope_level <= $signed(runtime_envelope_render_data);
      render_runtime.released <= runtime_released[render_voice_index];
      render_runtime.filter_enable <= runtime_filter_enable[render_voice_index];
      render_runtime.filter_b0 <= runtime_filter_render_word[FILTER_B0_LSB +: FILTER_COEFF_WIDTH];
      render_runtime.filter_b1 <= runtime_filter_render_word[FILTER_B1_LSB +: FILTER_COEFF_WIDTH];
      render_runtime.filter_b2 <= runtime_filter_render_word[FILTER_B2_LSB +: FILTER_COEFF_WIDTH];
      render_runtime.filter_a1 <= runtime_filter_render_word[FILTER_A1_LSB +: FILTER_COEFF_WIDTH];
      render_runtime.filter_a2 <= runtime_filter_render_word[FILTER_A2_LSB +: FILTER_COEFF_WIDTH];
      inspect_release <= {31'd0, runtime_released[inspect_voice]};

      if (bus_release_write) begin
        runtime_released[bus_write_voice] <= bus_wdata[0];
      end
      if (commit_release_clear) begin
        runtime_released[commit_write_voice] <= 1'b0;
      end
      if (commit_filter_enable_write) begin
        runtime_filter_enable[commit_write_voice] <= commit_filter_enable_data;
      end
    end
  end
endmodule
