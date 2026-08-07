module wavetable_common_status_regs #(
  parameter int OUTPUT_FIFO_DEPTH = 8
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     core_reset,
  input  synth_pkg::reg_bus_req_t  bus_req,
  output synth_pkg::reg_bus_rsp_t  bus_rsp,
  input  logic                     core_sample_valid,
  input  logic                     core_busy,
  input  logic                     render_inflight,
  input  logic                     render_deadline_miss_pulse,
  input  logic                     render_latency_valid,
  input  logic [15:0]              render_latency_cycles,
  input  logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  input  logic                     ext_rsp_valid,
  input  logic                     i2s_sample_ready,
  input  logic                     fifo_sample_valid,
  input  logic                     underrun_pulse,
  input  logic                     sample_drop_pulse,
  input  logic                     mem_response_trace_pulse,
  input  logic [15:0]              mem_response_trace_latency,
  input  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  input  logic                     playback_started,
  input  logic [31:0]              audio_lead,
  input  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] minimum_fifo_level,
  input  logic [31:0]              command_error_count,
  input  logic [31:0]              stale_generation_count,
  input  logic [31:0]              session_epoch,
  input  synth_pkg::audio_diagnostics_t audio_diagnostics,
  input  synth_pkg::sample_window_diagnostics_t sample_window_diagnostics,
  output logic                     diagnostics_clear_pulse
);
  import synth_register_pkg::*;

  localparam logic [15:0] ADDR_SYSTEM_STATUS = REG_SYSTEM_STATUS;
  localparam logic [15:0] ADDR_COMMON_EVENT_FLAGS = REG_COMMON_EVENT_FLAGS;
  localparam logic [15:0] ADDR_PIPELINE_LATENCY_STATUS =
      REG_PIPELINE_LATENCY_STATUS;
  localparam logic [15:0] ADDR_UNDERRUN_COUNT = REG_UNDERRUN_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_DROP_COUNT = REG_SAMPLE_DROP_COUNT;
  localparam logic [15:0] ADDR_RENDER_DEADLINE_MISS_COUNT = REG_RENDER_DEADLINE_MISS_COUNT;
  localparam logic [15:0] ADDR_MEM_RESPONSE_COUNT = REG_MEM_RESPONSE_COUNT;
  localparam logic [15:0] ADDR_DIAGNOSTIC_CONTROL = REG_DIAGNOSTIC_CONTROL;
  localparam logic [15:0] ADDR_PIPELINE_LATENCY_MAX = REG_PIPELINE_LATENCY_MAX;
  localparam logic [15:0] ADDR_AUDIO_FIFO_DIAGNOSTICS =
      REG_AUDIO_FIFO_DIAGNOSTICS;
  localparam logic [15:0] ADDR_AUDIO_LEAD = REG_AUDIO_LEAD;
  localparam logic [15:0] ADDR_COMMAND_ERROR_COUNT = REG_COMMAND_ERROR_COUNT;
  localparam logic [15:0] ADDR_STALE_GENERATION_COUNT =
      REG_STALE_GENERATION_COUNT;
  localparam logic [15:0] ADDR_RENDER_SESSION_EPOCH =
      REG_RENDER_SESSION_EPOCH;
  localparam logic [15:0] ADDR_COMPRESSOR_STATUS = REG_COMPRESSOR_STATUS;
  localparam logic [15:0] ADDR_COMPRESSOR_GAIN_REDUCTION = REG_COMPRESSOR_GAIN_REDUCTION;
  localparam logic [15:0] ADDR_COMPRESSOR_TARGET_GAIN_REDUCTION =
      REG_COMPRESSOR_TARGET_GAIN_REDUCTION;
  localparam logic [15:0] ADDR_COMPRESSOR_DETECTOR_PEAK = REG_COMPRESSOR_DETECTOR_PEAK;
  localparam logic [15:0] ADDR_COMPRESSOR_MAX_GAIN_REDUCTION =
      REG_COMPRESSOR_MAX_GAIN_REDUCTION;
  localparam logic [15:0] ADDR_COMPRESSOR_MAX_DETECTOR_PEAK =
      REG_COMPRESSOR_MAX_DETECTOR_PEAK;
  localparam logic [15:0] ADDR_COMPRESSOR_INPUT_FRAME_COUNT =
      REG_COMPRESSOR_INPUT_FRAME_COUNT;
  localparam logic [15:0] ADDR_COMPRESSOR_OUTPUT_FRAME_COUNT =
      REG_COMPRESSOR_OUTPUT_FRAME_COUNT;
  localparam logic [15:0] ADDR_COMPRESSOR_COMPRESSED_FRAME_COUNT =
      REG_COMPRESSOR_COMPRESSED_FRAME_COUNT;
  localparam logic [15:0] ADDR_COMPRESSOR_SATURATION_COUNT =
      REG_COMPRESSOR_SATURATION_COUNT;
  localparam logic [15:0] ADDR_EFFECT_STATUS = REG_EFFECT_STATUS;
  localparam logic [15:0] ADDR_EFFECT_INPUT_FRAME_COUNT = REG_EFFECT_INPUT_FRAME_COUNT;
  localparam logic [15:0] ADDR_EFFECT_OUTPUT_FRAME_COUNT = REG_EFFECT_OUTPUT_FRAME_COUNT;
  localparam logic [15:0] ADDR_EFFECT_SATURATION_COUNT = REG_EFFECT_SATURATION_COUNT;
  localparam logic [15:0] ADDR_EFFECT_MAX_PROCESSING_CYCLES =
      REG_EFFECT_MAX_PROCESSING_CYCLES;
  localparam logic [15:0] ADDR_CHORUS_HISTORY_LEVEL = REG_CHORUS_HISTORY_LEVEL;
  localparam logic [15:0] ADDR_CHORUS_LFO_PHASE = REG_CHORUS_LFO_PHASE;
  localparam logic [15:0] ADDR_CHORUS_SATURATION_COUNT = REG_CHORUS_SATURATION_COUNT;
  localparam logic [15:0] ADDR_REVERB_STATUS = REG_REVERB_STATUS;
  localparam logic [15:0] ADDR_REVERB_SATURATION_COUNT = REG_REVERB_SATURATION_COUNT;
  localparam logic [15:0] ADDR_REVERB_MAX_PROCESSING_CYCLES =
      REG_REVERB_MAX_PROCESSING_CYCLES;
  localparam logic [15:0] ADDR_SAMPLE_WINDOW_REQUEST_COUNT =
      REG_SAMPLE_WINDOW_REQUEST_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_WINDOW_HIT_COUNT =
      REG_SAMPLE_WINDOW_HIT_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_WINDOW_REFILL_COUNT =
      REG_SAMPLE_WINDOW_REFILL_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_WINDOW_FALLBACK_READ_COUNT =
      REG_SAMPLE_WINDOW_FALLBACK_READ_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_WINDOW_MEMORY_READ_COUNT =
      REG_SAMPLE_WINDOW_MEMORY_READ_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_WINDOW_EVICTION_COUNT =
      REG_SAMPLE_WINDOW_EVICTION_COUNT;
  localparam logic [15:0] ADDR_SAMPLE_WINDOW_STALL_CYCLE_COUNT =
      REG_SAMPLE_WINDOW_STALL_CYCLE_COUNT;

  logic [31:0] common_event_flags;
  logic [31:0] underrun_count;
  logic [31:0] sample_drop_count;
  logic [31:0] render_deadline_miss_count;
  logic [31:0] mem_response_count;
  logic [31:0] common_event_set_mask;
  logic [15:0] max_render_latency_cycles;
  logic [15:0] max_mem_response_latency;
  logic diagnostic_clear_write;

  function automatic logic is_common_status_address(input logic [15:0] address);
    unique case (address)
      ADDR_SYSTEM_STATUS, ADDR_COMMON_EVENT_FLAGS, ADDR_PIPELINE_LATENCY_STATUS,
      ADDR_UNDERRUN_COUNT,
      ADDR_SAMPLE_DROP_COUNT, ADDR_RENDER_DEADLINE_MISS_COUNT,
      ADDR_MEM_RESPONSE_COUNT, ADDR_DIAGNOSTIC_CONTROL,
      ADDR_PIPELINE_LATENCY_MAX, ADDR_AUDIO_FIFO_DIAGNOSTICS,
      ADDR_AUDIO_LEAD, ADDR_COMMAND_ERROR_COUNT,
      ADDR_STALE_GENERATION_COUNT, ADDR_RENDER_SESSION_EPOCH,
      ADDR_COMPRESSOR_STATUS,
      ADDR_COMPRESSOR_GAIN_REDUCTION, ADDR_COMPRESSOR_TARGET_GAIN_REDUCTION,
      ADDR_COMPRESSOR_DETECTOR_PEAK, ADDR_COMPRESSOR_MAX_GAIN_REDUCTION,
      ADDR_COMPRESSOR_MAX_DETECTOR_PEAK, ADDR_COMPRESSOR_INPUT_FRAME_COUNT,
      ADDR_COMPRESSOR_OUTPUT_FRAME_COUNT, ADDR_COMPRESSOR_COMPRESSED_FRAME_COUNT,
      ADDR_COMPRESSOR_SATURATION_COUNT, ADDR_EFFECT_STATUS,
      ADDR_EFFECT_INPUT_FRAME_COUNT, ADDR_EFFECT_OUTPUT_FRAME_COUNT,
      ADDR_EFFECT_SATURATION_COUNT, ADDR_EFFECT_MAX_PROCESSING_CYCLES,
      ADDR_CHORUS_HISTORY_LEVEL, ADDR_CHORUS_LFO_PHASE,
      ADDR_CHORUS_SATURATION_COUNT, ADDR_REVERB_STATUS,
      ADDR_REVERB_SATURATION_COUNT, ADDR_REVERB_MAX_PROCESSING_CYCLES,
      ADDR_SAMPLE_WINDOW_REQUEST_COUNT, ADDR_SAMPLE_WINDOW_HIT_COUNT,
      ADDR_SAMPLE_WINDOW_REFILL_COUNT, ADDR_SAMPLE_WINDOW_FALLBACK_READ_COUNT,
      ADDR_SAMPLE_WINDOW_MEMORY_READ_COUNT, ADDR_SAMPLE_WINDOW_EVICTION_COUNT,
      ADDR_SAMPLE_WINDOW_STALL_CYCLE_COUNT: begin
        is_common_status_address = 1'b1;
      end
      default: is_common_status_address = 1'b0;
    endcase
  endfunction

  function automatic logic [31:0] sat_inc(input logic [31:0] value);
    sat_inc = (value == 32'hffff_ffff) ? value : value + 32'd1;
  endfunction

  logic regs_access;

  assign regs_access = bus_req.valid && is_common_status_address(bus_req.address);
  assign diagnostic_clear_write = regs_access && bus_req.write &&
      (bus_req.address == ADDR_DIAGNOSTIC_CONTROL) &&
      ((bus_req.wdata & REG_DIAGNOSTIC_CONTROL_CLEAR_MASK) != '0);
  assign bus_rsp.ready = bus_req.valid;
  assign bus_rsp.error = bus_req.valid && !is_common_status_address(bus_req.address);
  assign common_event_set_mask = {
    28'd0,
    mem_response_trace_pulse,
    render_deadline_miss_pulse,
    sample_drop_pulse,
    underrun_pulse
  };

  always_comb begin
    bus_rsp.rdata = 32'd0;
    unique case (bus_req.address)
      ADDR_SYSTEM_STATUS: begin
        bus_rsp.rdata = {
          8'd0,
          16'(output_fifo_level),
          ext_rsp_valid,
          ext_req_ready,
          ext_req_valid,
          i2s_sample_ready,
          fifo_sample_valid,
          core_sample_valid,
          render_inflight,
          core_busy
        };
      end
      ADDR_COMMON_EVENT_FLAGS: bus_rsp.rdata = common_event_flags;
      ADDR_PIPELINE_LATENCY_STATUS:
          bus_rsp.rdata = {mem_response_trace_latency, render_latency_cycles};
      ADDR_UNDERRUN_COUNT: bus_rsp.rdata = underrun_count;
      ADDR_SAMPLE_DROP_COUNT: bus_rsp.rdata = sample_drop_count;
      ADDR_RENDER_DEADLINE_MISS_COUNT: bus_rsp.rdata = render_deadline_miss_count;
      ADDR_MEM_RESPONSE_COUNT: bus_rsp.rdata = mem_response_count;
      ADDR_DIAGNOSTIC_CONTROL: bus_rsp.rdata = 32'd0;
      ADDR_PIPELINE_LATENCY_MAX:
          bus_rsp.rdata = {max_mem_response_latency, max_render_latency_cycles};
      ADDR_AUDIO_FIFO_DIAGNOSTICS: begin
        bus_rsp.rdata = {
          15'd0,
          playback_started,
          8'(minimum_fifo_level),
          8'(output_fifo_level)
        };
      end
      ADDR_AUDIO_LEAD: bus_rsp.rdata = audio_lead;
      ADDR_COMMAND_ERROR_COUNT: bus_rsp.rdata = command_error_count;
      ADDR_STALE_GENERATION_COUNT: bus_rsp.rdata = stale_generation_count;
      ADDR_RENDER_SESSION_EPOCH: bus_rsp.rdata = session_epoch;
      ADDR_COMPRESSOR_STATUS: begin
        bus_rsp.rdata = {8'd0, audio_diagnostics.compressor.delay_level_frames,
                     5'd0, |audio_diagnostics.compressor.gain_reduction_cb_q12_20,
                     audio_diagnostics.compressor.primed,
                     audio_diagnostics.compressor.enabled};
      end
      ADDR_COMPRESSOR_GAIN_REDUCTION:
          bus_rsp.rdata = audio_diagnostics.compressor.gain_reduction_cb_q12_20;
      ADDR_COMPRESSOR_TARGET_GAIN_REDUCTION:
          bus_rsp.rdata = audio_diagnostics.compressor.target_gain_reduction_cb_q12_20;
      ADDR_COMPRESSOR_DETECTOR_PEAK:
          bus_rsp.rdata = {{(32-synth_pkg::MIX_WIDTH){1'b0}},
                       audio_diagnostics.compressor.detector_peak};
      ADDR_COMPRESSOR_MAX_GAIN_REDUCTION:
          bus_rsp.rdata = audio_diagnostics.compressor.max_gain_reduction_cb_q12_20;
      ADDR_COMPRESSOR_MAX_DETECTOR_PEAK:
          bus_rsp.rdata = {{(32-synth_pkg::MIX_WIDTH){1'b0}},
                       audio_diagnostics.compressor.max_detector_peak};
      ADDR_COMPRESSOR_INPUT_FRAME_COUNT:
          bus_rsp.rdata = audio_diagnostics.compressor.input_frame_count;
      ADDR_COMPRESSOR_OUTPUT_FRAME_COUNT:
          bus_rsp.rdata = audio_diagnostics.compressor.output_frame_count;
      ADDR_COMPRESSOR_COMPRESSED_FRAME_COUNT:
          bus_rsp.rdata = audio_diagnostics.compressor.compressed_frame_count;
      ADDR_COMPRESSOR_SATURATION_COUNT:
          bus_rsp.rdata = audio_diagnostics.compressor.saturation_count;
      ADDR_EFFECT_STATUS: begin
        bus_rsp.rdata = {17'd0, audio_diagnostics.effects.mixer_config_clamped,
                     audio_diagnostics.effects.reverb_config_clamped,
                     audio_diagnostics.effects.chorus_config_clamped,
                     audio_diagnostics.effects.reverb_valid_line_mask,
                     |audio_diagnostics.effects.chorus_history_level_frames,
                     audio_diagnostics.effects.busy,
                     audio_diagnostics.effects.reverb_enabled,
                     audio_diagnostics.effects.chorus_enabled};
      end
      ADDR_EFFECT_INPUT_FRAME_COUNT:
          bus_rsp.rdata = audio_diagnostics.effects.input_frame_count;
      ADDR_EFFECT_OUTPUT_FRAME_COUNT:
          bus_rsp.rdata = audio_diagnostics.effects.output_frame_count;
      ADDR_EFFECT_SATURATION_COUNT:
          bus_rsp.rdata = audio_diagnostics.effects.mixer_saturation_count;
      ADDR_EFFECT_MAX_PROCESSING_CYCLES:
          bus_rsp.rdata = {16'd0, audio_diagnostics.effects.max_processing_cycles};
      ADDR_CHORUS_HISTORY_LEVEL:
          bus_rsp.rdata = {16'd0,
                       audio_diagnostics.effects.chorus_history_level_frames};
      ADDR_CHORUS_LFO_PHASE:
          bus_rsp.rdata = audio_diagnostics.effects.chorus_lfo_phase_q0_32;
      ADDR_CHORUS_SATURATION_COUNT:
          bus_rsp.rdata = audio_diagnostics.effects.chorus_saturation_count;
      ADDR_REVERB_STATUS:
          bus_rsp.rdata = {8'd0, audio_diagnostics.effects.reverb_valid_line_mask,
                       audio_diagnostics.effects.reverb_pre_delay_occupancy};
      ADDR_REVERB_SATURATION_COUNT:
          bus_rsp.rdata = audio_diagnostics.effects.reverb_saturation_count;
      ADDR_REVERB_MAX_PROCESSING_CYCLES:
          bus_rsp.rdata = {16'd0,
                       audio_diagnostics.effects.reverb_max_processing_cycles};
      ADDR_SAMPLE_WINDOW_REQUEST_COUNT:
          bus_rsp.rdata = sample_window_diagnostics.client_request_count;
      ADDR_SAMPLE_WINDOW_HIT_COUNT:
          bus_rsp.rdata = sample_window_diagnostics.window_hit_count;
      ADDR_SAMPLE_WINDOW_REFILL_COUNT:
          bus_rsp.rdata = sample_window_diagnostics.window_refill_count;
      ADDR_SAMPLE_WINDOW_FALLBACK_READ_COUNT:
          bus_rsp.rdata = sample_window_diagnostics.fallback_read_count;
      ADDR_SAMPLE_WINDOW_MEMORY_READ_COUNT:
          bus_rsp.rdata = sample_window_diagnostics.memory_read_count;
      ADDR_SAMPLE_WINDOW_EVICTION_COUNT:
          bus_rsp.rdata = sample_window_diagnostics.eviction_count;
      ADDR_SAMPLE_WINDOW_STALL_CYCLE_COUNT:
          bus_rsp.rdata = sample_window_diagnostics.stall_cycle_count;
      default: bus_rsp.rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst || core_reset) begin
      common_event_flags <= 32'd0;
      underrun_count <= 32'd0;
      sample_drop_count <= 32'd0;
      render_deadline_miss_count <= 32'd0;
      mem_response_count <= 32'd0;
      max_render_latency_cycles <= 16'd0;
      max_mem_response_latency <= 16'd0;
      diagnostics_clear_pulse <= 1'b0;
    end else begin
      diagnostics_clear_pulse <= diagnostic_clear_write;
      if (diagnostic_clear_write) begin
        common_event_flags <= common_event_set_mask;
      end else if (regs_access && bus_req.write &&
                   (bus_req.address == ADDR_COMMON_EVENT_FLAGS)) begin
        common_event_flags <= (common_event_flags & ~bus_req.wdata) | common_event_set_mask;
      end else begin
        common_event_flags <= common_event_flags | common_event_set_mask;
      end

      if (diagnostic_clear_write) begin
        underrun_count <= underrun_pulse ? 32'd1 : 32'd0;
        sample_drop_count <= sample_drop_pulse ? 32'd1 : 32'd0;
        render_deadline_miss_count <=
            render_deadline_miss_pulse ? 32'd1 : 32'd0;
        mem_response_count <= mem_response_trace_pulse ? 32'd1 : 32'd0;
        max_render_latency_cycles <=
            render_latency_valid ? render_latency_cycles : 16'd0;
        max_mem_response_latency <=
            mem_response_trace_pulse ? mem_response_trace_latency : 16'd0;
      end else begin
        if (underrun_pulse)
          underrun_count <= sat_inc(underrun_count);
        if (sample_drop_pulse)
          sample_drop_count <= sat_inc(sample_drop_count);
        if (render_deadline_miss_pulse)
          render_deadline_miss_count <= sat_inc(render_deadline_miss_count);
        if (mem_response_trace_pulse)
          mem_response_count <= sat_inc(mem_response_count);
        if (render_latency_valid &&
            (render_latency_cycles > max_render_latency_cycles))
          max_render_latency_cycles <= render_latency_cycles;
        if (mem_response_trace_pulse &&
            (mem_response_trace_latency > max_mem_response_latency))
          max_mem_response_latency <= mem_response_trace_latency;
      end
    end
  end
endmodule
