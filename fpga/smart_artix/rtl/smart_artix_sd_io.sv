module smart_artix_sd_io (
  input  logic       clk,
  input  logic       rst,
  input  logic       sd_clk_o,
  input  logic       sd_cmd_o,
  input  logic       sd_cmd_oe,
  output logic       sd_cmd_i,
  output logic [3:0] sd_dat_i,
  output wire        sd_clk,
  inout  wire        sd_cmd,
  input  wire  [3:0] sd_dat
);
`ifdef SYNTHESIS
  wire sd_cmd_pin_i;
  wire [3:0] sd_dat_pin_i;
  (* IOB = "TRUE" *) logic sd_cmd_i_q;
  (* IOB = "TRUE" *) logic [3:0] sd_dat_i_q;

  OBUF sd_clk_obuf (
    .I(sd_clk_o),
    .O(sd_clk)
  );

  IOBUF sd_cmd_iobuf (
    .I(sd_cmd_o),
    .T(!sd_cmd_oe),
    .O(sd_cmd_pin_i),
    .IO(sd_cmd)
  );

  assign sd_cmd_i = sd_cmd_i_q;
  assign sd_dat_i = sd_dat_i_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      sd_cmd_i_q <= 1'b1;
      sd_dat_i_q <= 4'hf;
    end else begin
      sd_cmd_i_q <= sd_cmd_pin_i;
      sd_dat_i_q <= sd_dat_pin_i;
    end
  end

  for (genvar line = 0; line < 4; line++) begin : sd_dat_input
    IBUF sd_dat_ibuf (
      .I(sd_dat[line]),
      .O(sd_dat_pin_i[line])
    );

  end
`else
  assign sd_clk = sd_clk_o;
  assign sd_cmd = sd_cmd_oe ? sd_cmd_o : 1'bz;

  always_ff @(posedge clk) begin
    if (rst) begin
      sd_cmd_i <= 1'b1;
      sd_dat_i <= 4'hf;
    end else begin
      sd_cmd_i <= sd_cmd;
      sd_dat_i <= sd_dat;
    end
  end
`endif
endmodule
