module tb_wavetable_register_fabric;
  import synth_register_pkg::*;

  synth_pkg::reg_bus_req_t master_req;
  logic core_reset;
  synth_pkg::reg_bus_rsp_t master_rsp;
  synth_pkg::reg_bus_req_t core_req;
  synth_pkg::reg_bus_rsp_t core_rsp;
  synth_pkg::reg_bus_req_t common_status_req;
  synth_pkg::reg_bus_rsp_t common_status_rsp;
  synth_pkg::reg_bus_req_t platform_regs_req;
  synth_pkg::reg_bus_rsp_t platform_regs_rsp;

  synth_pkg::reg_bus_rsp_t absent_master_rsp;
  synth_pkg::reg_bus_req_t absent_core_req;
  synth_pkg::reg_bus_req_t absent_common_status_req;
  synth_pkg::reg_bus_req_t absent_platform_regs_req;

  int errors;

  wavetable_register_fabric #(
    .PLATFORM_REGS_PRESENT(1'b1)
  ) dut (
    .master_req,
    .core_reset,
    .master_rsp,
    .core_req,
    .core_rsp,
    .common_status_req,
    .common_status_rsp,
    .platform_regs_req,
    .platform_regs_rsp
  );

  wavetable_register_fabric #(
    .PLATFORM_REGS_PRESENT(1'b0)
  ) dut_platform_absent (
    .master_req,
    .core_reset,
    .master_rsp(absent_master_rsp),
    .core_req(absent_core_req),
    .core_rsp,
    .common_status_req(absent_common_status_req),
    .common_status_rsp,
    .platform_regs_req(absent_platform_regs_req),
    .platform_regs_rsp
  );

  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask

  task automatic drive_request(
    input logic [15:0] address,
    input logic write,
    input logic [31:0] wdata
  );
    master_req.valid = 1'b1;
    master_req.write = write;
    master_req.address = address;
    master_req.wdata = wdata;
    #1;
  endtask

  initial begin
    master_req = '0;
    core_reset = 1'b1;
    core_rsp = '{rdata: 32'hc012_0001, ready: 1'b1, error: 1'b0};
    common_status_rsp = '{rdata: 32'hc022_0002, ready: 1'b1, error: 1'b0};
    platform_regs_rsp = '{rdata: 32'hc032_0003, ready: 1'b1, error: 1'b0};
    errors = 0;
    #1;

    check(!core_req.valid && !common_status_req.valid && !platform_regs_req.valid,
          "idle request unexpectedly reached a target");
    check(master_rsp == '0, "idle master response was not zero");

    drive_request(REG_VERSION, 1'b0, 32'h0000_0000);
    check(core_req === master_req,
          "REG_VERSION request did not reach core unchanged during reset");
    check(!common_status_req.valid && !platform_regs_req.valid,
          "REG_VERSION selected more than the core target");
    check(master_rsp === core_rsp,
          "REG_VERSION response did not return from core during reset");
    check(master_rsp.ready && !master_rsp.error &&
          master_rsp.rdata == 32'hc012_0001,
          "REG_VERSION was not readable during reset");

    drive_request(REG_CURRENT_SAMPLE, 1'b0, 32'h0000_0000);
    check(!core_req.valid,
          "non-reset-safe core request reached core during reset");
    check(!common_status_req.valid && !platform_regs_req.valid,
          "suppressed core request selected another target");
    check(master_rsp.ready && master_rsp.error && master_rsp.rdata == 32'd0,
          "suppressed core request did not return an immediate bus error");

    drive_request(REG_SYSTEM_STATUS, 1'b0, 32'h0000_0000);
    check(common_status_req === master_req,
          "common-status request did not reach common registers during core reset");
    check(!core_req.valid && !platform_regs_req.valid,
          "common-status request selected more than one target");
    check(master_rsp === common_status_rsp,
          "common-status response was not routed to master");
    check(absent_common_status_req === master_req,
          "platform parameter changed common-status routing");

    drive_request(REG_PLATFORM_STATUS, 1'b0, 32'h0000_0000);
    check(platform_regs_req === master_req,
          "platform request did not reach present platform registers");
    check(!core_req.valid && !common_status_req.valid,
          "platform request selected more than one target");
    check(master_rsp === platform_regs_rsp,
          "present platform response was not routed to master");
    check(!absent_platform_regs_req.valid,
          "platform request reached registers declared absent");
    check(absent_platform_regs_req.write == master_req.write &&
          absent_platform_regs_req.address == master_req.address &&
          absent_platform_regs_req.wdata == master_req.wdata,
          "absent platform target did not preserve request payload");
    check(absent_master_rsp.ready && absent_master_rsp.error &&
          absent_master_rsp.rdata == 32'd0,
          "absent platform request did not return an immediate bus error");

    core_reset = 1'b0;
    drive_request(REG_CURRENT_SAMPLE, 1'b1, 32'h5a5a_a5a5);
    check(core_req === master_req,
          "ordinary core request did not recover after reset release");
    check(master_rsp === core_rsp,
          "ordinary core response was not routed after reset release");
    check(absent_core_req === master_req,
          "platform parameter changed ordinary core routing");

    master_req = '0;
    #1;
    check(!core_req.valid && !common_status_req.valid && !platform_regs_req.valid,
          "target request remained valid after master request ended");

    if (errors != 0)
      $fatal(1, "FAIL: wavetable_register_fabric errors=%0d", errors);

    $display("PASS: wavetable_register_fabric");
    $finish;
  end
endmodule
