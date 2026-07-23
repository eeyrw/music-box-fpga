// Generated from spec/register_map.json by tools/gen_register_map.py.
// Do not edit by hand.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
package synth_register_pkg;
  localparam int REG_BUS_ADDR_WIDTH = 16;
  localparam int REG_BUS_DATA_WIDTH = 32;
  localparam logic [31:0] REG_VERSION_VALUE = 32'h00060000;
  localparam logic [15:0] REG_VOICE_BASE = 16'h0100;
  localparam logic [15:0] REG_VOICE_STRIDE = 16'h0080;
  localparam int REG_VOICE_STRIDE_SHIFT = 7;
  localparam int REG_MAX_ADDRESSABLE_VOICES = 286;

  localparam logic [15:0] REG_OFF_BASE_ADDR = 16'h0000;
  localparam logic [15:0] REG_OFF_BASE_ADDR_R = 16'h0004;
  localparam logic [15:0] REG_OFF_LENGTH = 16'h0008;
  localparam logic [15:0] REG_OFF_LENGTH_R = 16'h000c;
  localparam logic [15:0] REG_OFF_LOOP_START = 16'h0010;
  localparam logic [15:0] REG_OFF_LOOP_START_R = 16'h0014;
  localparam logic [15:0] REG_OFF_LOOP_END = 16'h0018;
  localparam logic [15:0] REG_OFF_LOOP_END_R = 16'h001c;
  localparam logic [15:0] REG_OFF_PHASE_INIT = 16'h0020;
  localparam logic [15:0] REG_OFF_PHASE_INC = 16'h0024;
  localparam logic [15:0] REG_OFF_GAIN = 16'h0028;
  localparam logic [15:0] REG_OFF_ENVELOPE = 16'h002c;
  localparam logic [15:0] REG_OFF_FILTER_CONTROL = 16'h0030;
  localparam logic [15:0] REG_OFF_FILTER_B0_B1 = 16'h0034;
  localparam logic [15:0] REG_OFF_FILTER_B2_A1 = 16'h0038;
  localparam logic [15:0] REG_OFF_FILTER_A2 = 16'h003c;
  localparam logic [15:0] REG_OFF_VOICE_CONTROL = 16'h0040;
  localparam logic [15:0] REG_OFF_PHASE_INC_RUNTIME = 16'h0044;
  localparam logic [15:0] REG_OFF_GAIN_RUNTIME = 16'h0048;
  localparam logic [15:0] REG_OFF_ENVELOPE_RUNTIME = 16'h004c;
  localparam logic [15:0] REG_OFF_RELEASE_CONTROL = 16'h0050;
  localparam logic [15:0] REG_OFF_STATUS = 16'h0054;

  localparam logic [15:0] REG_VERSION = 16'h9000;
  localparam logic [15:0] REG_SYSTEM_STATUS = 16'h9010;
  localparam logic [15:0] REG_COMMON_EVENT_FLAGS = 16'h9014;
  localparam logic [15:0] REG_AUDIO_STATUS = 16'h9018;
  localparam logic [15:0] REG_RENDER_STATUS = 16'h901c;
  localparam logic [15:0] REG_MEMORY_STATUS = 16'h9020;
  localparam logic [15:0] REG_UNDERRUN_COUNT = 16'h9024;
  localparam logic [15:0] REG_SAMPLE_DROP_COUNT = 16'h9028;
  localparam logic [15:0] REG_RENDER_DEADLINE_MISS_COUNT = 16'h902c;
  localparam logic [15:0] REG_EVENT_TIME = 16'h9030;
  localparam logic [15:0] REG_EVENT_FIFO_STATUS = 16'h9034;
  localparam logic [15:0] REG_MEM_RESPONSE_COUNT = 16'h9038;
  localparam logic [15:0] REG_EVENT_FIFO_DATA0 = 16'h9080;
  localparam logic [15:0] REG_EVENT_FIFO_DATA1 = 16'h9084;
  localparam logic [15:0] REG_EVENT_FIFO_DATA2 = 16'h9088;
  localparam logic [15:0] REG_EVENT_FIFO_PUSH = 16'h908c;
  localparam logic [15:0] REG_PLATFORM_STATUS = 16'h9040;
  localparam logic [15:0] REG_PLATFORM_ERRORS = 16'h9044;
  localparam logic [15:0] REG_PLATFORM_BYTES_LOADED = 16'h9048;
  localparam logic [15:0] REG_PLATFORM_SF2_SIZE = 16'h9050;
  localparam logic [15:0] REG_PLATFORM_CURRENT_LBA = 16'h9058;
  localparam logic [15:0] REG_PLATFORM_DDR_STATUS = 16'h905c;
  localparam logic [15:0] REG_DDR_ACCESS_CONTROL = 16'h9060;
  localparam logic [15:0] REG_DDR_ACCESS_STATUS = 16'h9064;
  localparam logic [15:0] REG_DDR_ACCESS_ADDR = 16'h9068;
  localparam logic [15:0] REG_DDR_ACCESS_BYTE_ENABLE = 16'h906c;
  localparam logic [15:0] REG_DDR_ACCESS_DATA0 = 16'h9070;
  localparam logic [15:0] REG_DDR_ACCESS_DATA1 = 16'h9074;
  localparam logic [15:0] REG_DDR_ACCESS_DATA2 = 16'h9078;
  localparam logic [15:0] REG_DDR_ACCESS_DATA3 = 16'h907c;

  localparam int REG_VOICE_CONTROL_STEREO_BIT = 0;
  localparam int REG_VOICE_CONTROL_LOOP_MODE_LSB = 1;
  localparam int REG_VOICE_CONTROL_LOOP_MODE_WIDTH = 2;
  localparam logic [31:0] REG_VOICE_CONTROL_ENABLE_MASK = 32'h00000008;
  localparam logic [31:0] REG_VOICE_CONTROL_APPLY_MASK = 32'h00000010;
  localparam logic [31:0] REG_VOICE_CONTROL_MASK = 32'h0000000f;
  localparam logic [31:0] REG_FILTER_CONTROL_ENABLE_MASK = 32'h00000001;
  localparam logic [31:0] REG_FILTER_A2_APPLY_MASK = 32'h00010000;
  localparam logic [31:0] REG_COMMON_EVENT_FLAGS_UNDERRUN_MASK = 32'h00000001;
  localparam logic [31:0] REG_COMMON_EVENT_FLAGS_SAMPLE_DROP_MASK = 32'h00000002;
  localparam logic [31:0] REG_COMMON_EVENT_FLAGS_RENDER_DEADLINE_MISS_MASK = 32'h00000004;
  localparam logic [31:0] REG_COMMON_EVENT_FLAGS_MEM_RESPONSE_MASK = 32'h00000008;
  localparam logic [31:0] REG_PLATFORM_STATUS_PLATFORM_REGS_PRESENT_MASK = 32'h00000001;
  localparam logic [31:0] REG_PLATFORM_STATUS_ERROR_PRESENT_MASK = 32'h00000002;
  localparam logic [31:0] REG_PLATFORM_STATUS_DDR_CALIBRATED_MASK = 32'h00000004;
  localparam logic [31:0] REG_PLATFORM_STATUS_DDR_UI_RESET_MASK = 32'h00000008;
  localparam logic [31:0] REG_PLATFORM_STATUS_SD_INITIALIZED_MASK = 32'h00000010;
  localparam logic [31:0] REG_PLATFORM_STATUS_ASSET_LOADED_MASK = 32'h00000020;
  localparam logic [31:0] REG_DDR_ACCESS_CONTROL_START_MASK = 32'h00000001;
  localparam logic [31:0] REG_DDR_ACCESS_CONTROL_WRITE_MASK = 32'h00000002;
  localparam logic [31:0] REG_DDR_ACCESS_CONTROL_CLEAR_MASK = 32'h00000004;
  localparam logic [31:0] REG_DDR_ACCESS_STATUS_PRESENT_MASK = 32'h00000001;
  localparam logic [31:0] REG_DDR_ACCESS_STATUS_READY_MASK = 32'h00000002;
  localparam logic [31:0] REG_DDR_ACCESS_STATUS_DONE_MASK = 32'h00000008;
  localparam logic [31:0] REG_DDR_ACCESS_STATUS_ERROR_MASK = 32'h00000010;

  localparam logic [31:0] REG_Q15_FULL = 32'h00007fff;
  localparam logic [31:0] REG_FILTER_B0_UNITY_Q2_14 = 32'h00004000;

  function automatic logic [15:0] reg_voice_addr(input logic [15:0] voice, input logic [15:0] offset);
    reg_voice_addr = REG_VOICE_BASE + (voice * REG_VOICE_STRIDE) + offset;
  endfunction
endpackage
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
