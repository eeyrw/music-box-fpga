module smart_artix_ddr3_line_reader #(
  parameter int QUEUE_DEPTH = 8
) (
  input  logic                     clk,
  input  logic                     rst,

  input  smart_artix_pkg::line_read_request_t line_req,
  output logic                     line_req_ready,
  output smart_artix_pkg::line_read_response_t line_rsp,
  input  logic                     line_rsp_ready,

  input  logic                     mig_init_calib_complete,
  output smart_artix_pkg::mig_app_command_t  mig_app_command,
  input  smart_artix_pkg::mig_app_response_t mig_app_response
);
  localparam logic [2:0] MIG_CMD_READ = 3'b001;
  localparam int PTR_WIDTH = (QUEUE_DEPTH > 1) ? $clog2(QUEUE_DEPTH) : 1;
  localparam int COUNT_WIDTH = $clog2(QUEUE_DEPTH + 1);

  logic [31:0] request_fifo [0:QUEUE_DEPTH-1];
  logic [smart_artix_pkg::LINE_BITS-1:0] response_fifo [0:QUEUE_DEPTH-1];
  logic [PTR_WIDTH-1:0] request_write_ptr_q;
  logic [PTR_WIDTH-1:0] request_read_ptr_q;
  logic [PTR_WIDTH-1:0] response_write_ptr_q;
  logic [PTR_WIDTH-1:0] response_read_ptr_q;
  logic [COUNT_WIDTH-1:0] request_count_q;
  logic [COUNT_WIDTH-1:0] response_count_q;
  logic [COUNT_WIDTH-1:0] transaction_count_q;
  logic [COUNT_WIDTH-1:0] issued_count_q;
  logic request_fire;
  logic command_fire;
  logic response_push;
  logic response_fire;

  initial begin
    if (QUEUE_DEPTH < 2 || (QUEUE_DEPTH & (QUEUE_DEPTH - 1)) != 0)
      $error("smart_artix_ddr3_line_reader QUEUE_DEPTH must be a power of two >= 2");
  end

  assign line_req_ready = mig_init_calib_complete &&
                          (transaction_count_q < COUNT_WIDTH'(QUEUE_DEPTH));
  assign request_fire = line_req.valid && line_req_ready;
  assign mig_app_command.cmd = MIG_CMD_READ;
  assign mig_app_command.en = mig_init_calib_complete &&
                              (request_count_q != '0);
  assign mig_app_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(
      request_fifo[request_read_ptr_q]);
  assign command_fire = mig_app_command.en && mig_app_response.rdy;
  assign response_push = mig_app_response.rd_data_valid &&
                         mig_app_response.rd_data_end;
  assign line_rsp.valid = response_count_q != '0;
  assign line_rsp.data = response_fifo[response_read_ptr_q];
  assign response_fire = line_rsp.valid && line_rsp_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      request_write_ptr_q <= '0;
      request_read_ptr_q <= '0;
      response_write_ptr_q <= '0;
      response_read_ptr_q <= '0;
      request_count_q <= '0;
      response_count_q <= '0;
      transaction_count_q <= '0;
      issued_count_q <= '0;
    end else begin
      if (request_fire) begin
        request_fifo[request_write_ptr_q] <= line_req.addr;
        request_write_ptr_q <= request_write_ptr_q + 1'b1;
      end
      if (command_fire)
        request_read_ptr_q <= request_read_ptr_q + 1'b1;
      unique case ({request_fire, command_fire})
        2'b10: request_count_q <= request_count_q + 1'b1;
        2'b01: request_count_q <= request_count_q - 1'b1;
        default: begin end
      endcase

      if (response_push) begin
        if ((response_count_q == COUNT_WIDTH'(QUEUE_DEPTH)) && !response_fire)
          $error("smart_artix_ddr3_line_reader response FIFO overflow");
        response_fifo[response_write_ptr_q] <=
            mig_app_response.rd_data[smart_artix_pkg::LINE_BITS-1:0];
        response_write_ptr_q <= response_write_ptr_q + 1'b1;
      end
      if (response_fire)
        response_read_ptr_q <= response_read_ptr_q + 1'b1;
      unique case ({response_push, response_fire})
        2'b10: response_count_q <= response_count_q + 1'b1;
        2'b01: response_count_q <= response_count_q - 1'b1;
        default: begin end
      endcase

      unique case ({request_fire, response_fire})
        2'b10: transaction_count_q <= transaction_count_q + 1'b1;
        2'b01: transaction_count_q <= transaction_count_q - 1'b1;
        default: begin end
      endcase
      unique case ({command_fire, response_push})
        2'b10: issued_count_q <= issued_count_q + 1'b1;
        2'b01: begin
          if (issued_count_q == '0)
            $error("smart_artix_ddr3_line_reader received data without an issued read");
          else
            issued_count_q <= issued_count_q - 1'b1;
        end
        default: begin end
      endcase
    end
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_mig_write_ready;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_mig_write_ready = mig_app_response.wdf_rdy;
endmodule
