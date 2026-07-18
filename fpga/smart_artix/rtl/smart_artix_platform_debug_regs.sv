module smart_artix_platform_debug_regs (
  input  logic                              clk,
  input  logic                              rst,
  input  logic                              bus_valid,
  input  logic                              bus_write,
  input  logic [15:0]                       bus_address,
  input  logic [31:0]                       bus_wdata,
  output logic                              debug_access,
  output logic [31:0]                       debug_rdata,
  input  smart_artix_pkg::platform_status_t platform_status,
  output smart_artix_pkg::ddr_debug_request_t ddr_debug_request,
  input  smart_artix_pkg::ddr_debug_status_t  ddr_debug_status
);
  import synth_register_pkg::*;

  localparam logic [15:0] ADDR_PLATFORM_STATUS = REG_PLATFORM_STATUS;
  localparam logic [15:0] ADDR_PLATFORM_ERRORS = REG_PLATFORM_ERRORS;
  localparam logic [15:0] ADDR_PLATFORM_BYTES_LOADED = REG_PLATFORM_BYTES_LOADED;
  localparam logic [15:0] ADDR_PLATFORM_SF2_SIZE = REG_PLATFORM_SF2_SIZE;
  localparam logic [15:0] ADDR_PLATFORM_CURRENT_LBA = REG_PLATFORM_CURRENT_LBA;
  localparam logic [15:0] ADDR_PLATFORM_DDR_STATUS = REG_PLATFORM_DDR_STATUS;
  localparam logic [15:0] ADDR_DDR_DEBUG_CONTROL = REG_DDR_DEBUG_CONTROL;
  localparam logic [15:0] ADDR_DDR_DEBUG_STATUS = REG_DDR_DEBUG_STATUS;
  localparam logic [15:0] ADDR_DDR_DEBUG_ADDR = REG_DDR_DEBUG_ADDR;
  localparam logic [15:0] ADDR_DDR_DEBUG_BYTE_ENABLE = REG_DDR_DEBUG_BYTE_ENABLE;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA0 = REG_DDR_DEBUG_DATA0;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA1 = REG_DDR_DEBUG_DATA1;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA2 = REG_DDR_DEBUG_DATA2;
  localparam logic [15:0] ADDR_DDR_DEBUG_DATA3 = REG_DDR_DEBUG_DATA3;

  logic ddr_debug_write_latched;
  logic ddr_debug_done_latched;
  logic ddr_debug_error_latched;

  function automatic logic is_platform_debug_address(input logic [15:0] address);
    unique case (address)
      ADDR_PLATFORM_STATUS, ADDR_PLATFORM_ERRORS, ADDR_PLATFORM_BYTES_LOADED,
      ADDR_PLATFORM_SF2_SIZE, ADDR_PLATFORM_CURRENT_LBA,
      ADDR_PLATFORM_DDR_STATUS, ADDR_DDR_DEBUG_CONTROL,
      ADDR_DDR_DEBUG_STATUS, ADDR_DDR_DEBUG_ADDR,
      ADDR_DDR_DEBUG_BYTE_ENABLE, ADDR_DDR_DEBUG_DATA0,
      ADDR_DDR_DEBUG_DATA1, ADDR_DDR_DEBUG_DATA2,
      ADDR_DDR_DEBUG_DATA3: begin
        is_platform_debug_address = 1'b1;
      end
      default: is_platform_debug_address = 1'b0;
    endcase
  endfunction

  assign debug_access = bus_valid && is_platform_debug_address(bus_address);

  always_comb begin
    debug_rdata = 32'd0;
    unique case (bus_address)
      ADDR_PLATFORM_STATUS: begin
        debug_rdata[0] = 1'b1;
        debug_rdata[1] = (platform_status.sd_error_code != 8'd0) ||
                         (platform_status.loader_error_code != 8'd0);
        debug_rdata[2] = platform_status.ddr_init_calib_complete;
        debug_rdata[3] = platform_status.ddr_ui_rst;
        debug_rdata[4] = platform_status.sd_initialized;
        debug_rdata[5] = platform_status.asset_loaded;
        debug_rdata[6] = platform_status.asset_loader_busy;
        debug_rdata[7] = platform_status.mig_app_rdy;
        debug_rdata[8] = platform_status.mig_app_wdf_rdy;
        debug_rdata[9] = platform_status.mig_app_rd_data_valid;
        debug_rdata[10] = platform_status.mig_app_rd_data_end;
        debug_rdata[14:11] = platform_status.asset_loader_state;
      end
      ADDR_PLATFORM_ERRORS: begin
        debug_rdata = {12'd0, platform_status.asset_loader_state,
                       platform_status.loader_error_code,
                       platform_status.sd_error_code};
      end
      ADDR_PLATFORM_BYTES_LOADED: debug_rdata = platform_status.bytes_loaded;
      ADDR_PLATFORM_SF2_SIZE: debug_rdata = platform_status.sf2_size_bytes;
      ADDR_PLATFORM_CURRENT_LBA: debug_rdata = platform_status.current_lba;
      ADDR_PLATFORM_DDR_STATUS: begin
        debug_rdata[0] = platform_status.ddr_init_calib_complete;
        debug_rdata[1] = platform_status.ddr_ui_rst;
        debug_rdata[2] = platform_status.mig_app_rdy;
        debug_rdata[3] = platform_status.mig_app_wdf_rdy;
        debug_rdata[4] = platform_status.mig_app_rd_data_valid;
        debug_rdata[5] = platform_status.mig_app_rd_data_end;
        debug_rdata[27:16] = platform_status.ddr_device_temp;
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
          ddr_debug_status.busy,
          ddr_debug_status.ready,
          1'b1
        };
      end
      ADDR_DDR_DEBUG_ADDR: debug_rdata = ddr_debug_request.addr;
      ADDR_DDR_DEBUG_BYTE_ENABLE: begin
        debug_rdata = {16'd0, ddr_debug_request.byte_enable};
      end
      ADDR_DDR_DEBUG_DATA0: debug_rdata = ddr_debug_status.rdata[31:0];
      ADDR_DDR_DEBUG_DATA1: debug_rdata = ddr_debug_status.rdata[63:32];
      ADDR_DDR_DEBUG_DATA2: debug_rdata = ddr_debug_status.rdata[95:64];
      ADDR_DDR_DEBUG_DATA3: debug_rdata = ddr_debug_status.rdata[127:96];
      default: debug_rdata = 32'd0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      ddr_debug_request.start <= 1'b0;
      ddr_debug_request.write <= 1'b0;
      ddr_debug_request.addr <= 32'd0;
      ddr_debug_request.wdata <= '0;
      ddr_debug_request.byte_enable <= '1;
      ddr_debug_write_latched <= 1'b0;
      ddr_debug_done_latched <= 1'b0;
      ddr_debug_error_latched <= 1'b0;
    end else begin
      ddr_debug_request.start <= 1'b0;

      if (ddr_debug_status.done)
        ddr_debug_done_latched <= 1'b1;
      if (ddr_debug_status.error)
        ddr_debug_error_latched <= 1'b1;

      if (debug_access && bus_write) begin
        unique case (bus_address)
          ADDR_DDR_DEBUG_CONTROL: begin
            if (bus_wdata[0] && ddr_debug_status.ready) begin
              ddr_debug_request.start <= 1'b1;
              ddr_debug_request.write <= bus_wdata[1];
              ddr_debug_write_latched <= bus_wdata[1];
              ddr_debug_done_latched <= 1'b0;
              ddr_debug_error_latched <= 1'b0;
            end
            if (bus_wdata[2]) begin
              ddr_debug_done_latched <= 1'b0;
              ddr_debug_error_latched <= 1'b0;
            end
          end
          ADDR_DDR_DEBUG_ADDR: ddr_debug_request.addr <= bus_wdata;
          ADDR_DDR_DEBUG_BYTE_ENABLE: begin
            ddr_debug_request.byte_enable <= bus_wdata[smart_artix_pkg::LINE_BYTES-1:0];
          end
          ADDR_DDR_DEBUG_DATA0: ddr_debug_request.wdata[31:0] <= bus_wdata;
          ADDR_DDR_DEBUG_DATA1: ddr_debug_request.wdata[63:32] <= bus_wdata;
          ADDR_DDR_DEBUG_DATA2: ddr_debug_request.wdata[95:64] <= bus_wdata;
          ADDR_DDR_DEBUG_DATA3: ddr_debug_request.wdata[127:96] <= bus_wdata;
          default: begin
          end
        endcase
      end
    end
  end
endmodule
