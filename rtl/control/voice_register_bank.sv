module voice_register_bank (
  input  logic                       clk,
  input  logic                       rst,
  input  logic                       bus_valid,
  input  logic                       bus_write,
  input  logic [15:0]                bus_address,
  input  logic [31:0]                bus_wdata,
  output logic [31:0]                bus_rdata,
  output logic                       bus_ready,
  output logic                       bus_error,
  output synth_pkg::voice_config_t   active_config,
  output logic                       config_valid,
  output logic                       commit_pulse
);
  import synth_pkg::*;

  localparam logic [15:0] ADDR_CONTROL    = 16'h0100;
  localparam logic [15:0] ADDR_BASE       = 16'h0104;
  localparam logic [15:0] ADDR_LENGTH     = 16'h0108;
  localparam logic [15:0] ADDR_LOOP_START = 16'h010c;
  localparam logic [15:0] ADDR_LOOP_END   = 16'h0110;
  localparam logic [15:0] ADDR_PHASE_INIT = 16'h0114;
  localparam logic [15:0] ADDR_PHASE_INC  = 16'h0118;
  localparam logic [15:0] ADDR_GAIN_L     = 16'h011c;
  localparam logic [15:0] ADDR_GAIN_R     = 16'h0120;
  localparam logic [15:0] ADDR_COMMIT     = 16'h0124;
  localparam logic [15:0] ADDR_STATUS     = 16'h0128;
  localparam logic [15:0] ADDR_VERSION    = 16'h3000;

  voice_config_t shadow_config;
  logic address_valid;

  always_comb begin
    config_valid = (active_config.length != 16'd0) &&
                   (active_config.loop_start < active_config.loop_end) &&
                   (active_config.loop_end <= active_config.length);

    address_valid = 1'b1;
    bus_rdata = 32'd0;
    unique case (bus_address)
      ADDR_CONTROL:    bus_rdata = {30'd0, shadow_config.stereo, shadow_config.enable};
      ADDR_BASE:       bus_rdata = shadow_config.base_addr;
      ADDR_LENGTH:     bus_rdata = {16'd0, shadow_config.length};
      ADDR_LOOP_START: bus_rdata = {16'd0, shadow_config.loop_start};
      ADDR_LOOP_END:   bus_rdata = {16'd0, shadow_config.loop_end};
      ADDR_PHASE_INIT: bus_rdata = shadow_config.phase_init;
      ADDR_PHASE_INC:  bus_rdata = shadow_config.phase_inc;
      ADDR_GAIN_L:     bus_rdata = {{16{shadow_config.gain_l[15]}}, shadow_config.gain_l};
      ADDR_GAIN_R:     bus_rdata = {{16{shadow_config.gain_r[15]}}, shadow_config.gain_r};
      ADDR_COMMIT:     bus_rdata = 32'd0;
      ADDR_STATUS:     bus_rdata = {31'd0, config_valid};
      ADDR_VERSION:    bus_rdata = 32'h0001_0000;
      default: begin
        address_valid = 1'b0;
        bus_rdata = 32'd0;
      end
    endcase

    bus_ready = bus_valid;
    bus_error = bus_valid && !address_valid;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      shadow_config <= '0;
      active_config <= '0;
      commit_pulse <= 1'b0;
    end else begin
      commit_pulse <= 1'b0;
      if (bus_valid && bus_write && address_valid) begin
        unique case (bus_address)
          ADDR_CONTROL: begin
            shadow_config.enable <= bus_wdata[0];
            shadow_config.stereo <= bus_wdata[1];
          end
          ADDR_BASE:       shadow_config.base_addr <= bus_wdata;
          ADDR_LENGTH:     shadow_config.length <= bus_wdata[15:0];
          ADDR_LOOP_START: shadow_config.loop_start <= bus_wdata[15:0];
          ADDR_LOOP_END:   shadow_config.loop_end <= bus_wdata[15:0];
          ADDR_PHASE_INIT: shadow_config.phase_init <= bus_wdata;
          ADDR_PHASE_INC:  shadow_config.phase_inc <= bus_wdata;
          ADDR_GAIN_L:     shadow_config.gain_l <= $signed(bus_wdata[15:0]);
          ADDR_GAIN_R:     shadow_config.gain_r <= $signed(bus_wdata[15:0]);
          ADDR_COMMIT: begin
            if (bus_wdata[0]) begin
              active_config <= shadow_config;
              commit_pulse <= 1'b1;
            end
          end
          default: begin
          end
        endcase
      end
    end
  end
endmodule
