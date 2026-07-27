module block_voice_state_store (
  input  logic                                      clk,
  input  logic                                      rst,
  input  logic                                      render_busy,

  input  logic                                      install_valid,
  output logic                                      install_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      install_voice,
  input  synth_pkg::block_voice_state_snapshot_t   install_state,

  input  logic                                      params_write_valid,
  output logic                                      params_write_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      params_write_voice,
  input  logic [synth_pkg::VOICE_GENERATION_WIDTH-1:0]
                                                    params_write_generation,
  input  synth_pkg::voice_event_params_t            params_write_event,
  input  synth_pkg::volume_env_params_t             params_write_env,

  input  logic                                      control_event_valid,
  output logic                                      control_event_ready,
  input  synth_pkg::block_voice_event_t             control_event,
  output logic                                      control_event_done_pulse,
  output logic                                      stale_control_event_pulse,

  input  logic                                      state_read_req_valid,
  output logic                                      state_read_req_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      state_read_req_voice,
  output logic                                      state_read_rsp_valid,
  input  logic                                      state_read_rsp_ready,
  output synth_pkg::block_voice_state_snapshot_t   state_read_rsp,

  input  logic                                      dynamic_write_valid,
  output logic                                      dynamic_write_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      dynamic_write_voice,
  input  synth_pkg::voice_dynamic_state_t           dynamic_write_data,

  output logic [synth_pkg::NUM_VOICES-1:0]          active_bitmap,
  output logic                                      stale_params_write_pulse,
  output logic                                      stale_dynamic_write_pulse
);
  import synth_pkg::*;

  (* ram_style = "block" *) voice_playback_region_t region_mem [0:NUM_VOICES-1];
  (* ram_style = "block" *) voice_event_params_t event_mem [0:NUM_VOICES-1];
  (* ram_style = "block" *) volume_env_params_t env_mem [0:NUM_VOICES-1];
  (* ram_style = "block" *) voice_dynamic_state_t dynamic_mem [0:NUM_VOICES-1];

  logic [NUM_VOICES-1:0] active_q;
  logic [VOICE_GENERATION_WIDTH-1:0] generation_tag [0:NUM_VOICES-1];
  logic read_pending_q;
  logic [VOICE_ID_WIDTH-1:0] read_voice_q;
  block_voice_state_snapshot_t read_rsp_q;
  logic install_fire;
  logic params_write_fire;
  logic dynamic_write_fire;
  logic params_generation_match;
  logic dynamic_generation_match;
  typedef enum logic [1:0] {
    CONTROL_IDLE,
    CONTROL_READ,
    CONTROL_APPLY
  } control_state_t;
  control_state_t control_state_q;
  block_voice_event_t control_event_q;
  voice_event_params_t control_event_params_q;
  volume_env_params_t control_env_params_q;
  voice_dynamic_state_t control_dynamic_q;
  voice_event_params_t control_event_params_next;
  volume_env_params_t control_env_params_next;
  voice_dynamic_state_t control_dynamic_next;
  logic [VOICE_ID_WIDTH-1:0] control_voice;
  logic control_generation_match;

  assign install_ready = !render_busy && (control_state_q == CONTROL_IDLE);
  assign params_write_ready = !render_busy && !install_valid &&
                              (control_state_q == CONTROL_IDLE);
  assign control_event_ready = !render_busy && !install_valid &&
                               !params_write_valid &&
                               (control_state_q == CONTROL_IDLE);
  assign state_read_req_ready = render_busy && !read_pending_q &&
                                !state_read_rsp_valid;
  assign dynamic_write_ready = render_busy;
  assign active_bitmap = active_q;
  assign state_read_rsp = read_rsp_q;

  assign install_fire = install_valid && install_ready;
  assign params_write_fire = params_write_valid && params_write_ready;
  assign dynamic_write_fire = dynamic_write_valid && dynamic_write_ready;
  assign params_generation_match = active_q[params_write_voice] &&
      (generation_tag[params_write_voice] == params_write_generation);
  assign dynamic_generation_match = active_q[dynamic_write_voice] &&
      (generation_tag[dynamic_write_voice] == dynamic_write_data.generation);
  assign control_voice = control_event_q.host_voice_id[VOICE_ID_WIDTH-1:0];
  assign control_generation_match = active_q[control_voice] &&
      (generation_tag[control_voice] == control_event_q.generation);

  always_comb begin
    control_event_params_next = control_event_params_q;
    control_env_params_next = control_env_params_q;
    control_dynamic_next = control_dynamic_q;
    unique case (control_event_q.kind)
      BLOCK_VOICE_STOP: control_dynamic_next.active = 1'b0;
      BLOCK_VOICE_RELEASE: begin
        control_event_params_next.released = 1'b1;
        control_env_params_next.release_step_cb_q12_20 =
            control_event_q.env_params.release_step_cb_q12_20;
        control_dynamic_next.env_state.stage = ENV_RELEASE;
        control_dynamic_next.env_state.elapsed = '0;
        if (control_event_q.env_params.release_step_cb_q12_20 == '0)
          control_dynamic_next.active = 1'b0;
      end
      BLOCK_VOICE_GAIN: begin
        control_event_params_next.gain_l = control_event_q.event_params.gain_l;
        control_event_params_next.gain_r = control_event_q.event_params.gain_r;
      end
      BLOCK_VOICE_PITCH:
        control_event_params_next.phase_inc = control_event_q.event_params.phase_inc;
      BLOCK_VOICE_FILTER: begin
        control_event_params_next.filter_enable =
            control_event_q.event_params.filter_enable;
        control_event_params_next.filter_b0 = control_event_q.event_params.filter_b0;
        control_event_params_next.filter_b1 = control_event_q.event_params.filter_b1;
        control_event_params_next.filter_b2 = control_event_q.event_params.filter_b2;
        control_event_params_next.filter_a1 = control_event_q.event_params.filter_a1;
        control_event_params_next.filter_a2 = control_event_q.event_params.filter_a2;
      end
      BLOCK_VOICE_ENV: control_env_params_next = control_event_q.env_params;
      default: begin end
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      active_q <= '0;
      read_pending_q <= 1'b0;
      read_voice_q <= '0;
      read_rsp_q <= '0;
      state_read_rsp_valid <= 1'b0;
      stale_params_write_pulse <= 1'b0;
      stale_dynamic_write_pulse <= 1'b0;
      control_state_q <= CONTROL_IDLE;
      control_event_q <= '0;
      control_event_params_q <= '0;
      control_env_params_q <= '0;
      control_dynamic_q <= '0;
      control_event_done_pulse <= 1'b0;
      stale_control_event_pulse <= 1'b0;
    end else begin
      stale_params_write_pulse <= 1'b0;
      stale_dynamic_write_pulse <= 1'b0;
      control_event_done_pulse <= 1'b0;
      stale_control_event_pulse <= 1'b0;

      unique case (control_state_q)
        CONTROL_IDLE: begin
          if (control_event_valid && control_event_ready) begin
            control_event_q <= control_event;
            control_state_q <= CONTROL_READ;
          end
        end
        CONTROL_READ: begin
          control_event_params_q <= event_mem[control_voice];
          control_env_params_q <= env_mem[control_voice];
          control_dynamic_q <= dynamic_mem[control_voice];
          control_state_q <= CONTROL_APPLY;
        end
        CONTROL_APPLY: begin
          control_event_done_pulse <= 1'b1;
          if (!control_generation_match) begin
            stale_control_event_pulse <= 1'b1;
          end else begin
            unique case (control_event_q.kind)
              BLOCK_VOICE_STOP: begin
                dynamic_mem[control_voice] <= control_dynamic_next;
                active_q[control_voice] <= 1'b0;
              end
              BLOCK_VOICE_RELEASE: begin
                if (control_event_q.env_params.release_step_cb_q12_20 == '0) begin
                  active_q[control_voice] <= 1'b0;
                end
                event_mem[control_voice] <= control_event_params_next;
                env_mem[control_voice] <= control_env_params_next;
                dynamic_mem[control_voice] <= control_dynamic_next;
              end
              BLOCK_VOICE_GAIN: begin
                event_mem[control_voice] <= control_event_params_next;
              end
              BLOCK_VOICE_PITCH: begin
                event_mem[control_voice] <= control_event_params_next;
              end
              BLOCK_VOICE_FILTER: begin
                event_mem[control_voice] <= control_event_params_next;
              end
              BLOCK_VOICE_ENV: begin
                env_mem[control_voice] <= control_env_params_next;
              end
              default: stale_control_event_pulse <= 1'b1;
            endcase
          end
          control_state_q <= CONTROL_IDLE;
        end
        default: control_state_q <= CONTROL_IDLE;
      endcase

      if (state_read_rsp_valid && state_read_rsp_ready)
        state_read_rsp_valid <= 1'b0;

      if (state_read_req_valid && state_read_req_ready) begin
        read_voice_q <= state_read_req_voice;
        read_pending_q <= 1'b1;
      end

      if (read_pending_q) begin
        read_rsp_q.region <= region_mem[read_voice_q];
        read_rsp_q.event_params <= event_mem[read_voice_q];
        read_rsp_q.env_params <= env_mem[read_voice_q];
        read_rsp_q.dynamic <= dynamic_mem[read_voice_q];
        read_pending_q <= 1'b0;
        state_read_rsp_valid <= 1'b1;
      end

      if (install_fire) begin
        region_mem[install_voice] <= install_state.region;
        event_mem[install_voice] <= install_state.event_params;
        env_mem[install_voice] <= install_state.env_params;
        dynamic_mem[install_voice] <= install_state.dynamic;
        generation_tag[install_voice] <= install_state.dynamic.generation;
        active_q[install_voice] <= install_state.dynamic.active;
      end else if (params_write_fire) begin
        if (params_generation_match) begin
          event_mem[params_write_voice] <= params_write_event;
          env_mem[params_write_voice] <= params_write_env;
        end else begin
          stale_params_write_pulse <= 1'b1;
        end
      end

      if (!install_fire && dynamic_write_fire) begin
        if (dynamic_generation_match) begin
          dynamic_mem[dynamic_write_voice] <= dynamic_write_data;
          active_q[dynamic_write_voice] <= dynamic_write_data.active;
        end else begin
          stale_dynamic_write_pulse <= 1'b1;
        end
      end
    end
  end
endmodule
