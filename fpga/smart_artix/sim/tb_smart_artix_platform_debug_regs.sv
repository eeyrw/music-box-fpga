module tb_smart_artix_platform_debug_regs;
  import synth_register_pkg::*;

  logic clk;
  logic rst;
  logic bus_valid;
  logic bus_write;
  logic [15:0] bus_address;
  logic [31:0] bus_wdata;
  logic debug_access;
  logic [31:0] debug_rdata;
  smart_artix_pkg::platform_status_t platform_status;
  smart_artix_pkg::ddr_debug_request_t ddr_debug_request;
  smart_artix_pkg::ddr_debug_status_t ddr_debug_status;
  int errors;

  smart_artix_platform_debug_regs dut (
    .clk,
    .rst,
    .bus_valid,
    .bus_write,
    .bus_address,
    .bus_wdata,
    .debug_access,
    .debug_rdata,
    .platform_status,
    .ddr_debug_request,
    .ddr_debug_status
  );

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
/* verilator lint_on BLKSEQ */

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask

  task automatic write_reg(input logic [15:0] address, input logic [31:0] data);
    @(negedge clk);
    bus_valid = 1'b1;
    bus_write = 1'b1;
    bus_address = address;
    bus_wdata = data;
    @(negedge clk);
    bus_valid = 1'b0;
    bus_write = 1'b0;
    bus_address = 16'd0;
    bus_wdata = 32'd0;
  endtask

  task automatic expect_read(input logic [15:0] address, input logic [31:0] expected);
    @(negedge clk);
    bus_valid = 1'b1;
    bus_write = 1'b0;
    bus_address = address;
    bus_wdata = 32'd0;
    #1;
    check(debug_access, "platform debug access not detected");
    if (debug_rdata !== expected) begin
      $error("platform debug read 0x%04x got 0x%08x expected 0x%08x",
             address, debug_rdata, expected);
      errors++;
    end
    @(negedge clk);
    bus_valid = 1'b0;
    bus_address = 16'd0;
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    bus_valid = 1'b0;
    bus_write = 1'b0;
    bus_address = 16'd0;
    bus_wdata = 32'd0;
    platform_status = '0;
    ddr_debug_status = '0;
    ddr_debug_status.ready = 1'b1;
    ddr_debug_status.rdata = 128'hfedc_ba98_7654_3210_89ab_cdef_0123_4567;
    errors = 0;

    platform_status.ddr_init_calib_complete = 1'b1;
    platform_status.ddr_ui_rst = 1'b0;
    platform_status.ddr_device_temp = 12'h2a5;
    platform_status.mig_app_rdy = 1'b1;
    platform_status.mig_app_wdf_rdy = 1'b0;
    platform_status.mig_app_rd_data_valid = 1'b1;
    platform_status.mig_app_rd_data_end = 1'b0;
    platform_status.sd_initialized = 1'b1;
    platform_status.asset_loaded = 1'b1;
    platform_status.asset_loader_busy = 1'b0;
    platform_status.asset_loader_state = 4'ha;
    platform_status.sd_error_code = 8'h12;
    platform_status.loader_error_code = 8'h34;
    platform_status.bytes_loaded = 32'h5566_7788;
    platform_status.sf2_size_bytes = 32'hddee_ff00;
    platform_status.current_lba = 32'h1234_5678;

    repeat (2) @(posedge clk);
    rst = 1'b0;

    expect_read(REG_PLATFORM_STATUS, 32'h0000_52b7);
    expect_read(REG_PLATFORM_ERRORS, 32'h000a_3412);
    expect_read(REG_PLATFORM_BYTES_LOADED, 32'h5566_7788);
    expect_read(REG_PLATFORM_SF2_SIZE, 32'hddee_ff00);
    expect_read(REG_PLATFORM_CURRENT_LBA, 32'h1234_5678);
    expect_read(REG_PLATFORM_DDR_STATUS, 32'h02a5_0015);
    expect_read(REG_DDR_DEBUG_STATUS, 32'h0000_0003);

    write_reg(REG_DDR_DEBUG_ADDR, 32'h0000_0100);
    write_reg(REG_DDR_DEBUG_BYTE_ENABLE, 32'h0000_00ff);
    write_reg(REG_DDR_DEBUG_DATA0, 32'h0123_4567);
    write_reg(REG_DDR_DEBUG_DATA1, 32'h89ab_cdef);
    write_reg(REG_DDR_DEBUG_DATA2, 32'h7654_3210);
    write_reg(REG_DDR_DEBUG_DATA3, 32'hfedc_ba98);
    write_reg(REG_DDR_DEBUG_CONTROL,
              REG_DDR_DEBUG_CONTROL_START_MASK | REG_DDR_DEBUG_CONTROL_WRITE_MASK);
    #1;
    check(ddr_debug_request.start, "DDR debug start pulse missing");
    check(ddr_debug_request.write, "DDR debug write bit missing");
    check(ddr_debug_request.addr == 32'h0000_0100, "DDR debug address mismatch");
    check(ddr_debug_request.byte_enable == 16'h00ff, "DDR debug byte-enable mismatch");
    check(ddr_debug_request.wdata == 128'hfedc_ba98_7654_3210_89ab_cdef_0123_4567,
          "DDR debug write data mismatch");

    ddr_debug_status.ready = 1'b0;
    ddr_debug_status.busy = 1'b1;
    expect_read(REG_DDR_DEBUG_STATUS, 32'h0000_0025);
    ddr_debug_status.ready = 1'b1;
    ddr_debug_status.busy = 1'b0;
    ddr_debug_status.done = 1'b1;
    @(negedge clk);
    ddr_debug_status.done = 1'b0;
    expect_read(REG_DDR_DEBUG_STATUS, 32'h0000_002b);
    expect_read(REG_DDR_DEBUG_DATA0, 32'h0123_4567);
    expect_read(REG_DDR_DEBUG_DATA1, 32'h89ab_cdef);
    expect_read(REG_DDR_DEBUG_DATA2, 32'h7654_3210);
    expect_read(REG_DDR_DEBUG_DATA3, 32'hfedc_ba98);
    write_reg(REG_DDR_DEBUG_CONTROL, REG_DDR_DEBUG_CONTROL_CLEAR_MASK);
    expect_read(REG_DDR_DEBUG_STATUS, 32'h0000_0023);

    bus_valid = 1'b1;
    bus_write = 1'b0;
    bus_address = REG_VERSION;
    #1;
    check(!debug_access, "platform debug claimed a core register address");
    bus_valid = 1'b0;

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_platform_debug_regs errors=%0d", errors);

    $display("PASS: smart_artix_platform_debug_regs");
    $finish;
  end
endmodule
