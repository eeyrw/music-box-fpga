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
/* verilator lint_off UNUSEDSIGNAL */
  // This store consumes runtime-event fields only; START-only fields are
  // handled by the command plane's install path.
  input  synth_pkg::block_voice_event_t             control_event,
/* verilator lint_on UNUSEDSIGNAL */
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

  output logic                                      stale_params_write_pulse,
  output logic                                      stale_dynamic_write_pulse
);
  import synth_pkg::*;

  localparam int REGION_MEM_WIDTH = $bits(voice_playback_region_t);
  localparam int EVENT_MEM_WIDTH = $bits(voice_event_params_t);
  localparam int ENV_MEM_WIDTH = $bits(volume_env_params_t);
  localparam int DYNAMIC_MEM_WIDTH = $bits(voice_dynamic_state_t);

  // Keep each physical bank as one vector word. Vivado otherwise decomposes a
  // packed-struct array into one shallow RAM per member.
  (* ram_style = "block" *) logic [REGION_MEM_WIDTH-1:0]
      region_mem [0:NUM_VOICES-1];
  (* ram_style = "block" *) logic [EVENT_MEM_WIDTH-1:0]
      event_mem [0:NUM_VOICES-1];
  (* ram_style = "block" *) logic [ENV_MEM_WIDTH-1:0]
      env_mem [0:NUM_VOICES-1];
  (* ram_style = "block" *) logic [DYNAMIC_MEM_WIDTH-1:0]
      dynamic_mem [0:NUM_VOICES-1];
  logic [NUM_VOICES-1:0] voice_valid_q;

  typedef enum logic [2:0] {
    CONTROL_IDLE,
    CONTROL_READ,
    CONTROL_CAPTURE,
    CONTROL_APPLY
  } control_state_t;
  control_state_t control_state_q;
  typedef enum logic [1:0] {
    CHECK_IDLE,
    CHECK_CAPTURE,
    CHECK_APPLY
  } check_state_t;
  check_state_t check_state_q;
  logic check_is_dynamic_q;
  logic [VOICE_ID_WIDTH-1:0] check_voice_q;
  logic [VOICE_GENERATION_WIDTH-1:0] check_generation_q;
  voice_event_params_t check_event_q;
  volume_env_params_t check_env_q;
  voice_dynamic_state_t check_dynamic_q;
  logic check_current_active_q;
  logic [VOICE_GENERATION_WIDTH-1:0] check_current_generation_q;
  logic check_generation_match;
  block_voice_event_kind_t control_event_kind_q;
  logic [VOICE_ID_WIDTH-1:0] control_event_voice_q;
  logic [VOICE_GENERATION_WIDTH-1:0] control_event_generation_q;
/* verilator lint_off UNUSEDSIGNAL */
  // The released bit is store-owned; the remaining event fields are updates.
  voice_event_params_t control_event_update_params_q;
