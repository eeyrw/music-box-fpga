module smart_artix_status_leds #(
  parameter int SLOW_HALF_PERIOD_CYCLES = 50_000_000,
  parameter int FAST_HALF_PERIOD_CYCLES = 10_000_000
) (
  input  logic clk,
  input  logic rst,
  input  logic ddr_ready,
  input  logic asset_loader_busy,
  input  logic error_present,
  input  logic asset_loaded,
  output logic led_ddr_ready,
  output logic led_asset_loaded
);
  localparam int MAX_HALF_PERIOD_CYCLES =
      (SLOW_HALF_PERIOD_CYCLES > FAST_HALF_PERIOD_CYCLES)
      ? SLOW_HALF_PERIOD_CYCLES : FAST_HALF_PERIOD_CYCLES;
  localparam int COUNTER_WIDTH =
      (MAX_HALF_PERIOD_CYCLES <= 1) ? 1 : $clog2(MAX_HALF_PERIOD_CYCLES);

  typedef enum logic [1:0] {
    LED_OFF,
    LED_SLOW_BLINK,
    LED_FAST_BLINK,
    LED_ON
  } led_mode_t;

  led_mode_t mode;
  led_mode_t mode_q;
  logic [COUNTER_WIDTH-1:0] counter_q;

  assign led_ddr_ready = ddr_ready;

  always_comb begin
    if (asset_loaded)
      mode = LED_ON;
    else if (error_present)
      mode = LED_FAST_BLINK;
    else if (asset_loader_busy)
      mode = LED_SLOW_BLINK;
    else
      mode = LED_OFF;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      mode_q <= LED_OFF;
      counter_q <= '0;
      led_asset_loaded <= 1'b0;
    end else if (mode != mode_q) begin
      mode_q <= mode;
      counter_q <= '0;
      led_asset_loaded <= (mode == LED_ON);
    end else begin
      case (mode)
        LED_ON: begin
          counter_q <= '0;
          led_asset_loaded <= 1'b1;
        end
        LED_SLOW_BLINK: begin
          if (counter_q == COUNTER_WIDTH'(SLOW_HALF_PERIOD_CYCLES - 1)) begin
            counter_q <= '0;
            led_asset_loaded <= !led_asset_loaded;
          end else begin
            counter_q <= counter_q + 1'b1;
          end
        end
        LED_FAST_BLINK: begin
          if (counter_q == COUNTER_WIDTH'(FAST_HALF_PERIOD_CYCLES - 1)) begin
            counter_q <= '0;
            led_asset_loaded <= !led_asset_loaded;
          end else begin
            counter_q <= counter_q + 1'b1;
          end
        end
        default: begin
          counter_q <= '0;
          led_asset_loaded <= 1'b0;
        end
      endcase
    end
  end
endmodule
