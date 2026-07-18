module i2s_tx #(
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
) (
  input  logic            clk,
  input  logic            rst,
  input  logic            sample_valid,
  output logic            sample_ready,
  input  synth_pkg::pcm_t sample_l,
  input  synth_pkg::pcm_t sample_r,
  output logic            underrun_pulse,
  output logic            i2s_bclk,
  output logic            i2s_lrclk,
  output logic            i2s_sdata
);
  localparam int BITS_PER_SAMPLE = synth_pkg::PCM_WIDTH;
  localparam int CHANNELS = 2;
  localparam int BCLK_HZ = SAMPLE_RATE_HZ * CHANNELS * BITS_PER_SAMPLE;
  localparam int BCLK_EDGE_HZ = BCLK_HZ * 2;
  localparam int BIT_INDEX_WIDTH = $clog2(BITS_PER_SAMPLE);
  localparam logic [BIT_INDEX_WIDTH-1:0] BIT_INDEX_LAST = BIT_INDEX_WIDTH'(BITS_PER_SAMPLE - 1);

  logic bclk_edge;
  logic [BIT_INDEX_WIDTH-1:0] bit_index;
  logic channel_right;
  synth_pkg::pcm_t current_l;
  synth_pkg::pcm_t current_r;
  synth_pkg::pcm_t pending_l;
  synth_pkg::pcm_t pending_r;
  logic pending_valid;

  assign sample_ready = !pending_valid;

  fractional_tick_gen #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .TICK_HZ(BCLK_EDGE_HZ)
  ) bclk_edge_gen (
    .clk,
    .rst,
    .tick(bclk_edge)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      bit_index <= '0;
      channel_right <= 1'b0;
      current_l <= '0;
      current_r <= '0;
      pending_l <= '0;
      pending_r <= '0;
      pending_valid <= 1'b0;
      underrun_pulse <= 1'b0;
      i2s_bclk <= 1'b0;
      i2s_lrclk <= 1'b0;
      i2s_sdata <= 1'b0;
    end else begin
      underrun_pulse <= 1'b0;

      if (sample_valid && sample_ready) begin
        pending_l <= sample_l;
        pending_r <= sample_r;
        pending_valid <= 1'b1;
      end

      if (bclk_edge) begin
        i2s_bclk <= ~i2s_bclk;

        if (i2s_bclk) begin
          i2s_sdata <= channel_right ? current_r[BIT_INDEX_LAST-bit_index]
                                      : current_l[BIT_INDEX_LAST-bit_index];

          // Philips I2S changes LRCLK one bit-clock before the next word MSB.
          if (bit_index == BIT_INDEX_LAST) begin
            i2s_lrclk <= !channel_right;
            bit_index <= '0;
            channel_right <= !channel_right;

            if (channel_right) begin
              if (pending_valid) begin
                current_l <= pending_l;
                current_r <= pending_r;
                pending_valid <= 1'b0;
              end else begin
                current_l <= '0;
                current_r <= '0;
                underrun_pulse <= 1'b1;
              end
            end
          end else begin
            bit_index <= bit_index + 1'b1;
            i2s_lrclk <= channel_right;
          end
        end
      end
    end
  end
endmodule
