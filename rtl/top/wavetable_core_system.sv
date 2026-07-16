module wavetable_core_system #(
  parameter int LINE_WORDS = 8,
  parameter int OUTPUT_FIFO_DEPTH = 8,
  parameter int SYS_CLK_HZ = 100_000_000,
  parameter int SAMPLE_RATE_HZ = 48_000
) (
  input  logic                     clk,
  input  logic                     rst,
  input  logic                     core_rst,
  input  logic                     spi_sclk,
  input  logic                     spi_cs_n,
  input  logic                     spi_mosi,
  output logic                     spi_miso,
  output logic                     spi_error,
  output logic                     ext_req_valid,
  input  logic                     ext_req_ready,
  output logic [31:0]              ext_req_addr,
  input  logic                     ext_rsp_valid,
  input  logic [LINE_WORDS*16-1:0] ext_rsp_data,
  output logic                     i2s_bclk,
  output logic                     i2s_lrclk,
  output logic                     i2s_sdata,
  output logic                     underrun_pulse,
  output logic                     sample_drop_pulse,
  output logic                     mem_debug_hit_pulse,
  output logic                     mem_debug_miss_pulse,
  output logic                     mem_debug_response_pulse,
  output logic [15:0]              mem_debug_response_latency,
  output logic [$clog2(OUTPUT_FIFO_DEPTH+1)-1:0] output_fifo_level,
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
  logic sample_tick;
  logic spi_bus_valid;
  logic spi_bus_write;
  logic [15:0] spi_bus_address;
  logic [31:0] spi_bus_wdata;
  logic [31:0] spi_bus_rdata;
  logic spi_bus_ready;
  logic spi_bus_error;
  logic core_bus_valid;
  logic core_bus_write;
  logic [15:0] core_bus_address;
  logic [31:0] core_bus_wdata;
  logic [31:0] core_bus_rdata;
  logic core_bus_ready;
  logic core_bus_error;
  logic core_sample_valid;
  synth_pkg::pcm_t core_sample_l;
  synth_pkg::pcm_t core_sample_r;
/* verilator lint_off UNUSEDSIGNAL */
  logic core_busy;
/* verilator lint_on UNUSEDSIGNAL */
  logic i2s_sample_ready;
/* verilator lint_off UNUSEDSIGNAL */
  logic fifo_input_ready;
/* verilator lint_on UNUSEDSIGNAL */
  logic fifo_sample_valid;
  logic fifo_sample_ready;
  synth_pkg::pcm_t fifo_sample_l;
  synth_pkg::pcm_t fifo_sample_r;
  logic render_pending;
  logic [15:0] render_latency_count;
  logic core_reset;

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

  logic system_debug_access;
  logic [31:0] system_debug_rdata;
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

  assign core_reset = rst || core_rst;
  assign system_debug_access = spi_bus_valid && is_system_debug_address(spi_bus_address);
  assign core_bus_valid = spi_bus_valid && !system_debug_access && !core_reset;
  assign core_bus_write = spi_bus_write;
  assign core_bus_address = spi_bus_address;
  assign core_bus_wdata = spi_bus_wdata;
  assign spi_bus_ready = system_debug_access ? 1'b1 : (core_reset ? spi_bus_valid : core_bus_ready);
  assign spi_bus_error = system_debug_access ? 1'b0 : (core_reset ? 1'b1 : core_bus_error);
  assign spi_bus_rdata = system_debug_access ? system_debug_rdata : (core_reset ? 32'd0 : core_bus_rdata);
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
    system_debug_rdata = 32'd0;
    unique case (spi_bus_address)
      ADDR_SYSTEM_STATUS: begin
        system_debug_rdata = {
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
      ADDR_DEBUG_EVENT_FLAGS: system_debug_rdata = debug_event_flags;
      ADDR_AUDIO_STATUS: begin
        system_debug_rdata = {
          14'd0,
          debug_event_flags[1],
          debug_event_flags[0],
          16'(output_fifo_level)
        };
      end
      ADDR_RENDER_STATUS: begin
        system_debug_rdata = {14'd0, debug_event_flags[2], render_pending, render_latency_cycles};
      end
      ADDR_MEMORY_STATUS: begin
        system_debug_rdata = {
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
      ADDR_UNDERRUN_COUNT: system_debug_rdata = underrun_count;
      ADDR_SAMPLE_DROP_COUNT: system_debug_rdata = sample_drop_count;
      ADDR_RENDER_DEADLINE_MISS_COUNT: system_debug_rdata = render_deadline_miss_count;
      ADDR_MEM_HIT_COUNT: system_debug_rdata = mem_hit_count;
      ADDR_MEM_MISS_COUNT: system_debug_rdata = mem_miss_count;
      ADDR_MEM_RESPONSE_COUNT: system_debug_rdata = mem_response_count;
      ADDR_PLATFORM_STATUS: begin
        system_debug_rdata[0] = 1'b1;
        system_debug_rdata[1] = (platform_sd_error_code != 8'd0) || (platform_loader_error_code != 8'd0);
        system_debug_rdata[2] = platform_ddr_init_calib_complete;
        system_debug_rdata[3] = platform_ddr_ui_rst;
        system_debug_rdata[4] = platform_sd_initialized;
        system_debug_rdata[5] = platform_asset_loaded;
        system_debug_rdata[6] = platform_asset_loader_busy;
        system_debug_rdata[7] = platform_mig_app_rdy;
        system_debug_rdata[8] = platform_mig_app_wdf_rdy;
        system_debug_rdata[9] = platform_mig_app_rd_data_valid;
        system_debug_rdata[10] = platform_mig_app_rd_data_end;
        system_debug_rdata[14:11] = platform_asset_loader_state;
      end
      ADDR_PLATFORM_ERRORS: begin
        system_debug_rdata = {12'd0, platform_asset_loader_state,
                              platform_loader_error_code, platform_sd_error_code};
      end
      ADDR_PLATFORM_BYTES_LOADED: system_debug_rdata = platform_bytes_loaded;
      ADDR_PLATFORM_SF2_SIZE: system_debug_rdata = platform_sf2_size_bytes;
      ADDR_PLATFORM_CURRENT_LBA: system_debug_rdata = platform_current_lba;
      ADDR_PLATFORM_DDR_STATUS: begin
        system_debug_rdata[0] = platform_ddr_init_calib_complete;
        system_debug_rdata[1] = platform_ddr_ui_rst;
        system_debug_rdata[2] = platform_mig_app_rdy;
        system_debug_rdata[3] = platform_mig_app_wdf_rdy;
        system_debug_rdata[4] = platform_mig_app_rd_data_valid;
        system_debug_rdata[5] = platform_mig_app_rd_data_end;
        system_debug_rdata[27:16] = platform_ddr_device_temp;
      end
      ADDR_DDR_DEBUG_CONTROL: begin
        system_debug_rdata[1] = ddr_debug_write_latched;
      end
      ADDR_DDR_DEBUG_STATUS: begin
        system_debug_rdata = {
          26'd0,
          ddr_debug_write_latched,
          ddr_debug_error_latched,
          ddr_debug_done_latched,
          platform_ddr_debug_busy,
          platform_ddr_debug_ready,
          1'b1
        };
      end
      ADDR_DDR_DEBUG_ADDR: system_debug_rdata = platform_ddr_debug_addr;
      ADDR_DDR_DEBUG_BYTE_ENABLE: begin
        system_debug_rdata = {16'd0, platform_ddr_debug_byte_enable};
      end
      ADDR_DDR_DEBUG_DATA0: system_debug_rdata = platform_ddr_debug_rdata[31:0];
      ADDR_DDR_DEBUG_DATA1: system_debug_rdata = platform_ddr_debug_rdata[63:32];
      ADDR_DDR_DEBUG_DATA2: system_debug_rdata = platform_ddr_debug_rdata[95:64];
      ADDR_DDR_DEBUG_DATA3: system_debug_rdata = platform_ddr_debug_rdata[127:96];
      default: system_debug_rdata = 32'd0;
    endcase
  end

  fractional_tick_gen #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .TICK_HZ(SAMPLE_RATE_HZ)
  ) sample_tick_gen (
    .clk,
    .rst(core_reset),
    .tick(sample_tick)
  );

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

      if (system_debug_access && spi_bus_write) begin
        unique case (spi_bus_address)
          ADDR_DDR_DEBUG_CONTROL: begin
            if (spi_bus_wdata[0] && platform_ddr_debug_ready) begin
              platform_ddr_debug_start <= 1'b1;
              platform_ddr_debug_write <= spi_bus_wdata[1];
              ddr_debug_write_latched <= spi_bus_wdata[1];
              ddr_debug_done_latched <= 1'b0;
              ddr_debug_error_latched <= 1'b0;
            end
            if (spi_bus_wdata[2]) begin
              ddr_debug_done_latched <= 1'b0;
              ddr_debug_error_latched <= 1'b0;
            end
          end
          ADDR_DDR_DEBUG_ADDR: platform_ddr_debug_addr <= spi_bus_wdata;
          ADDR_DDR_DEBUG_BYTE_ENABLE: platform_ddr_debug_byte_enable <= spi_bus_wdata[LINE_WORDS*2-1:0];
          ADDR_DDR_DEBUG_DATA0: platform_ddr_debug_wdata[31:0] <= spi_bus_wdata;
          ADDR_DDR_DEBUG_DATA1: platform_ddr_debug_wdata[63:32] <= spi_bus_wdata;
          ADDR_DDR_DEBUG_DATA2: platform_ddr_debug_wdata[95:64] <= spi_bus_wdata;
          ADDR_DDR_DEBUG_DATA3: platform_ddr_debug_wdata[127:96] <= spi_bus_wdata;
          default: begin
          end
        endcase
      end

      if (system_debug_access && spi_bus_write && (spi_bus_address == ADDR_DEBUG_EVENT_FLAGS)) begin
        debug_event_flags <= (debug_event_flags & ~spi_bus_wdata) | debug_event_set_mask;
      end else begin
        debug_event_flags <= debug_event_flags | debug_event_set_mask;
      end

      if (underrun_pulse) begin
        underrun_count <= sat_inc(underrun_count);
      end
      if (sample_drop_pulse) begin
        sample_drop_count <= sat_inc(sample_drop_count);
      end
      if (sample_tick && render_pending && !core_sample_valid) begin
        render_deadline_miss_count <= sat_inc(render_deadline_miss_count);
      end
      if (mem_debug_hit_pulse) begin
        mem_hit_count <= sat_inc(mem_hit_count);
      end
      if (mem_debug_miss_pulse) begin
        mem_miss_count <= sat_inc(mem_miss_count);
      end
      if (mem_debug_response_pulse) begin
        mem_response_count <= sat_inc(mem_response_count);
      end

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

  spi_register_bridge spi_bridge (
    .clk,
    .rst,
    .spi_sclk,
    .spi_cs_n,
    .spi_mosi,
    .spi_miso,
    .spi_error,
    .bus_valid(spi_bus_valid),
    .bus_write(spi_bus_write),
    .bus_address(spi_bus_address),
    .bus_wdata(spi_bus_wdata),
    .bus_rdata(spi_bus_rdata),
    .bus_ready(spi_bus_ready),
    .bus_error(spi_bus_error)
  );

  wavetable_core_memory #(.LINE_WORDS(LINE_WORDS)) core (
    .clk,
    .rst(core_reset),
    .bus_valid(core_bus_valid),
    .bus_write(core_bus_write),
    .bus_address(core_bus_address),
    .bus_wdata(core_bus_wdata),
    .bus_rdata(core_bus_rdata),
    .bus_ready(core_bus_ready),
    .bus_error(core_bus_error),
    .sample_tick,
    .sample_valid(core_sample_valid),
    .sample_l(core_sample_l),
    .sample_r(core_sample_r),
    .busy(core_busy),
    .ext_req_valid,
    .ext_req_ready,
    .ext_req_addr,
    .ext_rsp_valid,
    .ext_rsp_data,
    .mem_debug_hit_pulse,
    .mem_debug_miss_pulse,
    .mem_debug_response_pulse,
    .mem_debug_response_latency
  );

  output_sample_fifo #(.DEPTH(OUTPUT_FIFO_DEPTH)) output_fifo (
    .clk,
    .rst(core_reset),
    .in_valid(core_sample_valid),
    .in_ready(fifo_input_ready),
    .in_l(core_sample_l),
    .in_r(core_sample_r),
    .out_valid(fifo_sample_valid),
    .out_ready(fifo_sample_ready),
    .out_l(fifo_sample_l),
    .out_r(fifo_sample_r),
    .overflow_pulse(sample_drop_pulse),
    .level(output_fifo_level)
  );

  assign fifo_sample_ready = fifo_sample_valid && i2s_sample_ready;

  i2s_tx #(
    .SYS_CLK_HZ(SYS_CLK_HZ),
    .SAMPLE_RATE_HZ(SAMPLE_RATE_HZ)
  ) audio_tx (
    .clk,
    .rst(core_reset),
    .sample_valid(fifo_sample_valid && i2s_sample_ready),
    .sample_ready(i2s_sample_ready),
    .sample_l(fifo_sample_l),
    .sample_r(fifo_sample_r),
    .underrun_pulse,
    .i2s_bclk,
    .i2s_lrclk,
    .i2s_sdata
  );

endmodule
