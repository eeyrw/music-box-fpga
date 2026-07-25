module tb_control_cmd_parser;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic flush;
  logic [31:0] word_data;
  logic word_valid;
  logic word_ready;
  logic action_valid;
  logic action_ready;
  control_action_t action;
  logic command_error_pulse;
  int command_errors = 0;
  int errors = 0;

  always #5 clk <= ~clk;

  control_action_parser dut (.*);

  always_ff @(posedge clk) begin
    if (rst)
      command_errors <= 0;
    else if (command_error_pulse)
      command_errors <= command_errors + 1;
  end

  function automatic logic [31:0] header(
    input logic [7:0] opcode,
    input logic [7:0] voice,
    input logic [7:0] seq,
    input logic [7:0] payload_words
  );
    header = {opcode, voice, seq, payload_words};
  endfunction

  task automatic send_word(input logic [31:0] value);
    begin
      @(negedge clk);
      while (!word_ready) @(negedge clk);
      word_data = value;
      word_valid = 1'b1;
      @(negedge clk);
      word_valid = 1'b0;
    end
  endtask

  task automatic consume_action;
    begin
      action_ready = 1'b1;
      @(negedge clk);
      action_ready = 1'b0;
    end
  endtask

  initial begin
    rst = 1'b1;
    flush = 1'b0;
    word_data = '0;
    word_valid = 1'b0;
    action_ready = 1'b0;
    repeat (4) @(negedge clk);
    rst = 1'b0;

    send_word(header(VOICE_DEFINE_MONO, 8'd3, 8'h21, 8'd11));
    for (int index = 0; index < 11; index++)
      send_word(32'h1000_0000 + 32'(index));
    wait (action_valid);
    if (action.opcode != VOICE_DEFINE_MONO || action.voice != 8'd3 ||
        action.seq != 8'h21 || action.payload_words != 8'd11 ||
        action.payload[0] != 32'h1000_0000 || action.payload[10] != 32'h1000_000a) begin
      $error("VOICE_DEFINE_MONO decode mismatch");
      errors++;
    end
    repeat (3) begin
      @(negedge clk);
      if (!action_valid || word_ready) begin
        $error("parser did not hold action under backpressure");
        errors++;
      end
    end
    consume_action();

    send_word(header(MASTER_VOLUME, 8'd0, 8'd0, 8'd1));
    send_word(32'h0000_4000);
    wait (action_valid);
    if (action.opcode != MASTER_VOLUME || action.payload[0] != 32'h0000_4000) begin
      $error("MASTER_VOLUME decode mismatch");
      errors++;
    end
    consume_action();

    send_word(header(VOICE_ENV_UPDATE, 8'd9, 8'h44, 8'd4));
    send_word(32'h0000_0025);
    send_word(32'h0000_0100);
    send_word(32'h0000_0200);
    send_word(32'h0000_0300);
    wait (action_valid);
    if (action.opcode != VOICE_ENV_UPDATE || action.payload[0] != 32'h25 ||
        action.payload[3] != 32'h0000_0300) begin
      $error("VOICE_ENV_UPDATE decode mismatch");
      errors++;
    end
    consume_action();

    send_word(header(COMPRESSOR_CONFIG, 8'd0, 8'd0, 8'd4));
    send_word(32'h0001_0001);
    send_word(32'd120 << 20);
    send_word(32'd10 << 20);
    send_word(32'd1 << 20);
    wait (action_valid);
    if (action.opcode != COMPRESSOR_CONFIG || action.payload_words != 8'd4 ||
        action.payload[0] != 32'h0001_0001 ||
        action.payload[1] != (32'd120 << 20)) begin
      $error("COMPRESSOR_CONFIG decode mismatch");
      errors++;
    end
    consume_action();

    send_word(header(COMPRESSOR_CONFIG, 8'd1, 8'd0, 8'd4));
    for (int index = 0; index < 4; index++)
      send_word(32'd0);
    repeat (3) @(negedge clk);
    if (action_valid || command_errors != 1) begin
      $error("global compressor command accepted nonzero voice");
      errors++;
    end

    send_word(header(VOICE_ENV_UPDATE, 8'd1, 8'h01, 8'd2));
    send_word(32'h0000_0003);
    send_word(32'h0000_1111);
    repeat (3) @(negedge clk);
    if (action_valid || command_errors != 2) begin
      $error("invalid envelope mask/length was not rejected, errors=%0d", command_errors);
      errors++;
    end

    send_word(header(8'hee, 8'd0, 8'd0, 8'd2));
    send_word(32'hdead_beef);
    send_word(32'h0123_4567);
    repeat (3) @(negedge clk);
    if (action_valid || command_errors != 3) begin
      $error("unknown opcode was not drained and rejected, errors=%0d", command_errors);
      errors++;
    end

    send_word(header(VOICE_STOP, 8'd7, 8'h55, 8'd0));
    wait (action_valid);
    if (action.opcode != VOICE_STOP || action.voice != 8'd7 || action.seq != 8'h55) begin
      $error("VOICE_STOP decode mismatch");
      errors++;
    end
    consume_action();

    send_word(header(STREAM_FLUSH, 8'd0, 8'd0, 8'd0));
    wait (action_valid);
    if (action.opcode != STREAM_FLUSH) begin
      $error("STREAM_FLUSH decode mismatch");
      errors++;
    end
    consume_action();

    if (errors != 0)
      $fatal(1, "FAIL: control action parser errors=%0d", errors);
    $display("PASS: control action parser");
    $finish;
  end
endmodule
