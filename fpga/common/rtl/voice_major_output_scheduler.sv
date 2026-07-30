module voice_major_output_scheduler #(
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
) (
  input  logic                                      clk,
  input  logic                                      rst,
  input  logic                                      output_fifo_room,

  output logic                                      block_req_valid,
  input  logic                                      block_req_ready,
  output synth_pkg::render_block_req_t              block_req,
  input  logic                                      renderer_busy,

  input  logic                                      block_complete_valid,
  output logic                                      block_complete_ready,
/* verilator lint_off UNUSEDSIGNAL */
  // Ordered completion means the drain side only needs bank ID and frame count.
  input  synth_pkg::render_block_complete_t         block_complete,
/* verilator lint_on UNUSEDSIGNAL */

  output logic                                      block_read_req_valid,
  input  logic                                      block_read_req_ready,
  output synth_pkg::render_block_read_req_t         block_read_req,
  input  logic                                      block_read_rsp_valid,
  output logic                                      block_read_rsp_ready,

  output logic                                      block_release_valid,
  input  logic                                      block_release_ready,
  output logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                     block_release_buffer_id,

  output logic                                      sample_valid,
  input  logic                                      sample_ready,
  input  logic                                      effects_busy,
  output logic                                      render_inflight,
  output logic                                      render_deadline_miss_pulse,
  output logic [15:0]                               render_latency_cycles
);
  import synth_pkg::*;

  logic [TIMELINE_FRAME_WIDTH-1:0] next_frame_q;
  render_block_req_t timeline_request;
  logic request_accepted_pulse;

  assign timeline_request.start_frame = next_frame_q;
  assign timeline_request.frame_count = BLOCK_FRAME_COUNT_WIDTH'(MAX_BLOCK_FRAMES);

  always_ff @(posedge clk) begin
    if (rst) begin
      next_frame_q <= '0;
    end else if (request_accepted_pulse) begin
        next_frame_q <= next_frame_q + MAX_BLOCK_FRAMES;
    end
  end

  /* verilator lint_off PINCONNECTEMPTY */
  voice_major_block_output_manager #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) manager (
    .clk,
    .rst,
    .request_valid(output_fifo_room),
    .request_ready(),
    .request(timeline_request),
    .request_accepted_pulse,
    .block_req_valid,
    .block_req_ready,
    .block_req,
    .renderer_busy,
    .block_complete_valid,
    .block_complete_ready,
    .block_complete,
    .renderer_complete_pulse(),
    .completion_accepted_pulse(),
    .block_read_req_valid,
    .block_read_req_ready,
    .block_read_req,
    .block_read_rsp_valid,
    .block_read_rsp_ready,
    .block_release_valid,
    .block_release_ready,
    .block_release_buffer_id,
    .release_accepted_pulse(),
    .sample_valid,
    .sample_ready,
    .effects_busy,
    .drain_busy(),
    .block_pipeline_busy(),
    .render_inflight,
    .render_deadline_miss_pulse,
    .render_latency_cycles
  );
  /* verilator lint_on PINCONNECTEMPTY */
endmodule
