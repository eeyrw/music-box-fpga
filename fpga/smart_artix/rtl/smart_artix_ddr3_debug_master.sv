module smart_artix_ddr3_debug_master #(
  parameter int MIG_ADDR_WIDTH = 28,
  parameter int MIG_DATA_WIDTH = 128
) (
  input  logic                         clk,
  input  logic                         rst,

  input  logic                         start,
  input  logic                         write,
  input  logic [31:0]                  byte_addr,
  input  logic [MIG_DATA_WIDTH-1:0]    wdata,
  input  logic [MIG_DATA_WIDTH/8-1:0]  byte_enable,
  output logic                         ready,
  output logic                         busy,
  output logic                         done_pulse,
  output logic                         error_pulse,
  output logic [MIG_DATA_WIDTH-1:0]    rdata,

  output logic [MIG_ADDR_WIDTH-1:0]    mig_app_addr,
  output logic [2:0]                   mig_app_cmd,
  output logic                         mig_app_en,
  input  logic                         mig_app_rdy,
  input  logic [MIG_DATA_WIDTH-1:0]    mig_app_rd_data,
  input  logic                         mig_app_rd_data_valid,
  input  logic                         mig_app_rd_data_end,
  output logic [MIG_DATA_WIDTH-1:0]    mig_app_wdf_data,
  output logic [MIG_DATA_WIDTH/8-1:0]  mig_app_wdf_mask,
  output logic                         mig_app_wdf_wren,
  output logic                         mig_app_wdf_end,
  input  logic                         mig_app_wdf_rdy
);
  localparam int BEAT_BYTES = MIG_DATA_WIDTH / 8;
  localparam int ALIGN_BITS = $clog2(BEAT_BYTES);
  localparam logic [2:0] MIG_CMD_WRITE = 3'b000;
  localparam logic [2:0] MIG_CMD_READ = 3'b001;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_WRITE,
    STATE_READ_CMD,
    STATE_READ_DATA
  } state_t;

  state_t state;
  logic [MIG_ADDR_WIDTH-1:0] addr_latched;
  logic [MIG_DATA_WIDTH-1:0] wdata_latched;
  logic [MIG_DATA_WIDTH/8-1:0] mask_latched;
  logic cmd_sent;
  logic wdf_sent;
  logic addr_aligned;
  logic addr_in_range;
  logic write_has_enabled_byte;
  logic write_accepted;

  assign ready = state == STATE_IDLE;
  assign busy = state != STATE_IDLE;
  assign addr_aligned = byte_addr[ALIGN_BITS-1:0] == '0;
  assign addr_in_range = (byte_addr >> MIG_ADDR_WIDTH) == 32'd0;
  assign write_has_enabled_byte = |byte_enable;
  assign write_accepted = (cmd_sent || (mig_app_en && mig_app_rdy))
      && (wdf_sent || (mig_app_wdf_wren && mig_app_wdf_rdy));

  assign mig_app_addr = addr_latched;
  assign mig_app_cmd = (state == STATE_READ_CMD) ? MIG_CMD_READ : MIG_CMD_WRITE;
  assign mig_app_en = (state == STATE_WRITE && !cmd_sent) || (state == STATE_READ_CMD);
  assign mig_app_wdf_data = wdata_latched;
  assign mig_app_wdf_mask = mask_latched;
  assign mig_app_wdf_wren = (state == STATE_WRITE) && !wdf_sent;
  assign mig_app_wdf_end = mig_app_wdf_wren;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      addr_latched <= '0;
      wdata_latched <= '0;
      mask_latched <= '1;
      rdata <= '0;
      cmd_sent <= 1'b0;
      wdf_sent <= 1'b0;
      done_pulse <= 1'b0;
      error_pulse <= 1'b0;
    end else begin
      done_pulse <= 1'b0;
      error_pulse <= 1'b0;

      unique case (state)
        STATE_IDLE: begin
          if (start) begin
            if (!addr_aligned || !addr_in_range || (write && !write_has_enabled_byte)) begin
              error_pulse <= 1'b1;
            end else begin
              addr_latched <= MIG_ADDR_WIDTH'(byte_addr);
              wdata_latched <= wdata;
              mask_latched <= ~byte_enable;
              cmd_sent <= 1'b0;
              wdf_sent <= 1'b0;
              state <= write ? STATE_WRITE : STATE_READ_CMD;
            end
          end
        end

        STATE_WRITE: begin
          if (mig_app_en && mig_app_rdy)
            cmd_sent <= 1'b1;
          if (mig_app_wdf_wren && mig_app_wdf_rdy)
            wdf_sent <= 1'b1;
          if (write_accepted) begin
            done_pulse <= 1'b1;
            state <= STATE_IDLE;
          end
        end

        STATE_READ_CMD: begin
          if (mig_app_rdy)
            state <= STATE_READ_DATA;
        end

        STATE_READ_DATA: begin
          if (mig_app_rd_data_valid) begin
            rdata <= mig_app_rd_data;
            if (mig_app_rd_data_end) begin
              done_pulse <= 1'b1;
              state <= STATE_IDLE;
            end
          end
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end
endmodule
