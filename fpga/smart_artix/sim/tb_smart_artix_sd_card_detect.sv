module tb_smart_artix_sd_card_detect;
  logic clk;
  logic rst;
  logic card_detect_n;
  logic card_present;
  logic card_power_stable;
  logic insertion_pulse;
  logic removal_pulse;
  int errors;
  int insertion_count;
  int removal_count;

  smart_artix_sd_card_detect #(
    .CLK_HZ(1_000_000),
    .DEBOUNCE_US(4),
    .POWER_STABLE_US(6)
  ) dut (.*);

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask
/* verilator lint_on BLKSEQ */

  always_ff @(posedge clk) begin
    if (rst) begin
      insertion_count <= 0;
      removal_count <= 0;
    end else begin
      if (insertion_pulse)
        insertion_count <= insertion_count + 1;
      if (removal_pulse)
        removal_count <= removal_count + 1;
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    card_detect_n = 1'b1;
    errors = 0;
    repeat (3) @(posedge clk);
    rst = 1'b0;

    card_detect_n = 1'b0;
    repeat (2) @(posedge clk);
    card_detect_n = 1'b1;
    repeat (2) @(posedge clk);
    check(!card_present, "contact bounce was accepted as insertion");

    card_detect_n = 1'b0;
    wait (card_present);
    check(!card_power_stable, "power-stable asserted with insertion debounce");
    wait (card_power_stable);
    check(insertion_count == 1, "insertion pulse count mismatch");

    card_detect_n = 1'b1;
    repeat (2) @(posedge clk);
    card_detect_n = 1'b0;
    repeat (2) @(posedge clk);
    check(card_present, "contact bounce was accepted as removal");

    card_detect_n = 1'b1;
    wait (!card_present);
    check(!card_power_stable, "power-stable remained set after removal");
    repeat (2) @(posedge clk);
    check(removal_count == 1, "removal pulse count mismatch");

    card_detect_n = 1'b0;
    wait (card_power_stable);
    check(insertion_count == 2, "reinsertion did not create a new session");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_card_detect errors=%0d", errors);
    $display("PASS: smart_artix_sd_card_detect");
    $finish;
  end
endmodule
