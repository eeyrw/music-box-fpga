module tb_voice_line_cache;
  import synth_pkg::*;

  localparam int LINE_WORDS = 32;
  localparam int MEMORY_DEPTH = 160;

  logic clk = 1'b0;
  logic rst;
  wave_word_req_t req;
  logic req_ready;
  wave_word_rsp_t rsp;
  logic ext_req_valid;
  logic ext_req_ready;
  logic [ADDR_WIDTH-1:0] ext_req_addr;
  logic ext_rsp_valid;
  logic [LINE_WORDS*16-1:0] ext_rsp_data;
  logic response_trace_pulse;
  logic [15:0] response_trace_latency;
  logic demand_hit_pulse;
  logic demand_miss_pulse;
  logic line_fill_pulse;
  logic same_line_endpoint_hit_pulse;
  logic replacement_pulse;

  pcm_t memory [MEMORY_DEPTH];
  logic line_pending;
  logic [ADDR_WIDTH-1:0] line_pending_addr;
  int line_countdown;
  int errors = 0;
  int ext_request_count = 0;
  int hit_count = 0;
  int miss_count = 0;
  int fill_count = 0;
  int same_line_hit_count = 0;
  int replacement_count = 0;
  int backpressure_timeout;
  logic unused_trace;

  assign unused_trace = response_trace_pulse;

  always #5 clk <= ~clk;

  voice_line_cache #(
    .LINE_WORDS(LINE_WORDS),
    .LINES_PER_VOICE(2)
  ) dut (
    .clk,
    .rst,
    .req,
    .req_ready,
    .rsp,
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .response_trace_pulse,
    .response_trace_latency,
    .demand_hit_pulse,
    .demand_miss_pulse,
    .line_fill_pulse,
    .same_line_endpoint_hit_pulse,
    .replacement_pulse
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      line_pending <= 1'b0;
      line_pending_addr <= '0;
      line_countdown <= 0;
      ext_rsp_valid <= 1'b0;
      ext_rsp_data <= '0;
      ext_request_count <= 0;
      hit_count <= 0;
      miss_count <= 0;
      fill_count <= 0;
      same_line_hit_count <= 0;
      replacement_count <= 0;
    end else begin
      ext_rsp_valid <= 1'b0;
      if (ext_req_valid && ext_req_ready) begin
        line_pending <= 1'b1;
        line_pending_addr <= ext_req_addr;
        line_countdown <= 2;
        ext_request_count <= ext_request_count + 1;
      end
      if (line_pending) begin
        if (line_countdown == 0) begin
          for (int w = 0; w < LINE_WORDS; w++) begin
            ext_rsp_data[w * PCM_WIDTH +: PCM_WIDTH] <=
              ((line_pending_addr + ADDR_WIDTH'(w)) < MEMORY_DEPTH) ?
              memory[line_pending_addr + ADDR_WIDTH'(w)] : '0;
          end
          ext_rsp_valid <= 1'b1;
          line_pending <= 1'b0;
        end else begin
          line_countdown <= line_countdown - 1;
        end
      end
      if (demand_hit_pulse)
        hit_count <= hit_count + 1;
      if (demand_miss_pulse)
        miss_count <= miss_count + 1;
      if (line_fill_pulse)
        fill_count <= fill_count + 1;
      if (same_line_endpoint_hit_pulse)
        same_line_hit_count <= same_line_hit_count + 1;
      if (replacement_pulse)
        replacement_count <= replacement_count + 1;
    end
  end

  task automatic read_word(
    input logic [VOICE_ID_WIDTH-1:0] voice,
    input logic [ADDR_WIDTH-1:0] address,
    input int expected
  );
    int timeout;
    int actual;
    begin
      @(negedge clk);
      while (!req_ready)
        @(negedge clk);
      req.valid = 1'b1;
      req.voice = voice;
      req.addr = address;
      @(negedge clk);
      req.valid = 1'b0;

      timeout = 0;
      while (!rsp.valid && timeout < 50) begin
        @(negedge clk);
        timeout++;
      end
      if (!rsp.valid) begin
        $error("voice line cache read timed out voice=%0d addr=%0d", voice, address);
        errors++;
      end else begin
        actual = $signed({{16{rsp.data[15]}}, rsp.data});
        if (actual !== expected) begin
        $error("voice line cache read voice=%0d addr=%0d got %0d expected %0d",
               voice, address, actual, expected);
        errors++;
        end
      end
    end
  endtask

  task automatic expect_count(input string name, input int got, input int expected);
    begin
      @(negedge clk);
      if (got != expected) begin
        $error("%s got %0d expected %0d", name, got, expected);
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    req = '0;
    ext_req_ready = 1'b1;
    for (int i = 0; i < MEMORY_DEPTH; i++)
      memory[i] = 16'(i * 7 - 300);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);

    read_word('0, 32'd3, -279);
    expect_count("first miss external requests", ext_request_count, 1);
    expect_count("first miss count", miss_count, 1);

    read_word('0, 32'd6, -258);
    expect_count("same-line hit external requests", ext_request_count, 1);
    expect_count("same-line hit count", hit_count, 1);
    expect_count("same-line endpoint hit count", same_line_hit_count, 1);

    read_word(VOICE_ID_WIDTH'(1), 32'd64, 148);
    expect_count("second voice miss external requests", ext_request_count, 2);

    read_word('0, 32'd8, -244);
    expect_count("voice 0 line survives voice 1 miss", ext_request_count, 2);

    read_word('0, 32'd40, -20);
    read_word('0, 32'd70, 190);
    expect_count("third voice-local line external requests", ext_request_count, 4);
    expect_count("replacement count", replacement_count, 1);

    read_word('0, 32'd40, -20);
    expect_count("unreplaced second way hit", ext_request_count, 4);

    ext_req_ready = 1'b0;
    @(negedge clk);
    while (!req_ready)
      @(negedge clk);
    req.valid = 1'b1;
    req.voice = '0;
    req.addr = 32'd128;
    @(negedge clk);
    req.valid = 1'b0;
    repeat (2) @(negedge clk);
    if (req_ready) begin
      $error("req_ready stayed high while a miss waited for ext_req_ready");
      errors++;
    end
    ext_req_ready = 1'b1;
    backpressure_timeout = 0;
    while (!rsp.valid && backpressure_timeout < 50) begin
      @(negedge clk);
      backpressure_timeout++;
    end
    if (!rsp.valid) begin
      $error("backpressured miss did not complete after ext_req_ready returned");
      errors++;
    end

    rst = 1'b1;
    repeat (2) @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    read_word('0, 32'd40, -20);
    expect_count("reset invalidates cached lines", ext_request_count, 1);

    if (response_trace_latency === 16'hxxxx) begin
      $error("response trace latency contains unknown bits");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: %0d errors", errors);
    $display("PASS: voice line cache");
    $finish;
  end
endmodule
