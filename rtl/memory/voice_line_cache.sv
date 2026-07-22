module voice_line_cache #(
  parameter int LINE_WORDS = 32,
  parameter int LINES_PER_VOICE = 2
) (
  input  logic                            clk,
  input  logic                            rst,
  input  synth_pkg::wave_word_req_t       req,
  output logic                            req_ready,
  output synth_pkg::wave_word_rsp_t       rsp,
  output logic                            ext_req_valid,
  input  logic                            ext_req_ready,
  output logic [synth_pkg::ADDR_WIDTH-1:0] ext_req_addr,
  input  logic                            ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0]        ext_rsp_data,
  output logic                            response_trace_pulse,
  output logic [15:0]                     response_trace_latency,
  output logic                            demand_hit_pulse,
  output logic                            demand_miss_pulse,
  output logic                            line_fill_pulse,
  output logic                            same_line_endpoint_hit_pulse,
  output logic                            replacement_pulse
);
  import synth_pkg::*;

  localparam int INDEX_WIDTH = $clog2(LINE_WORDS);
  localparam int TAG_WIDTH = ADDR_WIDTH - INDEX_WIDTH;
  localparam int WAY_WIDTH = (LINES_PER_VOICE <= 1) ? 1 : $clog2(LINES_PER_VOICE);

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_EXT_REQ,
    STATE_EXT_WAIT,
    STATE_RESPOND
  } state_t;

  state_t state;
  logic [NUM_VOICES-1:0][LINES_PER_VOICE-1:0] cache_valid;
  logic [NUM_VOICES-1:0][LINES_PER_VOICE-1:0][TAG_WIDTH-1:0] cache_tag;
  logic [NUM_VOICES-1:0][LINES_PER_VOICE-1:0][LINE_WORDS*PCM_WIDTH-1:0] cache_line;
  logic [NUM_VOICES-1:0][WAY_WIDTH-1:0] replace_way;

  logic [VOICE_ID_WIDTH-1:0] pending_voice;
  logic [TAG_WIDTH-1:0] pending_tag;
  logic [INDEX_WIDTH-1:0] pending_index;
  logic [WAY_WIDTH-1:0] pending_way;
  logic [ADDR_WIDTH-1:0] pending_line_addr;
  logic [15:0] latency_counter;

  logic hit;
  logic [WAY_WIDTH-1:0] fill_way;
  logic fill_replaces_valid;
  pcm_t hit_data;
  logic previous_accept_valid;
  logic [VOICE_ID_WIDTH-1:0] previous_accept_voice;
  logic [TAG_WIDTH-1:0] previous_accept_tag;

  assign req_ready = (state == STATE_IDLE);
  assign ext_req_valid = (state == STATE_EXT_REQ);
  assign ext_req_addr = pending_line_addr;

  always_comb begin
    hit = 1'b0;
    hit_data = '0;
    fill_way = replace_way[req.voice];
    fill_replaces_valid = cache_valid[req.voice][replace_way[req.voice]];

    for (int w = 0; w < LINES_PER_VOICE; w++) begin
      if (cache_valid[req.voice][w] && cache_tag[req.voice][w] == req.addr[ADDR_WIDTH-1:INDEX_WIDTH]) begin
        hit = 1'b1;
        hit_data = cache_line[req.voice][w][req.addr[INDEX_WIDTH-1:0] * PCM_WIDTH +: PCM_WIDTH];
      end
      if (!cache_valid[req.voice][w]) begin
        fill_way = WAY_WIDTH'(w);
        fill_replaces_valid = 1'b0;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      cache_valid <= '0;
      replace_way <= '0;
      pending_voice <= '0;
      pending_tag <= '0;
      pending_index <= '0;
      pending_way <= '0;
      pending_line_addr <= '0;
      latency_counter <= '0;
      rsp <= '0;
      response_trace_pulse <= 1'b0;
      response_trace_latency <= '0;
      demand_hit_pulse <= 1'b0;
      demand_miss_pulse <= 1'b0;
      line_fill_pulse <= 1'b0;
      same_line_endpoint_hit_pulse <= 1'b0;
      replacement_pulse <= 1'b0;
      previous_accept_valid <= 1'b0;
      previous_accept_voice <= '0;
      previous_accept_tag <= '0;
    end else begin
      rsp.valid <= 1'b0;
      response_trace_pulse <= 1'b0;
      demand_hit_pulse <= 1'b0;
      demand_miss_pulse <= 1'b0;
      line_fill_pulse <= 1'b0;
      same_line_endpoint_hit_pulse <= 1'b0;
      replacement_pulse <= 1'b0;

      unique case (state)
        STATE_IDLE: begin
          if (req.valid) begin
            pending_voice <= req.voice;
            pending_tag <= req.addr[ADDR_WIDTH-1:INDEX_WIDTH];
            pending_index <= req.addr[INDEX_WIDTH-1:0];
            pending_way <= fill_way;
            pending_line_addr <= {req.addr[ADDR_WIDTH-1:INDEX_WIDTH], {INDEX_WIDTH{1'b0}}};
            latency_counter <= 16'd0;
            previous_accept_valid <= 1'b1;
            previous_accept_voice <= req.voice;
            previous_accept_tag <= req.addr[ADDR_WIDTH-1:INDEX_WIDTH];
            if (hit) begin
              rsp.data <= hit_data;
              demand_hit_pulse <= 1'b1;
              same_line_endpoint_hit_pulse <= previous_accept_valid &&
                                              previous_accept_voice == req.voice &&
                                              previous_accept_tag == req.addr[ADDR_WIDTH-1:INDEX_WIDTH];
              state <= STATE_RESPOND;
            end else begin
              demand_miss_pulse <= 1'b1;
              replacement_pulse <= fill_replaces_valid;
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
            cache_valid[pending_voice][pending_way] <= 1'b1;
            cache_tag[pending_voice][pending_way] <= pending_tag;
            cache_line[pending_voice][pending_way] <= ext_rsp_data;
            replace_way[pending_voice] <= (pending_way == WAY_WIDTH'(LINES_PER_VOICE - 1)) ? '0 : pending_way + 1'b1;
            rsp.data <= ext_rsp_data[pending_index * PCM_WIDTH +: PCM_WIDTH];
            line_fill_pulse <= 1'b1;
            state <= STATE_RESPOND;
          end
        end

        STATE_RESPOND: begin
          rsp.valid <= 1'b1;
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
