module block_voice_event_executor (
  input  logic                                      clk,
  input  logic                                      rst,

  input  logic                                      event_valid,
  output logic                                      event_ready,
  input  synth_pkg::block_voice_event_t             event_in,
  input  logic                                      boundary_open,
  input  logic [synth_pkg::TIMELINE_FRAME_WIDTH-1:0] boundary_frame,

  output logic                                      install_valid,
  input  logic                                      install_ready,
  output logic [synth_pkg::VOICE_ID_WIDTH-1:0]      install_voice,
  output synth_pkg::block_voice_state_snapshot_t   install_state,

  output logic                                      control_event_valid,
  input  logic                                      control_event_ready,
  output synth_pkg::block_voice_event_t             control_event,
  input  logic                                      control_event_done_pulse,
  input  logic                                      stale_control_event_pulse,

  output logic                                      result_valid,
  input  logic                                      result_ready,
  output synth_pkg::block_voice_event_result_t     result,
  output logic                                      late_event_sticky
);
  import synth_pkg::*;

  typedef enum logic [2:0] {
    EXEC_IDLE,
    EXEC_WAIT_BOUNDARY,
    EXEC_DISPATCH,
    EXEC_WAIT_STORE,
    EXEC_RESULT
  } executor_state_t;

  executor_state_t state_q;
  block_voice_event_t event_q;
  block_voice_event_result_t result_q;
  logic signed [TIMELINE_FRAME_WIDTH-1:0] frame_delta;
  logic eligible;
  logic bad_time;
  logic bad_voice;

  assign frame_delta = $signed(event_q.target_frame - boundary_frame);
  assign eligible = frame_delta <= 0;
  assign bad_time = (event_q.target_frame - boundary_frame) ==
                    {1'b1, {(TIMELINE_FRAME_WIDTH-1){1'b0}}};
  assign bad_voice = event_q.host_voice_id >= 16'(NUM_VOICES);

  assign event_ready = state_q == EXEC_IDLE;
  assign install_valid = (state_q == EXEC_DISPATCH) &&
                         (event_q.kind == BLOCK_VOICE_START) &&
                         !bad_voice && !bad_time;
  assign install_voice = event_q.host_voice_id[VOICE_ID_WIDTH-1:0];
  always_comb begin
    install_state = '0;
    install_state.region = event_q.descriptor.region;
    install_state.event_params = event_q.event_params;
    install_state.env_params = event_q.env_params;
    install_state.dynamic.active = 1'b1;
    install_state.dynamic.generation = event_q.generation;
    install_state.dynamic.phase = event_q.descriptor.phase_init;
    install_state.dynamic.env_state = event_q.start_env_state;
  end

  assign control_event_valid = (state_q == EXEC_DISPATCH) &&
                               (event_q.kind != BLOCK_VOICE_START) &&
                               !bad_voice && !bad_time;
  assign control_event = event_q;
  assign result_valid = state_q == EXEC_RESULT;
  assign result = result_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= EXEC_IDLE;
      event_q <= '0;
      result_q <= '0;
      late_event_sticky <= 1'b0;
    end else begin
      unique case (state_q)
        EXEC_IDLE: begin
          if (event_valid && event_ready) begin
            event_q <= event_in;
            state_q <= EXEC_WAIT_BOUNDARY;
          end
        end
        EXEC_WAIT_BOUNDARY: begin
          if (boundary_open && eligible) begin
            result_q.target_frame <= event_q.target_frame;
            result_q.host_voice_id <= event_q.host_voice_id;
            result_q.generation <= event_q.generation;
            result_q.kind <= event_q.kind;
            if (frame_delta < 0)
              late_event_sticky <= 1'b1;
            state_q <= EXEC_DISPATCH;
          end
        end
        EXEC_DISPATCH: begin
          if (bad_voice) begin
            result_q.status <= BLOCK_EVENT_BAD_VOICE;
            state_q <= EXEC_RESULT;
          end else if (bad_time) begin
            result_q.status <= BLOCK_EVENT_BAD_TIME;
            state_q <= EXEC_RESULT;
          end else if (event_q.kind == BLOCK_VOICE_START) begin
            if (install_valid && install_ready) begin
              result_q.status <= BLOCK_EVENT_APPLIED;
              state_q <= EXEC_RESULT;
            end
          end else if (control_event_valid && control_event_ready) begin
            state_q <= EXEC_WAIT_STORE;
          end
        end
        EXEC_WAIT_STORE: begin
          if (control_event_done_pulse) begin
            result_q.status <= stale_control_event_pulse ?
                BLOCK_EVENT_STALE : BLOCK_EVENT_APPLIED;
            state_q <= EXEC_RESULT;
          end
        end
        EXEC_RESULT: begin
          if (result_valid && result_ready)
            state_q <= EXEC_IDLE;
        end
        default: state_q <= EXEC_IDLE;
      endcase
    end
  end
endmodule