/* verilator lint_on UNUSEDSIGNAL */
  volume_env_params_t control_event_update_env_q;
  voice_event_params_t control_event_params_q;
  volume_env_params_t control_env_params_q;
  voice_dynamic_state_t control_dynamic_q;
  voice_event_params_t control_event_params_next;
  volume_env_params_t control_env_params_next;
  voice_dynamic_state_t control_dynamic_next;
  logic [VOICE_ID_WIDTH-1:0] control_voice;
  logic control_generation_match;

  logic snapshot_capture_q;
  logic [VOICE_ID_WIDTH-1:0] snapshot_voice_q;
  block_voice_state_snapshot_t read_rsp_q;
  voice_playback_region_t region_read_data_q;
  voice_event_params_t event_read_data_q;
  volume_env_params_t env_read_data_q;
  voice_dynamic_state_t dynamic_read_data_q;
  logic memory_read_enable;
  logic [VOICE_ID_WIDTH-1:0] memory_read_voice;

  logic install_fire;
  logic params_write_fire;
  logic dynamic_write_fire;
  logic state_read_req_fire;
  logic params_generation_match;
  logic dynamic_generation_match;

  logic region_write_enable;
  logic [VOICE_ID_WIDTH-1:0] region_write_voice;
  voice_playback_region_t region_write_data;
  logic event_write_enable;
  logic [VOICE_ID_WIDTH-1:0] event_write_voice;
  voice_event_params_t event_write_data;
  logic env_write_enable;
  logic [VOICE_ID_WIDTH-1:0] env_write_voice;
  volume_env_params_t env_write_data;
  logic dynamic_mem_write_enable;
  logic [VOICE_ID_WIDTH-1:0] dynamic_mem_write_voice;
  voice_dynamic_state_t dynamic_mem_write_data;

  assign install_ready = !render_busy && (control_state_q == CONTROL_IDLE) &&
                         (check_state_q == CHECK_IDLE);
  assign params_write_ready = !render_busy && !install_valid &&
                              (control_state_q == CONTROL_IDLE) &&
                              (check_state_q == CHECK_IDLE);
  assign control_event_ready = !render_busy && !install_valid &&
                               !params_write_valid &&
                               (control_state_q == CONTROL_IDLE) &&
                               (check_state_q == CHECK_IDLE);
  assign state_read_req_ready = render_busy && !snapshot_capture_q &&
                                !state_read_rsp_valid &&
                                (check_state_q == CHECK_IDLE) &&
                                !dynamic_write_valid;
  assign dynamic_write_ready = render_busy &&
                               (check_state_q == CHECK_IDLE);
  assign state_read_rsp = read_rsp_q;

  assign install_fire = install_valid && install_ready;
  assign params_write_fire = params_write_valid && params_write_ready;
  assign dynamic_write_fire = dynamic_write_valid && dynamic_write_ready;
  assign state_read_req_fire = state_read_req_valid && state_read_req_ready;
  assign params_generation_match = check_generation_match;
  assign dynamic_generation_match = check_generation_match;
  assign control_voice = control_event_voice_q;
  assign control_generation_match = voice_valid_q[control_voice] &&
      control_dynamic_q.active &&
      (control_dynamic_q.generation == control_event_generation_q);
  assign check_generation_match = voice_valid_q[check_voice_q] &&
      check_current_active_q &&
      (check_current_generation_q == check_generation_q);

  always_comb begin
    control_event_params_next = control_event_params_q;
    control_env_params_next = control_env_params_q;
    control_dynamic_next = control_dynamic_q;
    unique case (control_event_kind_q)
      BLOCK_VOICE_STOP: control_dynamic_next.active = 1'b0;
      BLOCK_VOICE_RELEASE: begin
        control_event_params_next.released = 1'b1;
        control_env_params_next.release_step_cb_q12_20 =
            control_event_update_env_q.release_step_cb_q12_20;
        control_dynamic_next.env_state.stage = ENV_RELEASE;
        control_dynamic_next.env_state.elapsed = '0;
        if (control_event_update_env_q.release_step_cb_q12_20 == '0)
          control_dynamic_next.active = 1'b0;
      end
      BLOCK_VOICE_GAIN: begin
        control_event_params_next.gain_l = control_event_update_params_q.gain_l;
        control_event_params_next.gain_r = control_event_update_params_q.gain_r;
      end
      BLOCK_VOICE_PITCH:
        control_event_params_next.phase_inc = control_event_update_params_q.phase_inc;
      BLOCK_VOICE_FILTER: begin
        control_event_params_next.filter_enable =
            control_event_update_params_q.filter_enable;
        control_event_params_next.filter_b0 = control_event_update_params_q.filter_b0;
        control_event_params_next.filter_b1 = control_event_update_params_q.filter_b1;
        control_event_params_next.filter_b2 = control_event_update_params_q.filter_b2;
        control_event_params_next.filter_a1 = control_event_update_params_q.filter_a1;
        control_event_params_next.filter_a2 = control_event_update_params_q.filter_a2;
      end
      BLOCK_VOICE_ENV: control_env_params_next = control_event_update_env_q;
      default: begin end
    endcase

    memory_read_enable = dynamic_write_fire || params_write_fire ||
                         state_read_req_fire ||
                         (control_state_q == CONTROL_READ);
    if (dynamic_write_fire)
      memory_read_voice = dynamic_write_voice;
    else if (params_write_fire)
      memory_read_voice = params_write_voice;
    else if (state_read_req_fire)
      memory_read_voice = state_read_req_voice;
    else
      memory_read_voice = control_voice;

    region_write_enable = install_fire;
    region_write_voice = install_voice;
    region_write_data = install_state.region;

    event_write_enable = 1'b0;
    event_write_voice = '0;
    event_write_data = '0;
    env_write_enable = 1'b0;
    env_write_voice = '0;
    env_write_data = '0;
    dynamic_mem_write_enable = 1'b0;
    dynamic_mem_write_voice = '0;
    dynamic_mem_write_data = '0;

    if (install_fire) begin
      event_write_enable = 1'b1;
      event_write_voice = install_voice;
      event_write_data = install_state.event_params;
      env_write_enable = 1'b1;
      env_write_voice = install_voice;
      env_write_data = install_state.env_params;
      dynamic_mem_write_enable = 1'b1;
      dynamic_mem_write_voice = install_voice;
      dynamic_mem_write_data = install_state.dynamic;
    end else if ((check_state_q == CHECK_APPLY) &&
                 !check_is_dynamic_q && params_generation_match) begin
      event_write_enable = 1'b1;
      event_write_voice = check_voice_q;
      event_write_data = check_event_q;
      env_write_enable = 1'b1;
      env_write_voice = check_voice_q;
      env_write_data = check_env_q;
    end else if ((control_state_q == CONTROL_APPLY) &&
                 control_generation_match) begin
      unique case (control_event_kind_q)
        BLOCK_VOICE_STOP: begin
          dynamic_mem_write_enable = 1'b1;
          dynamic_mem_write_voice = control_voice;
          dynamic_mem_write_data = control_dynamic_next;
        end
        BLOCK_VOICE_RELEASE: begin
          event_write_enable = 1'b1;
          event_write_voice = control_voice;
          event_write_data = control_event_params_next;
          env_write_enable = 1'b1;
          env_write_voice = control_voice;
          env_write_data = control_env_params_next;
          dynamic_mem_write_enable = 1'b1;
          dynamic_mem_write_voice = control_voice;
          dynamic_mem_write_data = control_dynamic_next;
        end
        BLOCK_VOICE_GAIN, BLOCK_VOICE_PITCH, BLOCK_VOICE_FILTER: begin
          event_write_enable = 1'b1;
          event_write_voice = control_voice;
          event_write_data = control_event_params_next;
        end
        BLOCK_VOICE_ENV: begin
          env_write_enable = 1'b1;
          env_write_voice = control_voice;
          env_write_data = control_env_params_next;
        end
        default: begin end
      endcase
    end else if ((check_state_q == CHECK_APPLY) && check_is_dynamic_q &&
                 dynamic_generation_match) begin
      dynamic_mem_write_enable = 1'b1;
      dynamic_mem_write_voice = check_voice_q;
      dynamic_mem_write_data = check_dynamic_q;
    end
  end

  // Each state bank has one synchronous read and one canonical write port.
  always_ff @(posedge clk) begin
    if (memory_read_enable)
      region_read_data_q <= voice_playback_region_t'(
          region_mem[memory_read_voice]);
    if (region_write_enable)
      region_mem[region_write_voice] <= REGION_MEM_WIDTH'(region_write_data);
  end

  always_ff @(posedge clk) begin
    if (memory_read_enable)
      event_read_data_q <= voice_event_params_t'(event_mem[memory_read_voice]);
    if (event_write_enable)
      event_mem[event_write_voice] <= EVENT_MEM_WIDTH'(event_write_data);
  end

  always_ff @(posedge clk) begin
    if (memory_read_enable)
      env_read_data_q <= volume_env_params_t'(env_mem[memory_read_voice]);
    if (env_write_enable)
      env_mem[env_write_voice] <= ENV_MEM_WIDTH'(env_write_data);
  end

  always_ff @(posedge clk) begin
    if (memory_read_enable)
      dynamic_read_data_q <= voice_dynamic_state_t'(
          dynamic_mem[memory_read_voice]);
    if (dynamic_mem_write_enable)
      dynamic_mem[dynamic_mem_write_voice] <=
          DYNAMIC_MEM_WIDTH'(dynamic_mem_write_data);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      snapshot_capture_q <= 1'b0;
      snapshot_voice_q <= '0;
      voice_valid_q <= '0;
      state_read_rsp_valid <= 1'b0;
      control_state_q <= CONTROL_IDLE;
      check_state_q <= CHECK_IDLE;
      control_event_done_pulse <= 1'b0;
      stale_control_event_pulse <= 1'b0;
      stale_params_write_pulse <= 1'b0;
      stale_dynamic_write_pulse <= 1'b0;
    end else begin
      control_event_done_pulse <= 1'b0;
      stale_control_event_pulse <= 1'b0;
      stale_params_write_pulse <= 1'b0;
      stale_dynamic_write_pulse <= 1'b0;

      if (install_fire)
        voice_valid_q[install_voice] <= 1'b1;
      if ((control_state_q == CONTROL_APPLY) && control_generation_match &&
          ((control_event_kind_q == BLOCK_VOICE_STOP) ||
           ((control_event_kind_q == BLOCK_VOICE_RELEASE) &&
            (control_event_update_env_q.release_step_cb_q12_20 == '0))))
        voice_valid_q[control_voice] <= 1'b0;
      if ((check_state_q == CHECK_APPLY) && check_is_dynamic_q &&
          dynamic_generation_match && !check_dynamic_q.active)
        voice_valid_q[check_voice_q] <= 1'b0;

      unique case (control_state_q)
        CONTROL_IDLE: begin
          if (control_event_valid && control_event_ready) begin
            control_event_kind_q <= control_event.kind;
            control_event_voice_q <=
                control_event.host_voice_id[VOICE_ID_WIDTH-1:0];
            control_event_generation_q <= control_event.generation;
            control_event_update_params_q <= control_event.event_params;
            control_event_update_env_q <= control_event.env_params;
            control_state_q <= CONTROL_READ;
          end
        end
        CONTROL_READ: control_state_q <= CONTROL_CAPTURE;
        CONTROL_CAPTURE: begin
          control_event_params_q <= event_read_data_q;
          control_env_params_q <= env_read_data_q;
          control_dynamic_q <= dynamic_read_data_q;
          control_state_q <= CONTROL_APPLY;
        end
        CONTROL_APPLY: begin
          control_event_done_pulse <= 1'b1;
          if (!control_generation_match) begin
            stale_control_event_pulse <= 1'b1;
          end else begin
            unique case (control_event_kind_q)
              BLOCK_VOICE_STOP, BLOCK_VOICE_RELEASE: begin end
              BLOCK_VOICE_GAIN, BLOCK_VOICE_PITCH, BLOCK_VOICE_FILTER,
              BLOCK_VOICE_ENV: begin end
              default: stale_control_event_pulse <= 1'b1;
            endcase
          end
          control_state_q <= CONTROL_IDLE;
        end
        default: control_state_q <= CONTROL_IDLE;
      endcase

      if (state_read_rsp_valid && state_read_rsp_ready)
        state_read_rsp_valid <= 1'b0;

      unique case (check_state_q)
        CHECK_IDLE: begin
          if (dynamic_write_fire) begin
            check_is_dynamic_q <= 1'b1;
            check_voice_q <= dynamic_write_voice;
            check_generation_q <= dynamic_write_data.generation;
            check_dynamic_q <= dynamic_write_data;
            check_state_q <= CHECK_CAPTURE;
          end else if (params_write_fire) begin
            check_is_dynamic_q <= 1'b0;
            check_voice_q <= params_write_voice;
            check_generation_q <= params_write_generation;
            check_event_q <= params_write_event;
            check_env_q <= params_write_env;
            check_state_q <= CHECK_CAPTURE;
          end
        end
        CHECK_CAPTURE: begin
          check_current_active_q <= dynamic_read_data_q.active;
          check_current_generation_q <= dynamic_read_data_q.generation;
          check_state_q <= CHECK_APPLY;
        end
        CHECK_APPLY: begin
          if (!check_generation_match) begin
            if (check_is_dynamic_q)
              stale_dynamic_write_pulse <= 1'b1;
            else
              stale_params_write_pulse <= 1'b1;
          end
          check_state_q <= CHECK_IDLE;
        end
        default: check_state_q <= CHECK_IDLE;
      endcase

      if (state_read_req_fire) begin
        snapshot_capture_q <= 1'b1;
        snapshot_voice_q <= state_read_req_voice;
      end
      if (snapshot_capture_q) begin
        read_rsp_q.region <= region_read_data_q;
        read_rsp_q.event_params <= event_read_data_q;
        read_rsp_q.env_params <= env_read_data_q;
        read_rsp_q.dynamic <= dynamic_read_data_q;
        read_rsp_q.dynamic.active <=
            dynamic_read_data_q.active && voice_valid_q[snapshot_voice_q];
        snapshot_capture_q <= 1'b0;
        state_read_rsp_valid <= 1'b1;
      end

    end
  end
endmodule
