module tb_control_word_fifo;
  logic clk = 1'b0;
  logic rst;
  logic flush;
  logic push;
  logic [31:0] push_word;
  logic push_ready;
  logic pop;
  logic head_valid;
  logic [31:0] head_word;
  logic empty;
  logic full;
  logic [2:0] level;
  int errors = 0;

  always #5 clk <= ~clk;

  control_word_fifo #(.DEPTH(4), .WIDTH(32)) dut (.*);

  task automatic cycle(input logic push_i, input logic pop_i, input logic [31:0] word_i);
    begin
      @(negedge clk);
      push = push_i;
      pop = pop_i;
      push_word = word_i;
      @(negedge clk);
      push = 1'b0;
      pop = 1'b0;
    end
  endtask

  task automatic expect_head(
    input logic valid_i,
    input logic [31:0] word_i,
    input logic [2:0] level_i
  );
    begin
      if ((head_valid != valid_i) || (level != level_i) ||
          (valid_i && (head_word != word_i))) begin
        $error("FIFO mismatch valid=%0b word=%h level=%0d", head_valid, head_word, level);
        errors++;
      end
    end
  endtask

  task automatic refill_head;
    begin
      cycle(1'b0, 1'b0, '0);
      if (!head_valid) begin
        $error("FIFO head did not refill");
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    flush = 1'b0;
    push = 1'b0;
    push_word = '0;
    pop = 1'b0;
    repeat (3) @(negedge clk);
    rst = 1'b0;

    cycle(1'b1, 1'b0, 32'h11);
    expect_head(1'b0, '0, 3'd1);
    refill_head();
    expect_head(1'b1, 32'h11, 3'd1);
    cycle(1'b1, 1'b1, 32'h22);
    expect_head(1'b0, '0, 3'd1);
    refill_head();
    expect_head(1'b1, 32'h22, 3'd1);

    cycle(1'b1, 1'b0, 32'h33);
    cycle(1'b1, 1'b0, 32'h44);
    cycle(1'b1, 1'b0, 32'h55);
    expect_head(1'b1, 32'h22, 3'd4);
    if (!full || push_ready) begin
      $error("FIFO did not report full");
      errors++;
    end

    @(negedge clk);
    pop = 1'b1;
    #1;
    if (!push_ready) begin
      $error("FIFO did not accept a push paired with a full-state pop");
      errors++;
    end
    push = 1'b1;
    push_word = 32'h66;
    @(negedge clk);
    push = 1'b0;
    pop = 1'b0;
    expect_head(1'b1, 32'h33, 3'd4);

    cycle(1'b0, 1'b1, '0);
    expect_head(1'b1, 32'h44, 3'd3);
    cycle(1'b0, 1'b1, '0);
    expect_head(1'b1, 32'h55, 3'd2);
    cycle(1'b0, 1'b1, '0);
    expect_head(1'b1, 32'h66, 3'd1);

    @(negedge clk);
    flush = 1'b1;
    @(negedge clk);
    flush = 1'b0;
    expect_head(1'b0, '0, 3'd0);
    if (!empty) begin
      $error("FIFO did not report empty after flush");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: control word FIFO errors=%0d", errors);
    $display("PASS: control word FIFO");
    $finish;
  end
endmodule
