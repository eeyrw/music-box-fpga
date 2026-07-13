module voice_bram_1w2r #(
  parameter int NUM_WORDS = synth_pkg::NUM_VOICES,
  parameter int ADDR_WIDTH = $clog2(NUM_WORDS),
  parameter int DATA_WIDTH = 32,
  parameter logic [DATA_WIDTH-1:0] DEFAULT_WORD = '0
) (
  input  logic                  clk,
  input  logic                  write_en,
  input  logic [ADDR_WIDTH-1:0] write_addr,
  input  logic [DATA_WIDTH-1:0] write_data,
  input  logic [ADDR_WIDTH-1:0] read_addr_a,
  output logic [DATA_WIDTH-1:0] read_data_a,
  input  logic [ADDR_WIDTH-1:0] read_addr_b,
  output logic [DATA_WIDTH-1:0] read_data_b
);
  (* ram_style = "block" *) logic [DATA_WIDTH-1:0] mem [0:NUM_WORDS-1];

  initial begin
    for (int i = 0; i < NUM_WORDS; i++) begin
      mem[i] = DEFAULT_WORD;
    end
  end

  always_ff @(posedge clk) begin
    if (write_en) begin
      mem[write_addr] <= write_data;
    end

    read_data_a <= mem[read_addr_a];
    read_data_b <= mem[read_addr_b];
  end
endmodule
