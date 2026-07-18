module smart_artix_ddr3_debug_master (
  input  logic                         clk,
  input  logic                         rst,

  input  logic                         start,
  input  logic                         write,
  input  logic [31:0]                  byte_addr,
  input  logic [smart_artix_pkg::MIG_DATA_WIDTH-1:0] wdata,
  input  logic [smart_artix_pkg::MIG_MASK_WIDTH-1:0] byte_enable,
  output logic                         ready,
  output logic                         busy,
  output logic                         done_pulse,
  output logic                         error_pulse,
  output logic [smart_artix_pkg::MIG_DATA_WIDTH-1:0] rdata,

  output smart_artix_pkg::mig_app_command_t    mig_app_command,
  output smart_artix_pkg::mig_app_write_data_t mig_app_write_data,
  input  smart_artix_pkg::mig_app_response_t   mig_app_response
);
  localparam int BEAT_BYTES = smart_artix_pkg::MIG_MASK_WIDTH;
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
  logic [smart_artix_pkg::MIG_ADDR_WIDTH-1:0] addr_latched;
  logic [smart_artix_pkg::MIG_DATA_WIDTH-1:0] wdata_latched;
  logic [smart_artix_pkg::MIG_MASK_WIDTH-1:0] mask_latched;
  logic cmd_sent;
  logic wdf_sent;
  logic addr_aligned;
  logic addr_in_range;
  logic write_has_enabled_byte;
  logic write_accepted;
  logic write_data_wren;

  assign ready = state == STATE_IDLE;
  assign busy = state != STATE_IDLE;
  assign addr_aligned = byte_addr[ALIGN_BITS-1:0] == '0;
  assign addr_in_range = (byte_addr >> smart_artix_pkg::MIG_ADDR_WIDTH) == 32'd0;
  assign write_has_enabled_byte = |byte_enable;
  assign write_accepted = (cmd_sent || (mig_app_command.en && mig_app_response.rdy))
      && (wdf_sent || (write_data_wren && mig_app_response.wdf_rdy));

  assign mig_app_command.addr = addr_latched;
  assign mig_app_command.cmd = (state == STATE_READ_CMD) ? MIG_CMD_READ : MIG_CMD_WRITE;
  assign mig_app_command.en = (state == STATE_WRITE && !cmd_sent) || (state == STATE_READ_CMD);
  assign write_data_wren = (state == STATE_WRITE) && !wdf_sent;
  assign mig_app_write_data.data = wdata_latched;
  assign mig_app_write_data.mask = mask_latched;
  assign mig_app_write_data.wren = write_data_wren;
  assign mig_app_write_data.end_ = write_data_wren;

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
              addr_latched <= smart_artix_pkg::MIG_ADDR_WIDTH'(byte_addr);
              wdata_latched <= wdata;
              mask_latched <= ~byte_enable;
              cmd_sent <= 1'b0;
              wdf_sent <= 1'b0;
              state <= write ? STATE_WRITE : STATE_READ_CMD;
            end
          end
        end

        STATE_WRITE: begin
          if (mig_app_command.en && mig_app_response.rdy)
            cmd_sent <= 1'b1;
          if (write_data_wren && mig_app_response.wdf_rdy)
            wdf_sent <= 1'b1;
          if (write_accepted) begin
            done_pulse <= 1'b1;
            state <= STATE_IDLE;
          end
        end

        STATE_READ_CMD: begin
          if (mig_app_response.rdy)
            state <= STATE_READ_DATA;
        end

        STATE_READ_DATA: begin
          if (mig_app_response.rd_data_valid) begin
            rdata <= mig_app_response.rd_data;
            if (mig_app_response.rd_data_end) begin
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
