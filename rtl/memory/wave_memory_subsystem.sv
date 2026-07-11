module wave_memory_subsystem #(
  parameter int LINE_WORDS = 8
) (
  input  logic                            clk,
  input  logic                            rst,
  input  logic                            core_req_valid,
  output logic                            core_req_ready,
  input  logic [31:0]                     core_req_addr,
  output logic                            core_rsp_valid,
  output synth_pkg::pcm_t                 core_rsp_data,
  output logic                            ext_req_valid,
  input  logic                            ext_req_ready,
  output logic [31:0]                     ext_req_addr,
  input  logic                            ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0]        ext_rsp_data,
  output logic                            debug_hit_pulse,
  output logic                            debug_miss_pulse,
  output logic                            debug_response_pulse,
  output logic [15:0]                     debug_response_latency
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

  assign core_req_ready = (state == STATE_IDLE);
  assign ext_req_valid = (state == STATE_EXT_REQ);
  assign ext_req_addr = pending_line_addr;

  always_comb begin
    pending_hit = cache_valid && (cache_tag == core_req_addr[31:INDEX_WIDTH]);
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
      core_rsp_valid <= 1'b0;
      core_rsp_data <= '0;
      debug_hit_pulse <= 1'b0;
      debug_miss_pulse <= 1'b0;
      debug_response_pulse <= 1'b0;
      debug_response_latency <= '0;
    end else begin
      core_rsp_valid <= 1'b0;
      debug_hit_pulse <= 1'b0;
      debug_miss_pulse <= 1'b0;
      debug_response_pulse <= 1'b0;

      unique case (state)
        STATE_IDLE: begin
          if (core_req_valid) begin
            pending_tag <= core_req_addr[31:INDEX_WIDTH];
            pending_index <= core_req_addr[INDEX_WIDTH-1:0];
            pending_line_addr <= {core_req_addr[31:INDEX_WIDTH], {INDEX_WIDTH{1'b0}}};
            latency_counter <= 16'd0;
            if (pending_hit) begin
              core_rsp_data <= cache_line[core_req_addr[INDEX_WIDTH-1:0] * 16 +: 16];
              debug_hit_pulse <= 1'b1;
              state <= STATE_RESPOND;
            end else begin
              debug_miss_pulse <= 1'b1;
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
            core_rsp_data <= ext_rsp_data[pending_index * 16 +: 16];
            state <= STATE_RESPOND;
          end
        end

        STATE_RESPOND: begin
          core_rsp_valid <= 1'b1;
          debug_response_pulse <= 1'b1;
          debug_response_latency <= latency_counter;
          state <= STATE_IDLE;
        end

        default: state <= STATE_IDLE;
      endcase

      if (state != STATE_IDLE && state != STATE_RESPOND && latency_counter != 16'hffff)
        latency_counter <= latency_counter + 16'd1;
    end
  end
endmodule
