module smart_artix_ddr3_line_reader #(
  parameter int WORD_ADDR_SHIFT = 1
) (
  input  logic                     clk,
  input  logic                     rst,

  input  smart_artix_pkg::line_read_request_t line_req,
  output logic                     line_req_ready,
  output smart_artix_pkg::line_read_response_t line_rsp,

  input  logic                     mig_init_calib_complete,
  output smart_artix_pkg::mig_app_command_t  mig_app_command,
  input  smart_artix_pkg::mig_app_response_t mig_app_response
);
  localparam logic [2:0] MIG_CMD_READ = 3'b001;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_SEND_READ,
    STATE_WAIT_DATA
  } state_t;

  state_t state;
  logic [31:0] pending_line_addr;

  assign line_req_ready = mig_init_calib_complete && (state == STATE_IDLE);
  assign mig_app_command.cmd = MIG_CMD_READ;
  assign mig_app_command.en = state == STATE_SEND_READ;
  assign mig_app_command.addr = smart_artix_pkg::MIG_ADDR_WIDTH'(
      {pending_line_addr, {WORD_ADDR_SHIFT{1'b0}}});

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      pending_line_addr <= '0;
      line_rsp.valid <= 1'b0;
      line_rsp.data <= '0;
    end else begin
      line_rsp.valid <= 1'b0;

      unique case (state)
        STATE_IDLE: begin
          if (line_req.valid && line_req_ready) begin
            pending_line_addr <= line_req.addr;
            state <= STATE_SEND_READ;
          end
        end

        STATE_SEND_READ: begin
          if (mig_app_response.rdy)
            state <= STATE_WAIT_DATA;
        end

        STATE_WAIT_DATA: begin
          if (mig_app_response.rd_data_valid) begin
            line_rsp.data <= mig_app_response.rd_data[smart_artix_pkg::LINE_BITS-1:0];
            line_rsp.valid <= mig_app_response.rd_data_end;
            if (mig_app_response.rd_data_end)
              state <= STATE_IDLE;
          end
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end

/* verilator lint_off UNUSEDSIGNAL */
  logic unused_mig_write_ready;
/* verilator lint_on UNUSEDSIGNAL */
  assign unused_mig_write_ready = mig_app_response.wdf_rdy;
endmodule
