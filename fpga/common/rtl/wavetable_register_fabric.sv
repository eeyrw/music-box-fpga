module wavetable_register_fabric #(
  parameter bit PLATFORM_REGS_PRESENT = 1'b0
) (
  input  synth_pkg::reg_bus_req_t master_req,
  input  logic        core_reset,
  output synth_pkg::reg_bus_rsp_t master_rsp,
  output synth_pkg::reg_bus_req_t core_req,
  input  synth_pkg::reg_bus_rsp_t core_rsp,
  output synth_pkg::reg_bus_req_t common_status_req,
  input  synth_pkg::reg_bus_rsp_t common_status_rsp,
  output synth_pkg::reg_bus_req_t platform_regs_req,
  input  synth_pkg::reg_bus_rsp_t platform_regs_rsp
);
  import synth_register_pkg::*;

  function automatic logic is_common_status_address(input logic [15:0] address);
    unique case (address)
      REG_SYSTEM_STATUS, REG_COMMON_EVENT_FLAGS, REG_PIPELINE_LATENCY_STATUS,
      REG_UNDERRUN_COUNT,
      REG_SAMPLE_DROP_COUNT, REG_RENDER_DEADLINE_MISS_COUNT,
      REG_MEM_RESPONSE_COUNT, REG_COMPRESSOR_STATUS,
      REG_COMPRESSOR_GAIN_REDUCTION, REG_COMPRESSOR_TARGET_GAIN_REDUCTION,
      REG_COMPRESSOR_DETECTOR_PEAK, REG_COMPRESSOR_MAX_GAIN_REDUCTION,
      REG_COMPRESSOR_MAX_DETECTOR_PEAK, REG_COMPRESSOR_INPUT_FRAME_COUNT,
      REG_COMPRESSOR_OUTPUT_FRAME_COUNT, REG_COMPRESSOR_COMPRESSED_FRAME_COUNT,
      REG_COMPRESSOR_SATURATION_COUNT, REG_EFFECT_STATUS,
      REG_EFFECT_INPUT_FRAME_COUNT, REG_EFFECT_OUTPUT_FRAME_COUNT,
      REG_EFFECT_SATURATION_COUNT, REG_EFFECT_MAX_PROCESSING_CYCLES,
      REG_CHORUS_HISTORY_LEVEL, REG_CHORUS_LFO_PHASE,
      REG_CHORUS_SATURATION_COUNT, REG_REVERB_STATUS,
      REG_REVERB_SATURATION_COUNT,
      REG_REVERB_MAX_PROCESSING_CYCLES, REG_SAMPLE_WINDOW_REQUEST_COUNT,
      REG_SAMPLE_WINDOW_HIT_COUNT, REG_SAMPLE_WINDOW_REFILL_COUNT,
      REG_SAMPLE_WINDOW_FALLBACK_READ_COUNT,
      REG_SAMPLE_WINDOW_MEMORY_READ_COUNT, REG_SAMPLE_WINDOW_EVICTION_COUNT,
      REG_SAMPLE_WINDOW_STALL_CYCLE_COUNT: is_common_status_address = 1'b1;
      default: is_common_status_address = 1'b0;
    endcase
  endfunction

  function automatic logic is_platform_regs_address(input logic [15:0] address);
    unique case (address)
      REG_PLATFORM_STATUS, REG_PLATFORM_ERRORS, REG_PLATFORM_BYTES_LOADED,
      REG_PLATFORM_SF2_SIZE, REG_PLATFORM_CURRENT_LBA,
      REG_PLATFORM_DDR_STATUS, REG_DDR_ACCESS_CONTROL,
      REG_DDR_ACCESS_STATUS, REG_DDR_ACCESS_ADDR,
      REG_DDR_ACCESS_BYTE_ENABLE, REG_DDR_ACCESS_DATA0,
      REG_DDR_ACCESS_DATA1, REG_DDR_ACCESS_DATA2,
      REG_DDR_ACCESS_DATA3: is_platform_regs_address = 1'b1;
      default: is_platform_regs_address = 1'b0;
    endcase
  endfunction

  logic select_common_status;
  logic select_platform_regs;
  logic select_core;
  logic select_reset_safe_core;

  assign select_common_status = is_common_status_address(master_req.address);
  assign select_platform_regs = is_platform_regs_address(master_req.address);
  assign select_core = !select_common_status && !select_platform_regs;
  assign select_reset_safe_core = select_core &&
                                  master_req.address == REG_VERSION;

  always_comb begin
    core_req = master_req;
    core_req.valid = master_req.valid && select_core &&
                     (!core_reset || select_reset_safe_core);
    common_status_req = master_req;
    common_status_req.valid = master_req.valid && select_common_status;
    platform_regs_req = master_req;
    platform_regs_req.valid = master_req.valid && select_platform_regs &&
                              PLATFORM_REGS_PRESENT;
  end

  always_comb begin
    master_rsp = '0;

    if (master_req.valid) begin
      if (select_common_status) begin
        master_rsp = common_status_rsp;
      end else if (select_platform_regs) begin
        if (PLATFORM_REGS_PRESENT) begin
          master_rsp = platform_regs_rsp;
        end else begin
          master_rsp.ready = 1'b1;
          master_rsp.error = 1'b1;
        end
      end else if (core_reset && !select_reset_safe_core) begin
        master_rsp.ready = 1'b1;
        master_rsp.error = 1'b1;
      end else begin
        master_rsp = core_rsp;
      end
    end
  end
endmodule
