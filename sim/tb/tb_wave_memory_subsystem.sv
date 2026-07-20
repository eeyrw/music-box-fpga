module tb_wave_memory_subsystem;
  import synth_pkg::*;

  localparam int LINE_WORDS = 8;

  logic clk = 1'b0;
  logic rst;
  logic core_req_ready;
  wave_word_req_t core_req;
  wave_word_rsp_t core_rsp;
  logic ext_req_valid;
  logic ext_req_ready;
  logic [31:0] ext_req_addr;
  logic ext_rsp_valid;
  logic [LINE_WORDS*16-1:0] ext_rsp_data;
  logic response_trace_pulse;
  logic [15:0] response_trace_latency;
  int errors = 0;
  int ext_request_count = 0;
  int response_count = 0;

  always #5 clk <= ~clk;

  wave_memory_subsystem #(.LINE_WORDS(LINE_WORDS)) dut (
    .clk,
    .rst,
    .core_req,
    .core_req_ready,
    .core_rsp,
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .response_trace_pulse,
    .response_trace_latency
  );

  line_memory_model #(.DEPTH(64), .LINE_WORDS(LINE_WORDS), .LATENCY(4)) line_model (
    .clk,
    .rst,
    .req_valid(ext_req_valid),
    .req_ready(ext_req_ready),
    .req_addr(ext_req_addr),
    .rsp_valid(ext_rsp_valid),
    .rsp_data(ext_rsp_data)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      ext_request_count <= 0;
      response_count <= 0;
    end else begin
      if (ext_req_valid && ext_req_ready)
        ext_request_count <= ext_request_count + 1;
      if (response_trace_pulse)
        response_count <= response_count + 1;
    end
  end

  task automatic read_word(input logic [31:0] address, input int expected);
    int timeout;
    begin
      @(negedge clk);
      core_req.valid = 1'b1;
      core_req.addr = address;
      while (!core_req_ready)
        @(negedge clk);
      @(negedge clk);
      core_req.valid = 1'b0;

      timeout = 0;
      while (!core_rsp.valid && timeout < 50) begin
        @(negedge clk);
        timeout++;
      end
      if (!core_rsp.valid) begin
        $error("memory subsystem read timed out at 0x%08x", address);
        errors++;
      end else if ($signed({{16{core_rsp.data[15]}}, core_rsp.data}) !== expected) begin
        $error("memory subsystem read 0x%08x got %0d expected %0d", address, $signed(core_rsp.data), expected);
        errors++;
      end
    end
  endtask

  initial begin
    rst = 1'b1;
    core_req = '0;

    for (int i = 0; i < 64; i++)
      line_model.memory[i] = 16'(i * 11 - 100);

    repeat (5) @(negedge clk);
    rst = 1'b0;
    repeat (3) @(negedge clk);

    read_word(32'd3, -67);
    if (ext_request_count != 1) begin
      $error("first line miss made %0d external requests expected 1", ext_request_count);
      errors++;
    end

    read_word(32'd6, -34);
    if (ext_request_count != 1) begin
      $error("same-line hit made %0d external requests expected 1", ext_request_count);
      errors++;
    end

    read_word(32'd12, 32);
    if (ext_request_count != 2) begin
      $error("second line miss made %0d external requests expected 2", ext_request_count);
      errors++;
    end
    @(negedge clk);
    if (response_count != 3) begin
      $error("response trace counter got %0d expected 3", response_count);
      errors++;
    end
    if (response_trace_latency === 16'hxxxx) begin
      $error("response trace latency contains unknown bits");
      errors++;
    end

    if (errors != 0)
      $fatal(1, "FAIL: %0d errors", errors);
    $display("PASS: wave memory subsystem");
    $finish;
  end
endmodule
