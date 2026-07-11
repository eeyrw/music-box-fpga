module spi_register_bridge (
  input  logic        clk,
  input  logic        rst,
  input  logic        spi_sclk,
  input  logic        spi_cs_n,
  input  logic        spi_mosi,
  output logic        spi_miso,
  output logic        spi_error,
  output logic        bus_valid,
  output logic        bus_write,
  output logic [15:0] bus_address,
  output logic [31:0] bus_wdata,
  input  logic [31:0] bus_rdata,
  input  logic        bus_ready,
  input  logic        bus_error
);
  // Synchronous SPI-to-register bridge. The external SPI pins are sampled by
  // clk; board-specific timing constraints and CDC hardening belong with the
  // eventual FPGA integration wrapper.
  typedef enum logic [2:0] {
    STATE_IDLE,
    STATE_COMMAND,
    STATE_ADDRESS,
    STATE_WRITE_DATA,
    STATE_WRITE_WAIT,
    STATE_READ_WAIT,
    STATE_READ_DATA
  } state_t;

  state_t state;
  logic [1:0] sclk_sync;
  logic [1:0] cs_sync;
  logic [1:0] mosi_sync;
  logic [14:0] address_shift;
  logic [30:0] data_shift;
  logic [31:0] tx_shift;
  logic [5:0] bit_count;
  logic command_write;
  logic read_sample_seen;
  logic sclk_rise;
  logic sclk_fall;
  logic cs_active;
  logic cs_start;

  assign sclk_rise = cs_active && !sclk_sync[1] && sclk_sync[0];
  assign sclk_fall = cs_active && sclk_sync[1] && !sclk_sync[0];
  assign cs_active = !cs_sync[0];
  assign cs_start = cs_sync[1] && !cs_sync[0];

  always_ff @(posedge clk) begin
    if (rst) begin
      sclk_sync <= '0;
      cs_sync <= 2'b11;
      mosi_sync <= '0;
    end else begin
      sclk_sync <= {sclk_sync[0], spi_sclk};
      cs_sync <= {cs_sync[0], spi_cs_n};
      mosi_sync <= {mosi_sync[0], spi_mosi};
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      address_shift <= '0;
      data_shift <= '0;
      tx_shift <= '0;
      bit_count <= '0;
      command_write <= 1'b0;
      read_sample_seen <= 1'b0;
      spi_miso <= 1'b0;
      spi_error <= 1'b0;
      bus_valid <= 1'b0;
      bus_write <= 1'b0;
      bus_address <= '0;
      bus_wdata <= '0;
    end else begin
      bus_valid <= 1'b0;

      if (!cs_active) begin
        state <= STATE_IDLE;
        bit_count <= '0;
        spi_miso <= 1'b0;
      end else if (cs_start) begin
        state <= STATE_COMMAND;
        address_shift <= '0;
        data_shift <= '0;
        tx_shift <= '0;
        bit_count <= '0;
        command_write <= 1'b0;
        read_sample_seen <= 1'b0;
        spi_miso <= 1'b0;
        spi_error <= 1'b0;
      end else begin
        unique case (state)
          STATE_IDLE: begin
          end

          STATE_COMMAND: begin
            if (sclk_rise) begin
              if (bit_count == 6'd0)
                command_write <= mosi_sync[1];
              if (bit_count == 6'd7) begin
                bit_count <= '0;
                state <= STATE_ADDRESS;
              end else begin
                bit_count <= bit_count + 6'd1;
              end
            end
          end

          STATE_ADDRESS: begin
            if (sclk_rise) begin
              address_shift <= {address_shift[13:0], mosi_sync[1]};
              if (bit_count == 6'd15) begin
                bus_address <= {address_shift[14:0], mosi_sync[1]};
                bit_count <= '0;
                if (command_write) begin
                  state <= STATE_WRITE_DATA;
                end else begin
                  bus_valid <= 1'b1;
                  bus_write <= 1'b0;
                  state <= STATE_READ_WAIT;
                end
              end else begin
                bit_count <= bit_count + 6'd1;
              end
            end
          end

          STATE_WRITE_DATA: begin
            if (sclk_rise) begin
              data_shift <= {data_shift[29:0], mosi_sync[1]};
              if (bit_count == 6'd31) begin
                bus_wdata <= {data_shift[30:0], mosi_sync[1]};
                bus_valid <= 1'b1;
                bus_write <= 1'b1;
                bit_count <= '0;
                state <= STATE_WRITE_WAIT;
              end else begin
                bit_count <= bit_count + 6'd1;
              end
            end
          end

          STATE_WRITE_WAIT: begin
            bus_valid <= 1'b1;
            bus_write <= 1'b1;
            if (bus_ready) begin
              spi_error <= bus_error;
              bus_valid <= 1'b0;
              state <= STATE_IDLE;
            end
          end

          STATE_READ_WAIT: begin
            bus_valid <= 1'b1;
            bus_write <= 1'b0;
            if (bus_ready) begin
              tx_shift <= {bus_rdata[30:0], 1'b0};
              spi_miso <= bus_rdata[31];
              spi_error <= bus_error;
              bus_valid <= 1'b0;
              bit_count <= '0;
              read_sample_seen <= 1'b0;
              state <= STATE_READ_DATA;
            end
          end

          STATE_READ_DATA: begin
            if (sclk_rise) begin
              read_sample_seen <= 1'b1;
            end else if (sclk_fall && read_sample_seen) begin
              read_sample_seen <= 1'b0;
              if (bit_count != 6'd31) begin
                spi_miso <= tx_shift[31];
                tx_shift <= {tx_shift[30:0], 1'b0};
                bit_count <= bit_count + 6'd1;
              end
            end
          end

          default: state <= STATE_IDLE;
        endcase
      end
    end
  end
endmodule
