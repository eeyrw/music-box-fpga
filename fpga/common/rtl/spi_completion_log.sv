module spi_completion_log #(
  parameter int DEPTH = 512,
  parameter int BATCH_ITEMS = 16
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         clear,

  input  logic         event_valid,
  input  logic [8:0]   event_voice,
  input  logic [15:0]  event_generation,
  input  logic [1:0]   event_reason,

  input  logic         query_valid,
  output logic         query_ready,
  input  logic [15:0]  query_sequence,

  input  logic         read_clk,
  input  logic [$clog2(DEPTH)-1:0] read_address,
  output logic [31:0]  read_data,

  output logic         response_valid,
  output logic [7:0]   response_status,
  output logic [15:0]  response_start_sequence,
  output logic [15:0]  response_write_sequence,
  output logic [7:0]   response_count,
  output logic         response_overflow
);
  localparam int ADDRESS_WIDTH = $clog2(DEPTH);

  (* ram_style = "block" *) logic [31:0] log_mem [0:DEPTH-1];
  logic [15:0] write_sequence_q;
  logic [15:0] acknowledge_sequence_q;
  logic overflow_q;

  logic query_fire;
  logic query_sequence_valid;
  logic [15:0] query_available;
  logic [15:0] acknowledged_available;
  logic event_write_enable;
  logic [15:0] effective_acknowledge_sequence;

  assign query_ready = 1'b1;
  assign query_fire = query_valid && query_ready;
  assign acknowledged_available =
      write_sequence_q - acknowledge_sequence_q;
  assign query_sequence_valid =
      (query_sequence - acknowledge_sequence_q) <= acknowledged_available;
  assign query_available = write_sequence_q - query_sequence;
  assign effective_acknowledge_sequence =
      query_fire && query_sequence_valid ? query_sequence :
                                           acknowledge_sequence_q;
  assign event_write_enable = event_valid &&
      ((write_sequence_q - effective_acknowledge_sequence) < 16'(DEPTH));
  always_ff @(posedge clk) begin
    if (event_write_enable)
      log_mem[write_sequence_q[ADDRESS_WIDTH-1:0]] <= {
        event_generation, event_voice, 1'b0, event_reason, 4'd0
      };
  end

  // The physical BRAM's second port belongs to the SPI clock domain. Entries
  // at or beyond the acknowledged sequence cannot be overwritten, so the SPI
  // response can stream directly from the log without a 512-bit snapshot.
  always_ff @(posedge read_clk)
    read_data <= log_mem[read_address];

  always_ff @(posedge clk) begin : completion_log_control
    logic [7:0] bounded_count;
    if (rst || clear) begin
      write_sequence_q <= '0;
      acknowledge_sequence_q <= '0;
      overflow_q <= 1'b0;
      response_valid <= 1'b0;
      response_status <= '0;
      response_start_sequence <= '0;
      response_write_sequence <= '0;
      response_count <= '0;
      response_overflow <= 1'b0;
    end else begin
      response_valid <= 1'b0;

      if (event_valid) begin
        if (event_write_enable)
          write_sequence_q <= write_sequence_q + 1'b1;
        else
          overflow_q <= 1'b1;
      end

      if (query_fire) begin
        response_start_sequence <= query_sequence;
        response_write_sequence <= write_sequence_q;
        response_overflow <= overflow_q ||
            (event_valid && !event_write_enable);
        if (!query_sequence_valid) begin
          response_status <= 8'd1;
          response_count <= '0;
          response_valid <= 1'b1;
        end else begin
          bounded_count = query_available > 16'(BATCH_ITEMS) ?
              8'(BATCH_ITEMS) : query_available[7:0];
          acknowledge_sequence_q <= query_sequence;
          response_status <= 8'd0;
          response_count <= bounded_count;
          response_valid <= 1'b1;
        end
      end
    end
  end
endmodule
