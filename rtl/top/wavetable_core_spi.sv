module wavetable_core_spi (
  input  logic            clk,
  input  logic            rst,
  input  logic            spi_sclk,
  input  logic            spi_cs_n,
  input  logic            spi_mosi,
  output logic            spi_miso,
  output logic            spi_error,
  input  logic            sample_tick,
  output logic            sample_valid,
  output synth_pkg::pcm_t sample_l,
  output synth_pkg::pcm_t sample_r,
  output logic            busy,
  output logic            mem_req_valid,
  output logic [31:0]     mem_req_addr,
  input  logic            mem_req_ready,
  input  logic            mem_rsp_valid,
  input  synth_pkg::pcm_t mem_rsp_data
);
  logic bus_valid;
  logic bus_write;
  logic [15:0] bus_address;
  logic [31:0] bus_wdata;
  logic [31:0] bus_rdata;
  logic bus_ready;
  logic bus_error;

  spi_register_bridge spi_bridge (
    .clk,
    .rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso,
    .spi_error,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error
  );

  wavetable_core core (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .bus_rdata,
    .bus_ready,
    .bus_error,
    .sample_tick,
    .sample_valid,
    .sample_l,
    .sample_r,
    .busy,
    .mem_req_valid,
    .mem_req_addr,
    .mem_req_ready,
    .mem_rsp_valid,
    .mem_rsp_data
  );
endmodule
