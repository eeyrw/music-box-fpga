module smart_artix_sd_spi_byte_master #(
  parameter int DIV_WIDTH = 16
) (
  input  logic                 clk,
  input  logic                 rst,

  input  logic [DIV_WIDTH-1:0] clk_div,
  input  logic                 cs_n_in,

  input  logic                 tx_valid,
  output logic                 tx_ready,
  input  logic [7:0]           tx_data,
  output logic                 rx_valid,
  output logic [7:0]           rx_data,

  output logic                 sd_clk,
  output logic                 sd_cmd_mosi,
  input  logic                 sd_dat0_miso,
  output logic                 sd_dat3_cs_n
);
  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_LOW,
    STATE_HIGH,
    STATE_DONE
  } state_t;

  state_t state;
  logic [DIV_WIDTH-1:0] div_count;
  logic [7:0] shift_tx;
  logic [7:0] shift_rx;
  logic [2:0] bit_index;
  logic half_tick;

  assign tx_ready = state == STATE_IDLE;
  assign sd_dat3_cs_n = cs_n_in;
  assign half_tick = div_count == clk_div;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      div_count <= '0;
      shift_tx <= 8'hff;
      shift_rx <= 8'h00;
      bit_index <= '0;
      sd_clk <= 1'b0;
      sd_cmd_mosi <= 1'b1;
      rx_valid <= 1'b0;
      rx_data <= 8'h00;
    end else begin
      rx_valid <= 1'b0;

      unique case (state)
        STATE_IDLE: begin
          sd_clk <= 1'b0;
          div_count <= '0;
          if (tx_valid) begin
            shift_tx <= tx_data;
            shift_rx <= 8'h00;
            bit_index <= 3'd7;
            sd_cmd_mosi <= tx_data[7];
            state <= STATE_LOW;
          end
        end

        STATE_LOW: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b1;
            shift_rx[bit_index] <= sd_dat0_miso;
            state <= STATE_HIGH;
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_HIGH: begin
          if (half_tick) begin
            div_count <= '0;
            sd_clk <= 1'b0;
            if (bit_index == 3'd0) begin
              state <= STATE_DONE;
            end else begin
              bit_index <= bit_index - 3'd1;
              sd_cmd_mosi <= shift_tx[bit_index - 3'd1];
              state <= STATE_LOW;
            end
          end else begin
            div_count <= div_count + DIV_WIDTH'(1);
          end
        end

        STATE_DONE: begin
          rx_data <= shift_rx;
          rx_valid <= 1'b1;
          state <= STATE_IDLE;
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end
endmodule
