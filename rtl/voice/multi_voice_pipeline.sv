module multi_voice_pipeline (
  input  logic                       clk,
  input  logic                       rst,
  output logic [$clog2(synth_pkg::NUM_VOICES)-1:0] voice_read_index,
  input  synth_pkg::voice_config_t   voice_config,
  input  synth_pkg::voice_runtime_t  voice_runtime,
  input  logic [synth_pkg::NUM_VOICES-1:0] config_valid,
  input  logic [synth_pkg::NUM_VOICES-1:0] config_commit,
  input  logic                       sample_tick,
  output logic                       busy,
  output logic                       sample_valid,
  output synth_pkg::pcm_t            sample_l,
  output synth_pkg::pcm_t            sample_r,
  output logic                       mem_req_valid,
  output logic [31:0]                mem_req_addr,
  input  logic                       mem_req_ready,
  input  logic                       mem_rsp_valid,
  input  synth_pkg::pcm_t            mem_rsp_data
);
  import synth_pkg::*;

  typedef enum logic [3:0] {
    IDLE, SCAN_VOICE, READ_VOICE, WAIT_VOICE, START_VOICE, PROCESS_VOICE, DSP_START, DRAIN, FINISH
  } state_t;

  localparam int VOICE_INDEX_WIDTH = synth_pkg::VOICE_ID_WIDTH;
  localparam logic [VOICE_INDEX_WIDTH-1:0] LAST_VOICE = VOICE_INDEX_WIDTH'(NUM_VOICES - 1);

  state_t state;
  logic [VOICE_INDEX_WIDTH-1:0] voice_index;
  logic [VOICE_INDEX_WIDTH-1:0] render_index;
  logic [NUM_VOICES-1:0] frame_commit;
  (* ram_style = "distributed" *) logic [PHASE_WIDTH-1:0] phase [NUM_VOICES];
  (* ram_style = "distributed" *) logic [PHASE_WIDTH-1:0] phase_r [NUM_VOICES];
  logic [NUM_VOICES-1:0] phase_valid;
  logic [PHASE_WIDTH-1:0] phase_read;
  logic [PHASE_WIDTH-1:0] phase_r_read;
  logic phase_write_en;
  logic [PHASE_WIDTH-1:0] phase_write_data;
  logic [PHASE_WIDTH-1:0] phase_r_write_data;
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_l [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_l [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_r [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_r [NUM_VOICES];
  logic [NUM_VOICES-1:0] filter_state_valid;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_l_read;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_l_read;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z1_r_read;
  logic signed [FILTER_STATE_WIDTH-1:0] filter_z2_r_read;
  voice_dsp_context_t dsp_context;
  voice_dsp_context_t endpoint_issue_context;
  voice_dsp_result_t dsp_result;
  logic endpoint_issue_valid;
  logic endpoint_issue_ready;
  logic endpoint_context_valid;
  logic endpoint_empty;
  logic dsp_issue_valid;
  logic dsp_valid;
  logic [VOICE_INDEX_WIDTH:0] outstanding_count;
  logic [VOICE_INDEX_WIDTH:0] outstanding_next;
  logic signed [31:0] accum_l;
  logic signed [31:0] accum_r;
  logic signed [31:0] next_accum_l;
  logic signed [31:0] next_accum_r;
  logic scan_at_last_voice;
  logic voice_done;
  logic [PHASE_FRAME_WIDTH-1:0] phase_frame_0;
  logic [PHASE_FRAME_WIDTH-1:0] phase_frame_1;
  logic [PHASE_FRAME_WIDTH-1:0] phase_frame_r0;
  logic [PHASE_FRAME_WIDTH-1:0] phase_frame_r1;
  logic [PHASE_FRAC_WIDTH-1:0] phase_fraction;
  logic cfg_enable;
  logic cfg_stereo;
  logic [ADDR_WIDTH-1:0] cfg_base_addr;
  logic [ADDR_WIDTH-1:0] cfg_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_length;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_length_r;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_start_r;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_end;
  logic [PHASE_FRAME_WIDTH-1:0] cfg_loop_end_r;
  logic [PHASE_WIDTH-1:0] cfg_phase_inc;
  logic signed [15:0] cfg_gain_l;
  logic signed [15:0] cfg_gain_r;
  logic signed [15:0] cfg_envelope_level;
  logic [1:0] cfg_loop_mode;
  logic cfg_released;
  logic cfg_filter_enable;
  logic signed [31:0] cfg_filter_b0;
  logic signed [31:0] cfg_filter_b1;
  logic signed [31:0] cfg_filter_b2;
  logic signed [31:0] cfg_filter_a1;
  logic signed [31:0] cfg_filter_a2;
  logic current_enable;
  logic current_config_valid;
  logic current_commit;
  logic current_stereo;
  logic [ADDR_WIDTH-1:0] current_base_addr;
  logic [ADDR_WIDTH-1:0] current_base_addr_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_length;
  logic [PHASE_FRAME_WIDTH-1:0] current_length_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_start;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_start_r;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_end;
  logic [PHASE_FRAME_WIDTH-1:0] current_loop_end_r;
  logic [PHASE_WIDTH-1:0] current_phase_inc;
  logic signed [15:0] current_gain_l;
  logic signed [15:0] current_gain_r;
  logic signed [15:0] current_envelope_level;
  logic [1:0] current_loop_mode;
  logic current_released;
  logic current_filter_enable;
  logic signed [31:0] current_filter_b0;
  logic signed [31:0] current_filter_b1;
  logic signed [31:0] current_filter_b2;
  logic signed [31:0] current_filter_a1;
  logic signed [31:0] current_filter_a2;
  logic [PHASE_WIDTH-1:0] current_phase;
  logic [PHASE_WIDTH-1:0] current_phase_r;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z1_l;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z2_l;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z1_r;
  logic signed [FILTER_STATE_WIDTH-1:0] current_filter_z2_r;
  logic prefetch_active;
  logic prefetch_done;
  logic prefetch_ready;
  logic [1:0] prefetch_wait;
  logic [VOICE_INDEX_WIDTH-1:0] prefetch_scan_index;
  logic [VOICE_INDEX_WIDTH-1:0] prefetch_index;

  function automatic pcm_t saturate_pcm(input logic signed [63:0] value);
    if (value > 64'sd32767)
      saturate_pcm = 16'sh7fff;
    else if (value < -64'sd32768)
      saturate_pcm = 16'sh8000;
    else
      saturate_pcm = value[15:0];
  endfunction

  assign voice_read_index = render_index;
  assign endpoint_issue_valid = (state == PROCESS_VOICE) && current_enable &&
                                current_config_valid && !voice_done;
  assign phase_write_en = endpoint_issue_valid && endpoint_issue_ready;
  assign dsp_issue_valid = endpoint_context_valid;
  assign cfg_enable = voice_config.enable;
  assign cfg_stereo = voice_config.stereo;
  assign cfg_base_addr = voice_config.base_addr;
  assign cfg_base_addr_r = voice_config.base_addr_r;
  assign cfg_length = voice_config.length;
  assign cfg_length_r = voice_config.length_r;
  assign cfg_loop_start = voice_config.loop_start;
  assign cfg_loop_start_r = voice_config.loop_start_r;
  assign cfg_loop_end = voice_config.loop_end;
  assign cfg_loop_end_r = voice_config.loop_end_r;
  assign cfg_phase_inc = voice_runtime.phase_inc;
  assign cfg_gain_l = voice_runtime.gain_l;
  assign cfg_gain_r = voice_runtime.gain_r;
  assign cfg_envelope_level = voice_runtime.envelope_level;
  assign cfg_loop_mode = voice_config.loop_mode;
  assign cfg_released = voice_runtime.released;
  assign cfg_filter_enable = voice_runtime.filter_enable;
  assign cfg_filter_b0 = voice_runtime.filter_b0;
  assign cfg_filter_b1 = voice_runtime.filter_b1;
  assign cfg_filter_b2 = voice_runtime.filter_b2;
  assign cfg_filter_a1 = voice_runtime.filter_a1;
  assign cfg_filter_a2 = voice_runtime.filter_a2;

  voice_phase_frame phase_frame (
    .stereo(current_stereo),
    .loop_mode(current_loop_mode),
    .released(current_released),
    .phase(current_phase),
    .phase_r(current_phase_r),
    .phase_inc(current_phase_inc),
    .length(current_length),
    .length_r(current_length_r),
    .loop_start(current_loop_start),
    .loop_start_r(current_loop_start_r),
    .loop_end(current_loop_end),
    .loop_end_r(current_loop_end_r),
    .done(voice_done),
    .frame_0(phase_frame_0),
    .frame_1(phase_frame_1),
    .frame_r0(phase_frame_r0),
    .frame_r1(phase_frame_r1),
    .fraction(phase_fraction),
    .next_phase(phase_write_data),
    .next_phase_r(phase_r_write_data)
  );

  always_comb begin
    next_accum_l = accum_l + $signed({{16{dsp_result.contribution_l[15]}}, dsp_result.contribution_l});
    next_accum_r = accum_r + $signed({{16{dsp_result.contribution_r[15]}}, dsp_result.contribution_r});
    outstanding_next = outstanding_count + {{VOICE_INDEX_WIDTH{1'b0}}, dsp_issue_valid} -
                        {{VOICE_INDEX_WIDTH{1'b0}}, dsp_valid};
    scan_at_last_voice = (voice_index == LAST_VOICE);

    endpoint_issue_context = '0;
    endpoint_issue_context.voice_index = voice_index;
    endpoint_issue_context.filter_enable = current_filter_enable;
    endpoint_issue_context.gain_l = current_gain_l;
    endpoint_issue_context.gain_r = current_gain_r;
    endpoint_issue_context.envelope_level = current_envelope_level;
    endpoint_issue_context.filter_b0 = current_filter_b0;
    endpoint_issue_context.filter_b1 = current_filter_b1;
    endpoint_issue_context.filter_b2 = current_filter_b2;
    endpoint_issue_context.filter_a1 = current_filter_a1;
    endpoint_issue_context.filter_a2 = current_filter_a2;
    endpoint_issue_context.filter_z1_l = current_filter_z1_l;
    endpoint_issue_context.filter_z2_l = current_filter_z2_l;
    endpoint_issue_context.filter_z1_r = current_filter_z1_r;
    endpoint_issue_context.filter_z2_r = current_filter_z2_r;
    endpoint_issue_context.fraction = phase_fraction;
  end

  voice_endpoint_fetch endpoint_fetch (
    .clk,
    .rst,
    .issue_valid(endpoint_issue_valid),
    .issue_ready(endpoint_issue_ready),
    .issue_stereo(current_stereo),
    .issue_base_addr(current_base_addr),
    .issue_base_addr_r(current_base_addr_r),
    .issue_frame_0(phase_frame_0),
    .issue_frame_1(phase_frame_1),
    .issue_frame_r0(phase_frame_r0),
    .issue_frame_r1(phase_frame_r1),
    .issue_context(endpoint_issue_context),
    .context_valid(endpoint_context_valid),
    .context_o(dsp_context),
    .empty(endpoint_empty),
    .mem_req_valid,
    .mem_req_addr,
    .mem_req_ready,
    .mem_rsp_valid,
    .mem_rsp_data
  );

  voice_dsp_pipeline dsp_pipeline (
    .clk,
    .rst,
    .valid_i(dsp_issue_valid),
    .context_i(dsp_context),
    .valid_o(dsp_valid),
    .result_o(dsp_result)
  );

  always_ff @(posedge clk) begin
    phase_read <= phase[render_index];
    phase_r_read <= phase_r[render_index];
    if (phase_write_en)
      phase[voice_index] <= phase_write_data;
    if (phase_write_en && current_stereo)
      phase_r[voice_index] <= phase_r_write_data;

    filter_z1_l_read <= filter_z1_l[render_index];
    filter_z2_l_read <= filter_z2_l[render_index];
    filter_z1_r_read <= filter_z1_r[render_index];
    filter_z2_r_read <= filter_z2_r[render_index];
    if (dsp_valid && dsp_result.filter_enable) begin
      filter_z1_l[dsp_result.voice_index] <= dsp_result.next_z1_l;
      filter_z2_l[dsp_result.voice_index] <= dsp_result.next_z2_l;
      filter_z1_r[dsp_result.voice_index] <= dsp_result.next_z1_r;
      filter_z2_r[dsp_result.voice_index] <= dsp_result.next_z2_r;
    end
  end

  assign busy = (state != IDLE);

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE;
      voice_index <= '0;
      render_index <= '0;
      current_stereo <= 1'b0;
      current_base_addr <= '0;
      current_base_addr_r <= '0;
      current_enable <= 1'b0;
      current_config_valid <= 1'b0;
      current_commit <= 1'b0;
      current_length <= '0;
      current_length_r <= '0;
      current_loop_start <= '0;
      current_loop_start_r <= '0;
      current_loop_end <= '0;
      current_loop_end_r <= '0;
      current_phase <= '0;
      current_phase_r <= '0;
      current_phase_inc <= '0;
      current_gain_l <= '0;
      current_gain_r <= '0;
      current_envelope_level <= '0;
      current_loop_mode <= LOOP_MODE_NONE;
      current_released <= 1'b0;
      current_filter_enable <= 1'b0;
      current_filter_b0 <= '0;
      current_filter_b1 <= '0;
      current_filter_b2 <= '0;
      current_filter_a1 <= '0;
      current_filter_a2 <= '0;
      current_filter_z1_l <= '0;
      current_filter_z2_l <= '0;
      current_filter_z1_r <= '0;
      current_filter_z2_r <= '0;
      prefetch_active <= 1'b0;
      prefetch_done <= 1'b0;
      prefetch_ready <= 1'b0;
      prefetch_wait <= '0;
      prefetch_scan_index <= '0;
      prefetch_index <= '0;
      accum_l <= 32'sd0;
      accum_r <= 32'sd0;
      outstanding_count <= '0;
      sample_valid <= 1'b0;
      sample_l <= '0;
      sample_r <= '0;
      frame_commit <= '0;
      phase_valid <= '0;
      filter_state_valid <= '0;
    end else begin
      sample_valid <= 1'b0;

      if (dsp_valid) begin
        if (dsp_result.filter_enable)
          filter_state_valid[dsp_result.voice_index] <= 1'b1;
        accum_l <= next_accum_l;
        accum_r <= next_accum_r;
      end
      outstanding_count <= outstanding_next;

      if (prefetch_active) begin
        if (prefetch_wait != 2'd0) begin
          prefetch_wait <= prefetch_wait - 2'd1;
          if (prefetch_wait == 2'd1) begin
            prefetch_ready <= 1'b1;
            prefetch_done <= 1'b1;
            prefetch_active <= 1'b0;
          end
        end else if (config_valid[prefetch_scan_index]) begin
          prefetch_index <= prefetch_scan_index;
          render_index <= prefetch_scan_index;
          prefetch_wait <= 2'd2;
        end else if (prefetch_scan_index == LAST_VOICE) begin
          prefetch_done <= 1'b1;
          prefetch_active <= 1'b0;
        end else begin
          prefetch_scan_index <= prefetch_scan_index + 1'b1;
        end
      end

      unique case (state)
        IDLE: begin
          if (sample_tick) begin
            accum_l <= 32'sd0;
            accum_r <= 32'sd0;
            outstanding_count <= '0;
            frame_commit <= config_commit;
            voice_index <= '0;
            render_index <= '0;
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            state <= SCAN_VOICE;
          end
        end
        SCAN_VOICE: begin
          if (config_valid[voice_index]) begin
            render_index <= voice_index;
            state <= READ_VOICE;
          end else if (scan_at_last_voice) begin
            state <= DRAIN;
          end else begin
            voice_index <= voice_index + 1'b1;
          end
        end
        READ_VOICE: begin
          state <= WAIT_VOICE;
        end
        WAIT_VOICE: begin
          state <= START_VOICE;
        end
        START_VOICE: begin
          current_enable <= cfg_enable;
          current_config_valid <= config_valid[voice_index];
          current_commit <= frame_commit[voice_index];
          current_stereo <= cfg_stereo;
          current_base_addr <= cfg_base_addr;
          current_base_addr_r <= cfg_base_addr_r;
          current_length <= cfg_length;
          current_length_r <= cfg_length_r;
          current_loop_start <= cfg_loop_start;
          current_loop_start_r <= cfg_loop_start_r;
          current_loop_end <= cfg_loop_end;
          current_loop_end_r <= cfg_loop_end_r;
          current_phase <= frame_commit[voice_index] ? voice_config.phase_init :
                           (phase_valid[voice_index] ? phase_read : '0);
          current_phase_r <= frame_commit[voice_index] ? voice_config.phase_init :
                             (phase_valid[voice_index] ? phase_r_read : '0);
          current_phase_inc <= cfg_phase_inc;
          current_gain_l <= cfg_gain_l;
          current_gain_r <= cfg_gain_r;
          current_envelope_level <= cfg_envelope_level;
          current_loop_mode <= cfg_loop_mode;
          current_released <= cfg_released;
          current_filter_enable <= cfg_filter_enable;
          current_filter_b0 <= cfg_filter_b0;
          current_filter_b1 <= cfg_filter_b1;
          current_filter_b2 <= cfg_filter_b2;
          current_filter_a1 <= cfg_filter_a1;
          current_filter_a2 <= cfg_filter_a2;
          current_filter_z1_l <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z1_l_read;
          current_filter_z2_l <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z2_l_read;
          current_filter_z1_r <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z1_r_read;
          current_filter_z2_r <= (frame_commit[voice_index] || !filter_state_valid[voice_index]) ? '0 : filter_z2_r_read;
          prefetch_ready <= 1'b0;
          prefetch_done <= (voice_index == LAST_VOICE);
          prefetch_active <= (voice_index != LAST_VOICE);
          prefetch_scan_index <= voice_index + 1'b1;
          prefetch_wait <= '0;
          state <= PROCESS_VOICE;
        end
        PROCESS_VOICE: begin
          if (!current_enable || !current_config_valid || voice_done) begin
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            if (scan_at_last_voice) begin
              state <= DRAIN;
            end else begin
              voice_index <= voice_index + 1'b1;
              state <= SCAN_VOICE;
            end
          end else if (endpoint_issue_ready) begin
            if (current_commit)
              filter_state_valid[voice_index] <= 1'b0;
            phase_valid[voice_index] <= 1'b1;
            state <= DSP_START;
          end
        end
        DSP_START: begin
          if (scan_at_last_voice)
            state <= DRAIN;
          else if (prefetch_ready) begin
            voice_index <= prefetch_index;
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            state <= START_VOICE;
          end else if (prefetch_done) begin
            state <= DRAIN;
          end
          else begin
            voice_index <= voice_index + 1'b1;
            prefetch_active <= 1'b0;
            prefetch_done <= 1'b0;
            prefetch_ready <= 1'b0;
            prefetch_wait <= '0;
            state <= SCAN_VOICE;
          end
        end
        DRAIN: begin
          if (outstanding_next == '0 && endpoint_empty)
            state <= FINISH;
        end
        FINISH: begin
          sample_l <= saturate_pcm({{32{accum_l[31]}}, accum_l});
          sample_r <= saturate_pcm({{32{accum_r[31]}}, accum_r});
          sample_valid <= 1'b1;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
