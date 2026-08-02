module tb_smart_artix_status_leds;
  localparam int SLOW_HALF_PERIOD_CYCLES = 4;
  localparam int FAST_HALF_PERIOD_CYCLES = 2;

  logic clk;
  logic rst;
  logic ddr_ready;
  logic asset_loader_busy;
  logic error_present;
  logic asset_loaded;
  logic led_ddr_ready;
  logic led_asset_loaded;
  int errors;

  smart_artix_status_leds #(
    .SLOW_HALF_PERIOD_CYCLES(SLOW_HALF_PERIOD_CYCLES),
    .FAST_HALF_PERIOD_CYCLES(FAST_HALF_PERIOD_CYCLES)
  ) dut (.*);

  always #5 clk <= !clk;

  task automatic check_outputs(
    input logic expected_ddr,
    input logic expected_asset
  );
    #1;
    if (led_ddr_ready !== expected_ddr) begin
      $error("DDR-ready LED got %b expected %b", led_ddr_ready, expected_ddr);
      errors++;
    end
    if (led_asset_loaded !== expected_asset) begin
      $error("asset-status LED got %b expected %b", led_asset_loaded, expected_asset);
      errors++;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    errors = 0;
    ddr_ready = 1'b0;
    asset_loader_busy = 1'b0;
    error_present = 1'b0;
    asset_loaded = 1'b0;

    repeat (2) @(posedge clk);
    check_outputs(1'b0, 1'b0);

    @(negedge clk);
    rst = 1'b0;
    ddr_ready = 1'b1;
    check_outputs(1'b1, 1'b0);

    @(negedge clk);
    asset_loader_busy = 1'b1;
    @(posedge clk);
    check_outputs(1'b1, 1'b0);
    repeat (SLOW_HALF_PERIOD_CYCLES - 1) begin
      @(posedge clk);
      check_outputs(1'b1, 1'b0);
    end
    @(posedge clk);
    check_outputs(1'b1, 1'b1);

    @(negedge clk);
    error_present = 1'b1;
    @(posedge clk);
    check_outputs(1'b1, 1'b0);
    repeat (FAST_HALF_PERIOD_CYCLES - 1) begin
      @(posedge clk);
      check_outputs(1'b1, 1'b0);
    end
    @(posedge clk);
    check_outputs(1'b1, 1'b1);

    @(negedge clk);
    asset_loaded = 1'b1;
    @(posedge clk);
    check_outputs(1'b1, 1'b1);
    repeat (FAST_HALF_PERIOD_CYCLES + 1) begin
      @(posedge clk);
      check_outputs(1'b1, 1'b1);
    end

    @(negedge clk);
    asset_loader_busy = 1'b0;
    error_present = 1'b0;
    asset_loaded = 1'b0;
    @(posedge clk);
    check_outputs(1'b1, 1'b0);

    if (errors != 0)
      $fatal(1, "tb_smart_artix_status_leds failed with %0d errors", errors);
    $display("tb_smart_artix_status_leds PASS");
    $finish;
  end
endmodule
