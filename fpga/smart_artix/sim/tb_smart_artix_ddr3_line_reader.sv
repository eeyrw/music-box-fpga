module tb_smart_artix_ddr3_line_reader;
  logic clk;
  logic rst;
  smart_artix_pkg::line_read_request_t line_req;
  logic line_req_ready;
  smart_artix_pkg::line_read_response_t line_rsp;
  logic line_rsp_ready;
  logic mig_init_calib_complete;
  smart_artix_pkg::mig_app_command_t mig_app_command;
  smart_artix_pkg::mig_app_response_t mig_app_response;
  int errors;
  int command_count;
  int response_count;

  smart_artix_ddr3_line_reader #(
    .WORD_ADDR_SHIFT(1)
  ) dut (
    .clk,
    .rst,
    .line_req,
    .line_req_ready,
    .line_rsp,
    .line_rsp_ready,
    .mig_init_calib_complete,
    .mig_app_command,
    .mig_app_response
  );

/* verilator lint_off BLKSEQ */
  always #5 clk <= ~clk;
/* verilator lint_on BLKSEQ */

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask

  task automatic send_request(input logic [31:0] address);
    begin
      @(negedge clk);
      line_req.addr = address;
      line_req.valid = 1'b1;
      do @(posedge clk); while (!line_req_ready);
      @(negedge clk);
      line_req.valid = 1'b0;
    end
  endtask

  always_ff @(posedge clk) begin
    if (rst) begin
      command_count <= 0;
      response_count <= 0;
    end else begin
      if (mig_app_command.en && mig_app_response.rdy) begin
        check(mig_app_command.cmd == 3'b001,
              "line reader used wrong MIG read command");
        check(mig_app_command.addr == smart_artix_pkg::MIG_ADDR_WIDTH'(
                  (32'h0000_0040 + 32'(command_count * 8)) << 1),
              "queued line reader changed request order or address");
        command_count <= command_count + 1;
      end
      if (line_rsp.valid && line_rsp_ready) begin
        check(line_rsp.data == 128'(response_count + 1),
              "queued line reader changed response order");
        response_count <= response_count + 1;
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    line_req = '0;
    line_rsp_ready = 1'b0;
    mig_init_calib_complete = 1'b0;
    mig_app_response = '0;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(posedge clk);
    check(!line_req_ready, "line reader accepted requests before MIG calibration");

    mig_init_calib_complete = 1'b1;
    mig_app_response.rdy = 1'b1;
    for (int request_index = 0; request_index < 4; request_index++)
      send_request(32'h0000_0040 + 32'(request_index * 8));
    wait (command_count == 4);

    for (int response_index = 0; response_index < 4; response_index++) begin
      @(negedge clk);
      mig_app_response.rd_data = 128'(response_index + 1);
      mig_app_response.rd_data_valid = 1'b1;
      mig_app_response.rd_data_end = 1'b1;
      @(posedge clk);
    end
    @(negedge clk);
    mig_app_response.rd_data_valid = 1'b0;
    mig_app_response.rd_data_end = 1'b0;
    check(line_rsp.valid, "queued responses disappeared under backpressure");
    check(line_rsp.data == 128'd1, "response FIFO head changed under backpressure");
    repeat (2) @(posedge clk);
    check(line_rsp.data == 128'd1, "response FIFO data was not stable while stalled");

    @(negedge clk);
    line_rsp_ready = 1'b1;
    wait (response_count == 4);
    @(negedge clk);
    check(!line_rsp.valid, "line reader did not drain its response FIFO");
    check(line_req_ready, "line reader did not return all transaction credits");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_ddr3_line_reader errors=%0d", errors);

    $display("PASS: smart_artix_ddr3_line_reader");
    $finish;
  end
endmodule
