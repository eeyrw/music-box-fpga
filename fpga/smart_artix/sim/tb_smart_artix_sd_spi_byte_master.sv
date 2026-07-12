module tb_smart_artix_sd_spi_byte_master;
  logic clk;
  logic rst;
  logic [3:0] clk_div;
  logic cs_n_in;
  logic tx_valid;
  logic tx_ready;
  logic [7:0] tx_data;
  logic rx_valid;
  logic [7:0] rx_data;
  logic sd_clk;
  logic sd_cmd_mosi;
  logic sd_dat0_miso;
  logic sd_dat3_cs_n;
  int errors;
  int rising_edges;
  logic [7:0] mosi_seen;
  logic [7:0] miso_pattern;

  smart_artix_sd_spi_byte_master #(
    .DIV_WIDTH(4)
  ) dut (
    .clk,
    .rst,
    .clk_div,
    .cs_n_in,
    .tx_valid,
    .tx_ready,
    .tx_data,
    .rx_valid,
    .rx_data,
    .sd_clk,
    .sd_cmd_mosi,
    .sd_dat0_miso,
    .sd_dat3_cs_n
  );

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
/* verilator lint_on BLKSEQ */

/* verilator lint_off BLKSEQ */
  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask
/* verilator lint_on BLKSEQ */

  always_comb begin
    if (rising_edges < 8)
      sd_dat0_miso = miso_pattern[7-rising_edges];
    else
      sd_dat0_miso = 1'b1;
  end

/* verilator lint_off BLKSEQ */
  always @(posedge sd_clk) begin
    mosi_seen = {mosi_seen[6:0], sd_cmd_mosi};
    rising_edges++;
  end
/* verilator lint_on BLKSEQ */

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    clk_div = 4'd0;
    cs_n_in = 1'b1;
    tx_valid = 1'b0;
    tx_data = 8'h00;
    errors = 0;
    rising_edges = 0;
    mosi_seen = 8'h00;
    miso_pattern = 8'h3c;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    check(tx_ready, "SPI byte master not ready after reset");
    cs_n_in = 1'b0;
    tx_data = 8'ha5;
    tx_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tx_valid = 1'b0;

    wait (rx_valid);
    @(negedge clk);
    check(rising_edges == 8, "SPI byte master did not generate 8 rising edges");
    check(mosi_seen == 8'ha5, "SPI byte master shifted MOSI in wrong order");
    check(rx_data == 8'h3c, "SPI byte master sampled MISO in wrong order");
    check(sd_dat3_cs_n == 1'b0, "SPI byte master did not pass CS low");
    check(tx_ready, "SPI byte master not ready after byte");

    cs_n_in = 1'b1;
    @(posedge clk);
    check(sd_dat3_cs_n == 1'b1, "SPI byte master did not pass CS high");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_spi_byte_master errors=%0d", errors);

    $display("PASS: smart_artix_sd_spi_byte_master");
    $finish;
  end
endmodule
