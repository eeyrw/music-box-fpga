module wavetable_system_debug_regs #(
  parameter int LINE_WORDS = 8,
  parameter int OUTPUT_FIFO_DEPTH = 8
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     core_reset,
  input  logic                     bus_valid,
  input  logic                     bus_write,
  input  logic [15:0]              bus_address,
  input  logic [31:0]              bus_wdata,
  output logic                     debug_access,
  output logic [31:0]              debug_rdata,
  input  logic                     sample_tick,
  input  logic                     core_sample_valid,
  input  logic                     core_busy,
  input  logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  input  logic                     ext_rsp_valid,
  input  logic                     i2s_sample_ready,
  input  logic                     fifo_sample_valid,
  input  logic                     underrun_pulse,
  input  logic                     sample_drop_pulse,
  input  logic                     mem_debug_hit_pulse,
  input  logic                     mem_debug_miss_pulse,
  input  logic                     mem_debug_response_pulse,
  input  logic [15:0]              mem_debug_response_latency,
  input  logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
  output logic                     render_deadline_miss_pulse,
  output logic [15:0]              render_latency_cycles,
  input  logic                     platform_ddr_init_calib_complete,
  input  logic                     platform_ddr_ui_rst,
  input  logic [11:0]              platform_ddr_device_temp,
  input  logic                     platform_mig_app_rdy,
  input  logic                     platform_mig_app_wdf_rdy,
  input  logic                     platform_mig_app_rd_data_valid,
  input  logic                     platform_mig_app_rd_data_end,
  input  logic                     platform_sd_initialized,
  input  logic                     platform_asset_loaded,
  input  logic                     platform_asset_loader_busy,
  input  logic [3:0]               platform_asset_loader_state,
  input  logic [7:0]               platform_sd_error_code,
  input  logic [7:0]               platform_loader_error_code,
  input  logic [31:0]              platform_bytes_loaded,
  input  logic [31:0]              platform_sf2_size_bytes,
  input  logic [31:0]              platform_current_lba,
  output logic                     platform_ddr_debug_start,
  output logic                     platform_ddr_debug_write,
  output logic [31:0]              platform_ddr_debug_addr,
  output logic [LINE_WORDS*16-1:0] platform_ddr_debug_wdata,
  output logic [LINE_WORDS*2-1:0]  platform_ddr_debug_byte_enable,
  input  logic                     platform_ddr_debug_ready,
  input  logic                     platform_ddr_debug_busy,
  input  logic                     platform_ddr_debug_done,
  input  logic                     platform_ddr_debug_error,
  input  logic [LINE_WORDS*16-1:0] platform_ddr_debug_rdata
);
  localparam logic [15:0] ADDR_SYSTEM_STATUS = 16'h3010;
  localparam logic [15:0] ADDR_DEBUG_EVENT_FLAGS = 16'h3014;
  localparam logic [15:0] ADDR_AUDIO_STATUS = 16'h3018;
  localparam logic [15:0] ADDR_RENDER_STATUS = 16'h301c;
  localparam logic [15:0] ADDR_MEMORY_STATUS = 16'h3020;
  localparam logic [15:0] ADDR_UNDERRUN_COUNT = 16'h3024;
  localparam logic [15:0] ADDR_SAMPLE_DROP_COUNT = 16'h3028;
  localparam logic [15:0] ADDR_RENDER_DEADLINE_MISS_COUNT = 16'h302c;
  localparam logic [15:0] ADDR_MEM_HIT_COUNT = 16'h3030;
  localparam logic [15:0] ADDR_MEM_MISS_COUNT = 16'h3034;
  localparam logic [15:0] ADDR_MEM_RESPONSE_COUNT = 16'h3038;
  localparam logic [15:0] ADDR_PLATFORM_STATUS = 16'h3040;
  localparam logic [15:0] ADDR_PLATFORM_ERRORS = 16'h3044;
  localparam logic [15:0] ADDR_PLATFORM_BYTES_LOADED = 16'h3048;
  localparam logic [15:0] ADDR_PLATFORM_SF2_SIZE = 16'h3050;
  localparam logic [15:0] ADDR_PLATFORM_CURRENT_LBA = 16'h3058;
  localparam logic [15:0] ADDR_PLATFORM_DDR_STATUS = 16'h305c;
  localparam logic [15:0] ADDR_DDR_DEBUG_CONTROL = 16'h3060;
  localparam logic [15:0] ADDR_DDR_DEBUG_STATUS = 16'h3064;
  localparam logic [15:0] ADDR_DDR_DEBUG_ADDR = 16'h3068;
  localparam logic [15:0] ADDR_DDR_DEBUG_BYTE_ENABLE = 16'h306c;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA0 = 16'h3070;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA1 = 16'h3074;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA2 = 16'h3078;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA3 = 16'h307c;

  logic render_pending;
  logic [15:0] render_latency_count;
  logic [31:0] debug_event_flags;
  logic [31:0] underrun_count;
  logic [31:0] sample_drop_count;
  logic [31:0] render_deadline_miss_count;
  logic [31:0] mem_hit_count;
  logic [31:0] mem_miss_count;
  logic [31:0] mem_response_count;
  logic [31:0] debug_event_set_mask;
  logic ddr_debug_write_latched;
  logic ddr_debug_done_latched;
  logic ddr_debug_error_latched;

  function automatic logic is_system_debug_address(input logic [15:0] address);
    unique case (address)
      ADDR_SYSTEM_STATUS, ADDR_DEBUG_EVENT_FLAGS, ADDR_AUDIO_STATUS,
      ADDR_RENDER_STATUS, ADDR_MEMORY_STATUS, ADDR_UNDERRUN_COUNT,
      ADDR_SAMPLE_DROP_COUNT, ADDR_RENDER_DEADLINE_MISS_COUNT,
      ADDR_MEM_HIT_COUNT, ADDR_MEM_MISS_COUNT, ADDR_MEM_RESPONSE_COUNT,
      ADDR_PLATFORM_STATUS, ADDR_PLATFORM_ERRORS, ADDR_PLATFORM_BYTES_LOADED,
      ADDR_PLATFORM_SF2_SIZE, ADDR_PLATFORM_CURRENT_LBA,
      ADDR_PLATFORM_DDR_STATUS, ADDR_DDR_DEBUG_CONTROL,
      ADDR_DDR_DEBUG_STATUS, ADDR_DDR_DEBUG_ADDR,
      ADDR_DDR_DEBUG_BYTE_ENABLE, ADDR_DDR_DEBUG_DATA0,
      ADDR_DDR_DEBUG_DATA1, ADDR_DDR_DEBUG_DATA2,
      ADDR_DDR_DEBUG_DATA3: begin
        is_system_debug_address = 1'b1;
      end
      default: is_system_debug_address = 1'b0;
    endcase
  endfunction

  function automatic logic [31:0] sat_inc(input logic [31:0] value);
    sat_inc = (value == 32'hffff_ffff) ? value : value + 32'd1;
  endfunction

  assign debug_access = bus_valid && is_system_debug_address(bus_address);
  assign debug_event_set_mask = {
    26'd0,
    mem_debug_response_pulse,
    mem_debug_miss_pulse,
    mem_debug_hit_pulse,
    sample_tick && render_pending && !core_sample_valid,
    sample_drop_pulse,
    underrun_pulse
  };

  always_comb begin
    debug_rdata = 32'd0;
    unique case (bus_address)
      ADDR_SYSTEM_STATUS: begin
        debug_rdata = {
          24'd0,
          ext_rsp_valid,
          ext_req_ready,
          ext_req_valid,
          i2s_sample_ready,
          fifo_sample_valid,
          core_sample_valid,
          render_pending,
          core_busy
        };
      end
      ADDR_DEBUG_EVENT_FLAGS: debug_rdata = debug_event_flags;
      ADDR_AUDIO_STATUS: begin
        debug_rdata = {
          14'd0,
          debug_event_flags[1],
          debug_event_flags[0],
          16'(output_fifo_level)
        };
      end
      ADDR_RENDER_STATUS: begin
        debug_rdata = {14'd0, debug_event_flags[2], render_pending, render_latency_cycles};
      end
      ADDR_MEMORY_STATUS: begin
        debug_rdata = {
          10'd0,
          debug_event_flags[5],
          debug_event_flags[4],
          debug_event_flags[3],
          ext_rsp_valid,
          ext_req_ready,
          ext_req_valid,
          mem_debug_response_latency
        };
      end
      ADDR_UNDERRUN_COUNT: debug_rdata = underrun_count;
      ADDR_SAMPLE_DROP_COUNT: debug_rdata = sample_drop_count;
      ADDR_RENDER_DEADLINE_MISS_COUNT: debug_rdata = render_deadline_miss_count;
      ADDR_MEM_HIT_COUNT: debug_rdata = mem_hit_count;
      ADDR_MEM_MISS_COUNT: debug_rdata = mem_miss_count;
      ADDR_MEM_RESPONSE_COUNT: debug_rdata = mem_response_count;
      ADDR_PLATFORM_STATUS: begin
        debug_rdata[0] = 1'b1;
        debug_rdata[1] = (platform_sd_error_code != 8'd0) || (platform_loader_error_code != 8'd0);
        debug_rdata[2] = platform_ddr_init_calib_complete;
        debug_rdata[3] = platform_ddr_ui_rst;
        debug_rdata[4] = platform_sd_initialized;
        debug_rdata[5] = platform_asset_loaded;
        debug_rdata[6] = platform_asset_loader_busy;
        debug_rdata[7] = platform_mig_app_rdy;
        debug_rdata[8] = platform_mig_app_wdf_rdy;
        debug_rdata[9] = platform_mig_app_rd_data_valid;
        debug_rdata[10] = platform_mig_app_rd_data_end;
        debug_rdata[14:11] = platform_asset_loader_state;
      end
      ADDR_PLATFORM_ERRORS: begin
        debug_rdata = {12'd0, platform_asset_loader_state,
                       platform_loader_error_code, platform_sd_error_code};
      end
      ADDR_PLATFORM_BYTES_LOADED: debug_rdata = platform_bytes_loaded;
      ADDR_PLATFORM_SF2_SIZE: debug_rdata = platform_sf2_size_bytes;
      ADDR_PLATFORM_CURRENT_LBA: debug_rdata = platform_current_lba;
      ADDR_PLATFORM_DDR_STATUS: begin
        debug_rdata[0] = platform_ddr_init_calib_complete;
        debug_rdata[1] = platform_ddr_ui_rst;
        debug_rdata[2] = platform_mig_app_rdy;
        debug_rdata[3] = platform_mig_app_wdf_rdy;
        debug_rdata[4] = platform_mig_app_rd_data_valid;
        debug_rdata[5] = platform_mig_app_rd_data_end;
        debug_rdata[27:16] = platform_ddr_device_temp;
      end
      ADDR_DDR_DEBUG_CONTROL: begin
        debug_rdata[1] = ddr_debug_write_latched;
      end
      ADDR_DDR_DEBUG_STATUS: begin
        debug_rdata = {
          26'd0,
          ddr_debug_write_latched,
          ddr_debug_error_latched,
          ddr_debug_done_latched,
          platform_ddr_debug_busy,
          platform_ddr_debug_ready,
          1'b1
        };
      end
      ADDR_DDR_DEBUG_ADDR: debug_rdata = platform_ddr_debug_addr;
      ADDR_DDR_DEBUG_BYTE_ENABLE: debug_rdata = {16'd0, platform_ddr_debug_byte_enable};
      ADDR_DDR_DEBUG_DATA0: debug_rdata = platform_ddr_debug_rdata[31:0];
      ADDR_DDR_DEBUG_DATA1: debug_rdata = platform_ddr_debug_rdata[63:32];
      ADDR_DDR_DEBUG_DATA2: debug_rdata = platform_ddr_debug_rdata[95:64];
      ADDR_DDR_DEBUG_DATA3: debug_rdata = platform_ddr_debug_rdata[127:96];
      default: debug_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      render_pending <= 1'b0;
      render_latency_count <= '0;
      render_latency_cycles <= '0;
      render_deadline_miss_pulse <= 1'b0;
      debug_event_flags <= 32'd0;
      underrun_count <= 32'd0;
      sample_drop_count <= 32'd0;
      render_deadline_miss_count <= 32'd0;
      mem_hit_count <= 32'd0;
      mem_miss_count <= 32'd0;
      mem_response_count <= 32'd0;
      platform_ddr_debug_start <= 1'b0;
      platform_ddr_debug_write <= 1'b0;
      platform_ddr_debug_addr <= 32'd0;
      platform_ddr_debug_wdata <= '0;
      platform_ddr_debug_byte_enable <= '1;
      ddr_debug_write_latched <= 1'b0;
      ddr_debug_done_latched <= 1'b0;
      ddr_debug_error_latched <= 1'b0;
    end else begin
      render_deadline_miss_pulse <= 1'b0;
      platform_ddr_debug_start <= 1'b0;

      if (platform_ddr_debug_done)
        ddr_debug_done_latched <= 1'b1;
      if (platform_ddr_debug_error)
        ddr_debug_error_latched <= 1'b1;

      if (debug_access && bus_write) begin
        unique case (bus_address)
          ADDR_DDR_DEBUG_CONTROL: begin
            if (bus_wdata[0] && platform_ddr_debug_ready) begin
              platform_ddr_debug_start <= 1'b1;
              platform_ddr_debug_write <= bus_wdata[1];
              ddr_debug_write_latched <= bus_wdata[1];
              ddr_debug_done_latched <= 1'b0;
              ddr_debug_error_latched <= 1'b0;
            end
            if (bus_wdata[2]) begin
              ddr_debug_done_latched <= 1'b0;
              ddr_debug_error_latched <= 1'b0;
            end
          end
          ADDR_DDR_DEBUG_ADDR: platform_ddr_debug_addr <= bus_wdata;
          ADDR_DDR_DEBUG_BYTE_ENABLE: platform_ddr_debug_byte_enable <= bus_wdata[LINE_WORDS*2-1:0];
          ADDR_DDR_DEBUG_DATA0: platform_ddr_debug_wdata[31:0] <= bus_wdata;
          ADDR_DDR_DEBUG_DATA1: platform_ddr_debug_wdata[63:32] <= bus_wdata;
          ADDR_DDR_DEBUG_DATA2: platform_ddr_debug_wdata[95:64] <= bus_wdata;
          ADDR_DDR_DEBUG_DATA3: platform_ddr_debug_wdata[127:96] <= bus_wdata;
          default: begin
          end
        endcase
      end

      if (debug_access && bus_write && (bus_address == ADDR_DEBUG_EVENT_FLAGS)) begin
        debug_event_flags <= (debug_event_flags & ~bus_wdata) | debug_event_set_mask;
      end else begin
        debug_event_flags <= debug_event_flags | debug_event_set_mask;
      end

      if (underrun_pulse)
        underrun_count <= sat_inc(underrun_count);
      if (sample_drop_pulse)
        sample_drop_count <= sat_inc(sample_drop_count);
      if (sample_tick && render_pending && !core_sample_valid)
        render_deadline_miss_count <= sat_inc(render_deadline_miss_count);
      if (mem_debug_hit_pulse)
        mem_hit_count <= sat_inc(mem_hit_count);
      if (mem_debug_miss_pulse)
        mem_miss_count <= sat_inc(mem_miss_count);
      if (mem_debug_response_pulse)
        mem_response_count <= sat_inc(mem_response_count);

      if (core_reset) begin
        render_pending <= 1'b0;
        render_latency_count <= '0;
        render_latency_cycles <= '0;
      end else begin
        render_deadline_miss_pulse <= sample_tick && render_pending && !core_sample_valid;

        if (sample_tick) begin
          render_pending <= 1'b1;
          render_latency_count <= '0;
        end else if (core_sample_valid) begin
          render_pending <= 1'b0;
          render_latency_cycles <= render_latency_count;
        end else if (render_pending && render_latency_count != 16'hffff) begin
          render_latency_count <= render_latency_count + 1'b1;
        end
      end
    end
  end
endmodule
