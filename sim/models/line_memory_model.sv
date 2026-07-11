module line_memory_model #(
  parameter int DEPTH = 256,
  parameter int LINE_WORDS = 8,
  parameter int LATENCY = 3,
  parameter int RANDOM_LATENCY = LATENCY,
  parameter int SEQUENTIAL_LATENCY = LATENCY,
  parameter int READY_GAP = 0
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     req_valid,
  output logic                     req_ready,
  input  logic [31:0]              req_addr,
  output logic                     rsp_valid,
  output logic [LINE_WORDS*16-1:0] rsp_data
);
  logic signed [15:0] memory [0:DEPTH-1];
  logic [31:0] pending_addr;
  logic [31:0] last_line_addr;
  int countdown;
  int ready_gap_countdown;
  logic busy;
  logic have_last_line_addr;
  logic sequential_request;

  assign req_ready = !busy && (ready_gap_countdown == 0);
  assign sequential_request = have_last_line_addr && (req_addr == last_line_addr + LINE_WORDS);

  always_ff @(posedge clk) begin
    if (rst) begin
      pending_addr <= '0;
      last_line_addr <= '0;
      countdown <= 0;
      ready_gap_countdown <= 0;
      busy <= 1'b0;
      have_last_line_addr <= 1'b0;
      rsp_valid <= 1'b0;
      rsp_data <= '0;
    end else begin
      rsp_valid <= 1'b0;

      if (req_valid && req_ready) begin
        pending_addr <= req_addr;
        last_line_addr <= req_addr;
        have_last_line_addr <= 1'b1;
        countdown <= sequential_request ? SEQUENTIAL_LATENCY : RANDOM_LATENCY;
        busy <= 1'b1;
      end else if (ready_gap_countdown > 0) begin
        ready_gap_countdown <= ready_gap_countdown - 1;
      end else if (busy) begin
        if (countdown == 0) begin
          for (int w = 0; w < LINE_WORDS; w++) begin
            if (pending_addr + w < DEPTH)
              rsp_data[w * 16 +: 16] <= memory[pending_addr + w];
            else
              rsp_data[w * 16 +: 16] <= '0;
          end
          rsp_valid <= 1'b1;
          busy <= 1'b0;
          ready_gap_countdown <= READY_GAP;
        end else begin
          countdown <= countdown - 1;
        end
      end
    end
  end
endmodule
