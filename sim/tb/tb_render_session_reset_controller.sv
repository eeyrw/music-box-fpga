`timescale 1ns/1ps

module tb_render_session_reset_controller;
  logic clk = 1'b0;
  logic rst = 1'b1;
  logic request = 1'b0;
  logic drain_complete = 1'b1;
  logic acknowledge;
  logic session_reset;
  logic [31:0] session_epoch;

  always #5 clk <= ~clk;

  render_session_reset_controller dut (.*);

  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    if (session_epoch != 32'd0 || session_reset || acknowledge)
      $fatal(1, "session reset controller reset mismatch");

    request = 1'b1;
    @(posedge clk);
    #1;
    if (!session_reset || acknowledge || session_epoch != 32'd0)
      $fatal(1, "session reset was not asserted before acknowledgement");
    @(posedge clk);
    #1;
    if (!session_reset || acknowledge || session_epoch != 32'd0)
      $fatal(1, "session reset did not cover the drain boundary");
    @(posedge clk);
    #1;
    if (session_reset || !acknowledge || session_epoch != 32'd1)
      $fatal(1, "session reset acknowledgement/epoch mismatch");

    repeat (3) begin
      @(posedge clk);
      #1;
      if (!acknowledge || session_epoch != 32'd1)
        $fatal(1, "held request retriggered the session reset");
    end

    request = 1'b0;
    @(posedge clk);
    #1;
    if (session_reset || acknowledge)
      $fatal(1, "acknowledgement did not clear after request release");

    request = 1'b1;
    @(posedge clk);
    drain_complete = 1'b0;
    @(posedge clk);
    repeat (3) begin
      @(posedge clk);
      #1;
      if (!session_reset || acknowledge || session_epoch != 32'd1)
        $fatal(1, "session reset acknowledged before drain completion");
    end
    drain_complete = 1'b1;
    @(posedge clk);
    #1;
    if (!acknowledge || session_epoch != 32'd2)
      $fatal(1, "second session reset did not increment epoch");

    $display("PASS: render session reset controller");
    $finish;
  end
endmodule
