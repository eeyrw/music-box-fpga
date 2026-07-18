module voice_active_store (
  input  logic                                  clk,
  input  logic                                  rst,
  input  logic                                  frame_boundary,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] render_voice_index,
  output synth_pkg::voice_config_t              render_config,
  output logic [synth_pkg::NUM_VOICES-1:0]     config_valid,
  output logic [synth_pkg::NUM_VOICES-1:0]     commit_pulse,
  input  logic                                  config_write,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] config_write_voice,
  input  synth_pkg::voice_config_t              config_write_data,
  input  logic                                  valid_write,
  input  logic                                  valid_write_data
);
  import synth_pkg::*;

  localparam int ACTIVE_CONFIG_WORD_WIDTH = $bits(voice_config_t);

  logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] active_config_ram_word;
  logic [NUM_VOICES-1:0] active_config_valid;
  logic [NUM_VOICES-1:0] pending_commit;

  function automatic voice_config_t unpack_active_config(
    input logic [ACTIVE_CONFIG_WORD_WIDTH-1:0] word
  );
    voice_config_t cfg;
    begin
      cfg = word;
      unpack_active_config = cfg;
    end
  endfunction

  assign config_valid = active_config_valid;

  voice_bram_1r1w #(
    .NUM_WORDS(NUM_VOICES),
    .ADDR_WIDTH(VOICE_ID_WIDTH),
    .DATA_WIDTH(ACTIVE_CONFIG_WORD_WIDTH),
    .DEFAULT_WORD('0)
  ) active_config_ram (
    .clk(clk),
    .write_en(config_write),
    .write_addr(config_write_voice),
    .write_data(config_write_data),
    .read_addr(render_voice_index),
    .read_data(active_config_ram_word)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      render_config <= '0;
      render_config.loop_mode <= LOOP_MODE_NONE;
      active_config_valid <= '0;
      pending_commit <= '0;
      commit_pulse <= '0;
    end else begin
      render_config <= unpack_active_config(active_config_ram_word);
      commit_pulse <= pending_commit;

      if (frame_boundary) begin
        pending_commit <= '0;
      end

      if (config_write) begin
        pending_commit[config_write_voice] <= 1'b1;
      end
      if (valid_write) begin
        active_config_valid[config_write_voice] <= valid_write_data;
      end
    end
  end
endmodule
