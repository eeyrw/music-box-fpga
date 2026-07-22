module wave_memory_subsystem #(
  parameter int LINE_WORDS = 8
) (
  input  logic                            clk,
  input  logic                            rst,
  input  synth_pkg::wave_word_req_t       core_req,
  output logic                            core_req_ready,
  output synth_pkg::wave_word_rsp_t       core_rsp,
  output logic                            ext_req_valid,
  input  logic                            ext_req_ready,
  output logic [31:0]                     ext_req_addr,
  input  logic                            ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0]        ext_rsp_data,
  output logic                            response_trace_pulse,
  output logic [15:0]                     response_trace_latency
);
  import synth_pkg::*;

  localparam int INDEX_WIDTH = $clog2(LINE_WORDS);
  localparam int TAG_WIDTH = 32 - INDEX_WIDTH;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_EXT_REQ,
    STATE_EXT_WAIT,
    STATE_RESPOND
  } state_t;

  state_t state;
  logic cache_valid;
  logic [TAG_WIDTH-1:0] cache_tag;
  logic [LINE_WORDS*16-1:0] cache_line;
  logic [TAG_WIDTH-1:0] pending_tag;
  logic [INDEX_WIDTH-1:0] pending_index;
  logic [31:0] pending_line_addr;
  logic pending_hit;
  logic [15:0] latency_counter;
  logic [VOICE_ID_WIDTH-1:0] unused_core_req_voice;

  assign core_req_ready = (state == STATE_IDLE);
  assign ext_req_valid = (state == STATE_EXT_REQ);
  assign ext_req_addr = pending_line_addr;
  assign unused_core_req_voice = core_req.voice;

  always_comb begin
    pending_hit = cache_valid && (cache_tag == core_req.addr[31:INDEX_WIDTH]);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      cache_valid <= 1'b0;
      cache_tag <= '0;
      cache_line <= '0;
      pending_tag <= '0;
      pending_index <= '0;
      pending_line_addr <= '0;
      latency_counter <= '0;
      core_rsp <= '0;
      response_trace_pulse <= 1'b0;
      response_trace_latency <= '0;
    end else begin
      core_rsp.valid <= 1'b0;
      response_trace_pulse <= 1'b0;

      unique case (state)
        STATE_IDLE: begin
          if (core_req.valid) begin
            pending_tag <= core_req.addr[31:INDEX_WIDTH];
            pending_index <= core_req.addr[INDEX_WIDTH-1:0];
            pending_line_addr <= {core_req.addr[31:INDEX_WIDTH], {INDEX_WIDTH{1'b0}}};
            latency_counter <= 16'd0;
            if (pending_hit) begin
              core_rsp.data <= cache_line[core_req.addr[INDEX_WIDTH-1:0] * 16 +: 16];
              state <= STATE_RESPOND;
            end else begin
              state <= STATE_EXT_REQ;
            end
          end
        end

        STATE_EXT_REQ: begin
          if (ext_req_ready)
            state <= STATE_EXT_WAIT;
        end

        STATE_EXT_WAIT: begin
          if (ext_rsp_valid) begin
            cache_valid <= 1'b1;
            cache_tag <= pending_tag;
            cache_line <= ext_rsp_data;
            core_rsp.data <= ext_rsp_data[pending_index * 16 +: 16];
            state <= STATE_RESPOND;
          end
        end

        STATE_RESPOND: begin
          core_rsp.valid <= 1'b1;
          response_trace_pulse <= 1'b1;
          response_trace_latency <= latency_counter;
          state <= STATE_IDLE;
        end

        default: state <= STATE_IDLE;
      endcase

      if (state != STATE_IDLE && state != STATE_RESPOND && latency_counter != 16'hffff)
        latency_counter <= latency_counter + 16'd1;
    end
  end
endmodule
