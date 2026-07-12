module smart_artix_ddr3_line_reader #(
  parameter int LINE_WORDS = 8,
  parameter int MIG_ADDR_WIDTH = 28,
  parameter int MIG_DATA_WIDTH = LINE_WORDS * 16,
  parameter int WORD_ADDR_SHIFT = 1
) (
  input  logic                     clk,
  input  logic                     rst,

  input  logic                     line_req_valid,
  output logic                     line_req_ready,
  input  logic [31:0]              line_req_addr,
  output logic                     line_rsp_valid,
  output logic [LINE_WORDS*16-1:0] line_rsp_data,

  input  logic                     mig_init_calib_complete,
  output logic [MIG_ADDR_WIDTH-1:0] mig_app_addr,
  output logic [2:0]               mig_app_cmd,
  output logic                     mig_app_en,
  input  logic                     mig_app_rdy,
  input  logic [MIG_DATA_WIDTH-1:0] mig_app_rd_data,
  input  logic                     mig_app_rd_data_valid,
  input  logic                     mig_app_rd_data_end
);
  localparam int LINE_BITS = LINE_WORDS * 16;
  localparam logic [2:0] MIG_CMD_READ = 3'b001;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_SEND_READ,
    STATE_WAIT_DATA
  } state_t;

  state_t state;
  logic [31:0] pending_line_addr;

  assign line_req_ready = mig_init_calib_complete && (state == STATE_IDLE);
  assign mig_app_cmd = MIG_CMD_READ;
  assign mig_app_en = state == STATE_SEND_READ;
  assign mig_app_addr = MIG_ADDR_WIDTH'({pending_line_addr, {WORD_ADDR_SHIFT{1'b0}}});

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      pending_line_addr <= '0;
      line_rsp_valid <= 1'b0;
      line_rsp_data <= '0;
    end else begin
      line_rsp_valid <= 1'b0;

      unique case (state)
        STATE_IDLE: begin
          if (line_req_valid && line_req_ready) begin
            pending_line_addr <= line_req_addr;
            state <= STATE_SEND_READ;
          end
        end

        STATE_SEND_READ: begin
          if (mig_app_rdy)
            state <= STATE_WAIT_DATA;
        end

        STATE_WAIT_DATA: begin
          if (mig_app_rd_data_valid) begin
            line_rsp_data <= mig_app_rd_data[LINE_BITS-1:0];
            line_rsp_valid <= mig_app_rd_data_end;
            if (mig_app_rd_data_end)
              state <= STATE_IDLE;
          end
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end
endmodule
