module tb_smart_artix_sd_io;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk = 1'b0;
  logic rst = 1'b1;
  logic sd_clk_o = 1'b0;
  logic sd_cmd_o = 1'b1;
  logic sd_cmd_oe = 1'b0;
  logic sd_cmd_i;
  logic [3:0] sd_dat_i;
  wire sd_clk;
  tri sd_cmd;
  logic [3:0] sd_dat = 4'hf;
  logic card_cmd_oe = 1'b0;
  logic card_cmd_o = 1'b1;
  int errors = 0;

  assign sd_cmd = card_cmd_oe ? card_cmd_o : 1'bz;

  smart_artix_sd_io dut (.*);

  always #5ns clk = ~clk;

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask

  task automatic launch_card_sample(
      input logic cmd_value,
      input logic [3:0] dat_value);
    begin
      @(posedge clk);
      sd_clk_o <= 1'b1;
      fork
        begin
          #14ns;
          card_cmd_o = cmd_value;
          sd_dat = dat_value;
        end
      join_none
      @(posedge clk);
      sd_clk_o <= 1'b0;
      @(posedge clk);
      #1ns;
      check(sd_cmd_i == cmd_value, "CMD next-rising-edge IOB sample mismatch");
      check(sd_dat_i == dat_value, "DAT next-rising-edge IOB sample mismatch");
    end
  endtask

  initial begin
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    card_cmd_oe = 1'b1;

    launch_card_sample(1'b0, 4'h3);
    launch_card_sample(1'b1, 4'hc);

    card_cmd_oe = 1'b0;
    sd_cmd_o = 1'b0;
    sd_cmd_oe = 1'b1;
    #1ns;
    check(sd_cmd === 1'b0, "CMD output-enable low drive failed");
    sd_cmd_o = 1'b1;
    #1ns;
    check(sd_cmd === 1'b1, "CMD output-enable high drive failed");
    sd_cmd_oe = 1'b0;
    #1ns;
    check(sd_cmd === 1'bz, "CMD tri-state release failed");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_sd_io errors=%0d", errors);
    $display("PASS: Smart Artix SD I/O capture");
    $finish;
  end
endmodule
