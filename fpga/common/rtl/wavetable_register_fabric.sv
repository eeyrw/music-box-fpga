module wavetable_register_fabric #(
  parameter bit PLATFORM_REGS_PRESENT = 1'b0
) (
  input  logic        master_valid,
  input  logic        master_write,
  input  logic [15:0] master_address,
  input  logic [31:0] master_wdata,
  input  logic        core_reset,
  output logic [31:0] master_rdata,
  output logic        master_ready,
  output logic        master_error,

  output logic        core_valid,
  output logic        core_write,
  output logic [15:0] core_address,
  output logic [31:0] core_wdata,
  input  logic [31:0] core_rdata,
  input  logic        core_ready,
  input  logic        core_error,

  output logic        common_status_valid,
  output logic        common_status_write,
  output logic [15:0] common_status_address,
  output logic [31:0] common_status_wdata,
  input  logic [31:0] common_status_rdata,
  input  logic        common_status_ready,
  input  logic        common_status_error,

  output logic        platform_regs_valid,
  output logic        platform_regs_write,
  output logic [15:0] platform_regs_address,
  output logic [31:0] platform_regs_wdata,
  input  logic [31:0] platform_regs_rdata,
  input  logic        platform_regs_ready,
  input  logic        platform_regs_error
);
  import synth_register_pkg::*;

  function automatic logic is_common_status_address(input logic [15:0] address);
    unique case (address)
      REG_SYSTEM_STATUS, REG_COMMON_EVENT_FLAGS, REG_AUDIO_STATUS,
      REG_RENDER_STATUS, REG_MEMORY_STATUS, REG_UNDERRUN_COUNT,
      REG_SAMPLE_DROP_COUNT, REG_RENDER_DEADLINE_MISS_COUNT,
      REG_MEM_RESPONSE_COUNT: is_common_status_address = 1'b1;
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

  assign select_common_status = is_common_status_address(master_address);
  assign select_platform_regs = is_platform_regs_address(master_address);
  assign select_core = !select_common_status && !select_platform_regs;

  assign core_valid = master_valid && select_core && !core_reset;
  assign core_write = master_write;
  assign core_address = master_address;
  assign core_wdata = master_wdata;

  assign common_status_valid = master_valid && select_common_status;
  assign common_status_write = master_write;
  assign common_status_address = master_address;
  assign common_status_wdata = master_wdata;

  assign platform_regs_valid = master_valid && select_platform_regs && PLATFORM_REGS_PRESENT;
  assign platform_regs_write = master_write;
  assign platform_regs_address = master_address;
  assign platform_regs_wdata = master_wdata;

  always_comb begin
    master_rdata = 32'd0;
    master_ready = 1'b0;
    master_error = 1'b0;

    if (master_valid) begin
      if (select_common_status) begin
        master_rdata = common_status_rdata;
        master_ready = common_status_ready;
        master_error = common_status_error;
      end else if (select_platform_regs) begin
        if (PLATFORM_REGS_PRESENT) begin
          master_rdata = platform_regs_rdata;
          master_ready = platform_regs_ready;
          master_error = platform_regs_error;
        end else begin
          master_ready = 1'b1;
          master_error = 1'b1;
        end
      end else if (core_reset) begin
        master_ready = 1'b1;
        master_error = 1'b1;
      end else begin
        master_rdata = core_rdata;
        master_ready = core_ready;
        master_error = core_error;
      end
    end
  end
endmodule
