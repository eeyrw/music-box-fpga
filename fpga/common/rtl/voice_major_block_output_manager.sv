module voice_major_block_output_manager #(
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
) (
  input  logic                                      clk,
  input  logic                                      rst,

  input  logic                                      request_valid,
  output logic                                      request_ready,
  input  synth_pkg::render_block_req_t              request,
  output logic                                      request_accepted_pulse,

  output logic                                      block_req_valid,
  input  logic                                      block_req_ready,
  output synth_pkg::render_block_req_t              block_req,
  input  logic                                      renderer_busy,

  input  logic                                      block_complete_valid,
  output logic                                      block_complete_ready,
/* verilator lint_off UNUSEDSIGNAL */
  // Ordered output ownership only consumes the bank ID and frame count.
  input  synth_pkg::render_block_complete_t         block_complete,
/* verilator lint_on UNUSEDSIGNAL */
  output logic                                      renderer_complete_pulse,
  output logic                                      completion_accepted_pulse,

  output logic                                      block_read_req_valid,
  input  logic                                      block_read_req_ready,
  output synth_pkg::render_block_read_req_t         block_read_req,
  input  logic                                      block_read_rsp_valid,
  output logic                                      block_read_rsp_ready,

  output logic                                      block_release_valid,
  input  logic                                      block_release_ready,
  output logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                     block_release_buffer_id,
  output logic                                      release_accepted_pulse,

  output logic                                      sample_valid,
  input  logic                                      sample_ready,
  input  logic                                      effects_busy,
  output logic                                      drain_busy,
  output logic                                      block_pipeline_busy,
  output logic                                      render_inflight,
  output logic                                      render_deadline_miss_pulse,
  output logic [15:0]                               render_latency_cycles
);
  import synth_pkg::*;

  typedef enum logic [1:0] {
    OUTPUT_IDLE,
    OUTPUT_READ_REQUEST,
    OUTPUT_READ_RESPONSE,
    OUTPUT_RELEASE
  } output_state_t;

  output_state_t output_state_q;
  logic [BLOCK_BUFFER_ID_WIDTH-1:0] output_buffer_q;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] output_frame_count_q;
  logic [BLOCK_FRAME_INDEX_WIDTH-1:0] output_index_q;
  logic render_request_active_q;
  logic render_completion_seen_q;
  logic [BLOCK_FRAME_COUNT_WIDTH-1:0] request_frame_count_q;
  logic [31:0] render_cycle_count_q;

  assign block_req_valid = request_valid && !render_request_active_q;
  assign block_req = request;
  assign request_ready = block_req_ready && !render_request_active_q;

  // A published bank remains backpressured while the preceding bank drains.
  // Its render latency is captured on first sight, not ownership transfer.
  assign block_complete_ready = output_state_q == OUTPUT_IDLE;

  assign block_read_req_valid = output_state_q == OUTPUT_READ_REQUEST;
  assign block_read_req.buffer_id = output_buffer_q;
  assign block_read_req.frame_index = output_index_q;
  assign sample_valid = (output_state_q == OUTPUT_READ_RESPONSE) &&
                        block_read_rsp_valid;
  assign block_read_rsp_ready = sample_valid && sample_ready;

  assign block_release_valid = output_state_q == OUTPUT_RELEASE;
  assign block_release_buffer_id = output_buffer_q;
  assign drain_busy = output_state_q != OUTPUT_IDLE;
  assign block_pipeline_busy = render_request_active_q || renderer_busy ||
                               drain_busy;
  assign render_inflight = block_pipeline_busy || effects_busy;

  always_ff @(posedge clk) begin
    if (rst) begin
      output_state_q <= OUTPUT_IDLE;
      output_buffer_q <= '0;
      output_frame_count_q <= '0;
      output_index_q <= '0;
      render_request_active_q <= 1'b0;
      render_completion_seen_q <= 1'b0;
      request_frame_count_q <= '0;
      render_cycle_count_q <= '0;
      request_accepted_pulse <= 1'b0;
      renderer_complete_pulse <= 1'b0;
      completion_accepted_pulse <= 1'b0;
      release_accepted_pulse <= 1'b0;
      render_deadline_miss_pulse <= 1'b0;
      render_latency_cycles <= '0;
    end else begin
      request_accepted_pulse <= 1'b0;
      renderer_complete_pulse <= 1'b0;
      completion_accepted_pulse <= 1'b0;
      release_accepted_pulse <= 1'b0;
      render_deadline_miss_pulse <= 1'b0;

      if (render_request_active_q && !render_completion_seen_q &&
          render_cycle_count_q != 32'hffff_ffff)
        render_cycle_count_q <= render_cycle_count_q + 1'b1;

      if (block_req_valid && block_req_ready) begin
        render_request_active_q <= 1'b1;
        render_completion_seen_q <= 1'b0;
        request_frame_count_q <= request.frame_count;
        render_cycle_count_q <= '0;
        request_accepted_pulse <= 1'b1;
      end

      if (render_request_active_q && !render_completion_seen_q &&
          block_complete_valid) begin
        render_completion_seen_q <= 1'b1;
        renderer_complete_pulse <= 1'b1;
        render_latency_cycles <= render_cycle_count_q[15:0];
        if (render_cycle_count_q >
            (SYS_CLK_HZ * 32'(request_frame_count_q)) / SAMPLE_RATE_HZ)
          render_deadline_miss_pulse <= 1'b1;
      end

      if (block_complete_valid && block_complete_ready) begin
        output_buffer_q <= block_complete.buffer_id;
        output_frame_count_q <= block_complete.frame_count;
        output_index_q <= '0;
        render_request_active_q <= 1'b0;
        completion_accepted_pulse <= 1'b1;
        output_state_q <= OUTPUT_READ_REQUEST;
      end

      unique case (output_state_q)
        OUTPUT_IDLE: begin
        end
        OUTPUT_READ_REQUEST: begin
          if (block_read_req_valid && block_read_req_ready)
            output_state_q <= OUTPUT_READ_RESPONSE;
        end
        OUTPUT_READ_RESPONSE: begin
          if (block_read_rsp_valid && block_read_rsp_ready) begin
            if (BLOCK_FRAME_COUNT_WIDTH'(output_index_q) + 1'b1 >=
                output_frame_count_q) begin
              output_state_q <= OUTPUT_RELEASE;
            end else begin
              output_index_q <= output_index_q + 1'b1;
              output_state_q <= OUTPUT_READ_REQUEST;
            end
          end
        end
        OUTPUT_RELEASE: begin
          if (block_release_valid && block_release_ready) begin
            release_accepted_pulse <= 1'b1;
            output_state_q <= OUTPUT_IDLE;
          end
        end
        default: output_state_q <= OUTPUT_IDLE;
      endcase
    end
  end
endmodule
