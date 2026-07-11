module wave_memory_model #(
  parameter int DEPTH = 256
) (
  input  logic                    clk,
  input  logic                    rst,
  input  logic                    req_valid,
  output logic                    req_ready,
  input  logic [31:0]             req_addr,
  output logic                    rsp_valid,
  output synth_pkg::pcm_t         rsp_data
);
  synth_pkg::pcm_t memory [0:DEPTH-1];

  assign req_ready = 1'b1;

  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_valid <= 1'b0;
      rsp_data <= '0;
    end else begin
      rsp_valid <= req_valid;
      if (req_valid) begin
        if (req_addr < DEPTH)
          rsp_data <= memory[req_addr];
        else
          rsp_data <= '0;
      end
    end
  end
endmodule
