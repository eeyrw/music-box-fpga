module tb_render_credit_scheduler;
  localparam int FIFO_DEPTH = 8;
  localparam int TARGET_LEVEL = 6;

  logic clk = 1'b0;
  logic rst;
  logic [$clog2(FIFO_DEPTH+1)-1:0] fifo_level;
  logic renderer_busy;
  logic control_batch_complete;
  logic render_inflight;
  logic render_credit;
  logic render_start;
  int errors = 0;

  always #5 clk <= ~clk;

  render_credit_scheduler #(
    .FIFO_DEPTH(FIFO_DEPTH),
    .TARGET_LEVEL(TARGET_LEVEL)
  ) dut (.*);

  task automatic check(
    input int level_value,
    input logic busy_value,
    input logic batch_value,
    input logic expected_credit,
    input logic expected_start
  );
    begin
      fifo_level = level_value[$clog2(FIFO_DEPTH+1)-1:0];
      renderer_busy = busy_value;
      control_batch_complete = batch_value;
      #1;
      if ((render_credit !== expected_credit) ||
          (render_start !== expected_start) ||
          (render_inflight !== busy_value)) begin
        $error("level=%0d busy=%0b batch=%0b got credit/start/inflight=%0b/%0b/%0b",
               level_value, busy_value, batch_value,
               render_credit, render_start, render_inflight);
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b0;
    check(0, 1'b0, 1'b1, 1'b1, 1'b1);
    check(TARGET_LEVEL-1, 1'b0, 1'b1, 1'b1, 1'b1);
    check(TARGET_LEVEL-1, 1'b1, 1'b1, 1'b0, 1'b0);
    check(TARGET_LEVEL, 1'b0, 1'b1, 1'b0, 1'b0);
    check(TARGET_LEVEL-1, 1'b0, 1'b0, 1'b1, 1'b0);
    rst = 1'b1;
    check(0, 1'b0, 1'b1, 1'b1, 1'b0);

    if (errors != 0)
      $fatal(1, "FAIL: render credit scheduler errors=%0d", errors);
    $display("PASS: render credit scheduler");
    $finish;
  end
endmodule
