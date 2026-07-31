// Simulation-only, single-clock line memory for fast functional RTL renders.
module direct_line_memory_model #(
  parameter int ADDR_WIDTH = 32,
  parameter int LINE_WORDS = 8
) (
  input  logic                              clk,
  input  logic                              rst,
  input  logic                              req_valid,
  output logic                              req_ready,
  input  logic [ADDR_WIDTH-1:0]             req_addr,
  output logic                              rsp_valid,
  input  logic                              rsp_ready,
  output logic [LINE_WORDS*16-1:0]          rsp_data,
  output logic [63:0]                       stat_accepted,
  output logic [63:0]                       stat_returned
);
  import "DPI-C" function int ddr3_bin_open(input string path);
  import "DPI-C" function void ddr3_bin_read_line8(
      input int handle, input longint unsigned word_addr,
      output int unsigned words_1_0, output int unsigned words_3_2,
      output int unsigned words_5_4, output int unsigned words_7_6);
  import "DPI-C" function longint unsigned ddr3_bin_word_count(input int handle);
  import "DPI-C" function void ddr3_bin_close(input int handle);

  int image_handle = -1;
  string image_path;
  int unsigned line_words_1_0;
  int unsigned line_words_3_2;
  int unsigned line_words_5_4;
  int unsigned line_words_7_6;

  initial begin
    if (LINE_WORDS != 8)
      $fatal(1, "direct_line_memory_model requires LINE_WORDS=8");
    if (!$value$plusargs("DIRECT_MEMORY_IMAGE=%s", image_path))
      $fatal(1, "direct_line_memory_model requires +DIRECT_MEMORY_IMAGE=<path>");
    image_handle = ddr3_bin_open(image_path);
    if (image_handle < 0)
      $fatal(1, "direct_line_memory_model failed to load '%s'", image_path);
    $display("DIRECT_MEMORY image=%s words=%0d", image_path,
             ddr3_bin_word_count(image_handle));
  end

  final begin
    if (image_handle >= 0) ddr3_bin_close(image_handle);
  end

  assign req_ready = !rsp_valid || rsp_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_valid <= 1'b0;
      rsp_data <= '0;
      stat_accepted <= '0;
      stat_returned <= '0;
    end else begin
      if (rsp_valid && rsp_ready) begin
        rsp_valid <= 1'b0;
        stat_returned <= stat_returned + 1'b1;
      end
      if (req_valid && req_ready) begin
        if ((req_addr % LINE_WORDS) != 0)
          $fatal(1, "direct_line_memory_model accepted unaligned line address %0h",
                 req_addr);
        ddr3_bin_read_line8(image_handle, 64'(req_addr),
                            line_words_1_0, line_words_3_2,
                            line_words_5_4, line_words_7_6);
        rsp_data <= {line_words_7_6, line_words_5_4,
                     line_words_3_2, line_words_1_0};
        rsp_valid <= 1'b1;
        stat_accepted <= stat_accepted + 1'b1;
      end
    end
  end
endmodule
