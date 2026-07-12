module tb_smart_artix_ddr3_asset_writer;
  localparam int MIG_ADDR_WIDTH = 28;
  localparam int MIG_DATA_WIDTH = 128;
  localparam int BEAT_BYTES = MIG_DATA_WIDTH / 8;

  logic clk;
  logic rst;
  logic start;
  logic [63:0] base_byte_addr;
  logic [63:0] total_bytes;
  logic busy;
  logic done_pulse;
  logic error_pulse;
  logic byte_valid;
  logic byte_ready;
  logic [7:0] byte_data;
  logic [MIG_ADDR_WIDTH-1:0] mig_app_addr;
  logic [2:0] mig_app_cmd;
  logic mig_app_en;
  logic mig_app_rdy;
  logic [MIG_DATA_WIDTH-1:0] mig_app_wdf_data;
  logic [BEAT_BYTES-1:0] mig_app_wdf_mask;
  logic mig_app_wdf_wren;
  logic mig_app_wdf_end;
  logic mig_app_wdf_rdy;
  int errors;
  int cmd_seen;
  int wdf_seen;

  smart_artix_ddr3_asset_writer #(
    .MIG_ADDR_WIDTH(MIG_ADDR_WIDTH),
    .MIG_DATA_WIDTH(MIG_DATA_WIDTH)
  ) dut (
    .clk,
    .rst,
    .start,
    .base_byte_addr,
    .total_bytes,
    .busy,
    .done_pulse,
    .error_pulse,
    .byte_valid,
    .byte_ready,
    .byte_data,
    .mig_app_addr,
    .mig_app_cmd,
    .mig_app_en,
    .mig_app_rdy,
    .mig_app_wdf_data,
    .mig_app_wdf_mask,
    .mig_app_wdf_wren,
    .mig_app_wdf_end,
    .mig_app_wdf_rdy
  );

/* verilator lint_off BLKSEQ */
  always #5 clk = ~clk;
/* verilator lint_on BLKSEQ */

/* verilator lint_off BLKSEQ */
  task automatic check(input bit condition, input string message);
    if (!condition) begin
      $error("%s", message);
      errors++;
    end
  endtask
/* verilator lint_on BLKSEQ */

  always_ff @(posedge clk) begin
    if (rst) begin
      cmd_seen <= 0;
      wdf_seen <= 0;
    end else begin
      if (mig_app_en && mig_app_rdy) begin
        cmd_seen <= cmd_seen + 1;
        check(mig_app_cmd == 3'b000, "asset writer used wrong MIG write command");
        if (cmd_seen == 0)
          check(mig_app_addr == MIG_ADDR_WIDTH'(28'h000_0020), "first write address mismatch");
        else if (cmd_seen == 1)
          check(mig_app_addr == MIG_ADDR_WIDTH'(28'h000_0030), "second write address mismatch");
        else
          check(1'b0, "asset writer emitted too many write commands");
      end

      if (mig_app_wdf_wren && mig_app_wdf_rdy) begin
        wdf_seen <= wdf_seen + 1;
        check(mig_app_cmd == 3'b000, "asset writer used wrong MIG write command");
        check(mig_app_wdf_end, "asset writer did not assert wdf_end");

        if (wdf_seen == 0) begin
        check(mig_app_wdf_mask == 16'h0000, "first write mask mismatch");
        check(mig_app_wdf_data[31:0] == 32'h0302_0100, "first write byte order mismatch");
        check(mig_app_wdf_data[119:32] == 88'h0e0d_0c0b_0a09_0807_0605_04,
              "first write middle bytes mismatch");
        check(mig_app_wdf_data[127:120] == 8'h0f, "first write final byte mismatch");
        end else if (wdf_seen == 1) begin
        check(mig_app_wdf_mask == 16'hfff0, "second write partial mask mismatch");
        check(mig_app_wdf_data[31:0] == 32'h1312_1110, "second write byte order mismatch");
        end else begin
          check(1'b0, "asset writer emitted too many write-data beats");
        end
      end
    end
  end

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    start = 1'b0;
    base_byte_addr = 64'd0;
    total_bytes = 64'd0;
    byte_valid = 1'b0;
    byte_data = 8'd0;
    mig_app_rdy = 1'b1;
    mig_app_wdf_rdy = 1'b1;
    errors = 0;

    repeat (3) @(posedge clk);
    rst = 1'b0;
    @(negedge clk);
    base_byte_addr = 64'h20;
    total_bytes = 64'd20;
    start = 1'b1;
    @(negedge clk);
    start = 1'b0;

    for (int i = 0; i < 20; i++) begin
      @(negedge clk);
      byte_data = 8'(i);
      byte_valid = 1'b1;
      wait (byte_ready);
      @(negedge clk);
      byte_valid = 1'b0;
    end

    wait (done_pulse);
    @(posedge clk);
    check(!busy, "asset writer stayed busy after done");
    check(cmd_seen == 2, "asset writer did not emit exactly two write commands");
    check(wdf_seen == 2, "asset writer did not emit exactly two write-data beats");
    check(!error_pulse, "asset writer reported unexpected error");

    @(negedge clk);
    base_byte_addr = 64'h21;
    total_bytes = 64'd1;
    start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    start = 1'b0;
    check(error_pulse, "asset writer did not reject unaligned base address");

    if (errors != 0)
      $fatal(1, "FAIL: smart_artix_ddr3_asset_writer errors=%0d", errors);

    $display("PASS: smart_artix_ddr3_asset_writer");
    $finish;
  end
endmodule
