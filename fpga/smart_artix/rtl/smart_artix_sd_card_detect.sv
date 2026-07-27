module smart_artix_sd_card_detect #(
  parameter int unsigned CLK_HZ = 100_000_000,
  parameter int unsigned DEBOUNCE_US = 5_000,
  parameter int unsigned POWER_STABLE_US = 1_000
) (
  input  logic clk,
  input  logic rst,
  input  logic card_detect_n,
  output logic card_present,
  output logic card_power_stable,
  output logic insertion_pulse,
  output logic removal_pulse
);
  localparam longint unsigned DEBOUNCE_CYCLES_RAW =
      (longint'(CLK_HZ) * DEBOUNCE_US + 999_999) / 1_000_000;
  localparam longint unsigned POWER_STABLE_CYCLES_RAW =
      (longint'(CLK_HZ) * POWER_STABLE_US + 999_999) / 1_000_000;
  localparam int unsigned DEBOUNCE_CYCLES =
      DEBOUNCE_CYCLES_RAW < 1 ? 1 : int'(DEBOUNCE_CYCLES_RAW);
  localparam int unsigned POWER_STABLE_CYCLES =
      POWER_STABLE_CYCLES_RAW < 1 ? 1 : int'(POWER_STABLE_CYCLES_RAW);
  localparam int unsigned DEBOUNCE_COUNT_WIDTH = DEBOUNCE_CYCLES <= 1 ? 1 : $clog2(DEBOUNCE_CYCLES);
  localparam int unsigned POWER_COUNT_WIDTH = POWER_STABLE_CYCLES <= 1 ? 1 : $clog2(POWER_STABLE_CYCLES);

  (* ASYNC_REG = "TRUE" *) logic [1:0] detect_sync;
  logic [DEBOUNCE_COUNT_WIDTH-1:0] debounce_count;
  logic [POWER_COUNT_WIDTH-1:0] power_count;
  logic detected_present;

  assign detected_present = !detect_sync[1];

  always_ff @(posedge clk) begin
    if (rst) begin
      detect_sync <= 2'b11;
      debounce_count <= '0;
      power_count <= '0;
      card_present <= 1'b0;
      card_power_stable <= 1'b0;
      insertion_pulse <= 1'b0;
      removal_pulse <= 1'b0;
    end else begin
      detect_sync <= {detect_sync[0], card_detect_n};
      insertion_pulse <= 1'b0;
      removal_pulse <= 1'b0;

      if (detected_present == card_present) begin
        debounce_count <= '0;
      end else if (debounce_count == DEBOUNCE_COUNT_WIDTH'(DEBOUNCE_CYCLES - 1)) begin
        debounce_count <= '0;
        card_present <= detected_present;
        insertion_pulse <= detected_present;
        removal_pulse <= !detected_present;
      end else begin
        debounce_count <= debounce_count + DEBOUNCE_COUNT_WIDTH'(1);
      end

      if (!card_present || !detected_present) begin
        power_count <= '0;
        card_power_stable <= 1'b0;
      end else if (!card_power_stable) begin
        if (power_count == POWER_COUNT_WIDTH'(POWER_STABLE_CYCLES - 1)) begin
          card_power_stable <= 1'b1;
        end else begin
          power_count <= power_count + POWER_COUNT_WIDTH'(1);
        end
      end
    end
  end
endmodule
