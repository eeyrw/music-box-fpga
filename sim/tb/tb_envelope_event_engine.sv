module tb_envelope_event_engine;
  import synth_pkg::*;

  logic clk = 1'b0;
  logic rst;
  logic [31:0] current_sample;
  logic snapshot_prepare;
  logic [VOICE_ID_WIDTH-1:0] snapshot_voice;
  logic signed [15:0] manual_envelope_level;
  logic manual_envelope_write;
  logic [VOICE_ID_WIDTH-1:0] manual_envelope_write_voice;
  envelope_event_t event_head;
  envelope_event_t event_head1;
  envelope_event_t event_head2;
  envelope_event_t event_head3;
  logic event_head_valid;
  logic event_head1_valid;
  logic event_head2_valid;
  logic event_head3_valid;
  logic [2:0] event_pop_count;
  logic signed [15:0] prepared_envelope_level;
  logic prepared_envelope_active;
  logic release_write;
  logic [VOICE_ID_WIDTH-1:0] release_write_voice;
  logic release_write_value;
  logic late_flag;
  logic order_error_flag;
  logic push;
  logic push_ready;
  logic empty;
  logic full;
  logic [$clog2(33)-1:0] fifo_level;
  envelope_event_t event_head_in;
  logic unused_fifo_outputs;
  int errors = 0;
  string current_case = "startup";

  always #5 clk <= ~clk;

  control_event_fifo #(.DEPTH(32)) fifo (
    .clk,
    .rst,
    .push,
    .push_event(event_head_in),
    .push_ready,
    .pop_count(event_pop_count),
    .head_valid(event_head_valid),
    .head_event(event_head),
    .head1_valid(event_head1_valid),
    .head1_event(event_head1),
    .head2_valid(event_head2_valid),
    .head2_event(event_head2),
    .head3_valid(event_head3_valid),
    .head3_event(event_head3),
    .empty,
    .full,
    .level(fifo_level)
  );

  envelope_event_engine dut (
    .clk,
    .rst,
    .current_sample,
    .snapshot_prepare,
    .snapshot_voice,
    .manual_envelope_level,
    .manual_envelope_write,
    .manual_envelope_write_voice,
    .event_head,
    .event_head_valid,
    .event_head1,
    .event_head1_valid,
    .event_head2,
    .event_head2_valid,
    .event_head3,
    .event_head3_valid,
    .event_pop_count,
    .prepared_envelope_level,
    .prepared_envelope_active,
    .release_write,
    .release_write_voice,
    .release_write_value,
    .late_flag,
    .order_error_flag
  );

  assign unused_fifo_outputs = prepared_envelope_active | push_ready | empty | full | (|fifo_level);

  task automatic begin_case(input string name);
    current_case = name;
    $display("CASE: %s", current_case);
  endtask

  task automatic expect_level(input logic signed [15:0] expected);
    if ($signed(prepared_envelope_level) !== expected) begin
      $error("[%s] envelope got %0d expected %0d", current_case,
             $signed(prepared_envelope_level), expected);
      errors++;
    end
  endtask

  task automatic push_event(
    input logic [31:0] timestamp,
    input envelope_event_opcode_t opcode,
    input logic [VOICE_ID_WIDTH-1:0] voice,
    input logic [15:0] payload0,
    input logic [31:0] payload1
  );
    @(negedge clk);
    event_head_in.timestamp = timestamp;
    event_head_in.payload0 = payload0;
    event_head_in.opcode = opcode;
    event_head_in.voice = {{(8 - VOICE_ID_WIDTH){1'b0}}, voice};
    event_head_in.payload1 = payload1;
    push = 1'b1;
    @(negedge clk);
    push = 1'b0;
  endtask

  task automatic prepare(input logic [31:0] sample, input logic [VOICE_ID_WIDTH-1:0] voice);
    @(negedge clk);
    current_sample = sample;
    snapshot_voice = voice;
    snapshot_prepare = 1'b1;
    @(negedge clk);
    snapshot_prepare = 1'b0;
    @(negedge clk);
  endtask

  function automatic logic signed [15:0] cb_to_q15(input int cb);
    begin
      unique case (cb)
        0: cb_to_q15 = 16'sd32767;
        1: cb_to_q15 = 16'sd32398;
        2: cb_to_q15 = 16'sd32029;
        4: cb_to_q15 = 16'sd31292;
        default: cb_to_q15 = cb >= 960 ? 16'sh0000 : 16'shxxxx;
      endcase
    end
  endfunction

  initial begin
    rst = 1'b1;
    current_sample = 32'd0;
    snapshot_prepare = 1'b0;
    snapshot_voice = '0;
    manual_envelope_level = 16'sh0000;
    manual_envelope_write = 1'b0;
    manual_envelope_write_voice = '0;
    push = 1'b0;
    event_head_in = '0;
    repeat (4) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    begin_case("set exact");
    push_event(32'd0, EVT_ENV_SET, 0, 16'h4000, 32'd0);
    prepare(32'd0, 0);
    expect_level(16'h4000);

    begin_case("future timestamp waits");
    push_event(32'd2, EVT_ENV_SET, 0, 16'h2000, 32'd0);
    prepare(32'd1, 0);
    expect_level(16'h4000);
    prepare(32'd2, 0);
    expect_level(16'h2000);

    begin_case("same timestamp fifo order");
    push_event(32'd3, EVT_ENV_SET, 0, 16'h1000, 32'd0);
    push_event(32'd3, EVT_ENV_SET, 0, 16'h3000, 32'd0);
    prepare(32'd3, 0);
    expect_level(16'h3000);

    begin_case("attack monotonic");
    push_event(32'd4, EVT_VOL_ATTACK, 0, 16'h4000, 32'd4);
    prepare(32'd4, 0);
    expect_level(0);
    prepare(32'd5, 0);
    expect_level(16'h1000);
    prepare(32'd6, 0);
    expect_level(16'h2000);
    prepare(32'd7, 0);
    expect_level(16'h3000);
    prepare(32'd8, 0);
    expect_level(16'h4000);

    begin_case("decay cb");
    push_event(32'd9, EVT_VOL_DECAY_CB, 0, 16'd0, {16'd1, 16'd4});
    prepare(32'd9, 0);
    expect_level(cb_to_q15(0));
    prepare(32'd10, 0);
    expect_level(cb_to_q15(1));
    prepare(32'd11, 0);
    expect_level(cb_to_q15(2));

    begin_case("release to zero");
    push_event(32'd12, EVT_VOL_RELEASE_CB, 0, 16'd0, {16'd200, 16'd0});
    prepare(32'd12, 0);
    expect_level(cb_to_q15(0));
    for (int i = 13; i < 80; i++) begin
      prepare(i[31:0], 0);
    end
    expect_level(0);

    begin_case("release flag");
    push_event(32'd18, EVT_RELEASE_FLAG, 0, 16'd0, 32'd0);
    @(negedge clk);
    current_sample = 32'd18;
    snapshot_voice = '0;
    snapshot_prepare = 1'b1;
    #1;
    if (!release_write || release_write_voice != '0 || !release_write_value) begin
      $error("[%s] release flag write missing", current_case);
      errors++;
    end
    @(negedge clk);
    snapshot_prepare = 1'b0;
    @(negedge clk);

    begin_case("late and order flags");
    push_event(32'd19, EVT_ENV_SET, 0, 16'h1111, 32'd0);
    prepare(32'd20, 0);
    if (!late_flag) begin
      $error("[%s] late flag not set", current_case);
      errors++;
    end
    push_event(32'd21, EVT_ENV_SET, 0, 16'h2222, 32'd0);
    prepare(32'd21, 1);
    if (!order_error_flag) begin
      $error("[%s] order error flag not set", current_case);
      errors++;
    end

    if (errors == 0) begin
      $display("PASS");
      $finish;
    end else begin
      $display("FAIL errors=%0d", errors);
      $fatal(1);
    end
  end
endmodule
