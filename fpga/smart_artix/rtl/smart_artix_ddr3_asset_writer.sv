module smart_artix_ddr3_asset_writer #(
  parameter int MIG_ADDR_WIDTH = 28,
  parameter int MIG_DATA_WIDTH = 128
) (
  input  logic                      clk,
  input  logic                      rst,

  input  logic                      start,
  input  logic [63:0]               base_byte_addr,
  input  logic [63:0]               total_bytes,
  output logic                      busy,
  output logic                      done_pulse,
  output logic                      error_pulse,

  input  logic                      byte_valid,
  output logic                      byte_ready,
  input  logic [7:0]                byte_data,

  output logic [MIG_ADDR_WIDTH-1:0] mig_app_addr,
  output logic [2:0]                mig_app_cmd,
  output logic                      mig_app_en,
  input  logic                      mig_app_rdy,
  output logic [MIG_DATA_WIDTH-1:0] mig_app_wdf_data,
  output logic [MIG_DATA_WIDTH/8-1:0] mig_app_wdf_mask,
  output logic                      mig_app_wdf_wren,
  output logic                      mig_app_wdf_end,
  input  logic                      mig_app_wdf_rdy
);
  localparam int BEAT_BYTES = MIG_DATA_WIDTH / 8;
  localparam int COUNT_WIDTH = $clog2(BEAT_BYTES + 1);
  localparam logic [2:0] MIG_CMD_WRITE = 3'b000;

  typedef enum logic [1:0] {
    STATE_IDLE,
    STATE_FILL,
    STATE_SEND
  } state_t;

  state_t state;
  logic [MIG_DATA_WIDTH-1:0] data_buffer;
  logic [COUNT_WIDTH-1:0] beat_byte_count;
  logic [63:0] remaining_bytes;
  logic [63:0] current_addr;
  logic cmd_sent;
  logic wdf_sent;
  logic accepted_byte;
  logic send_accepted;
  logic base_aligned;

  assign busy = state != STATE_IDLE;
  assign byte_ready = (state == STATE_FILL) && (remaining_bytes != 64'd0)
      && (beat_byte_count != COUNT_WIDTH'(BEAT_BYTES));
  assign accepted_byte = byte_valid && byte_ready;
  assign send_accepted = (cmd_sent || (mig_app_en && mig_app_rdy))
      && (wdf_sent || (mig_app_wdf_wren && mig_app_wdf_rdy));
  assign base_aligned = base_byte_addr[$clog2(BEAT_BYTES)-1:0] == '0;

  assign mig_app_addr = MIG_ADDR_WIDTH'(current_addr);
  assign mig_app_cmd = MIG_CMD_WRITE;
  assign mig_app_en = (state == STATE_SEND) && !cmd_sent;
  assign mig_app_wdf_data = data_buffer;
  assign mig_app_wdf_wren = (state == STATE_SEND) && !wdf_sent;
  assign mig_app_wdf_end = (state == STATE_SEND) && !wdf_sent;

  always_comb begin
    mig_app_wdf_mask = '1;
    for (int i = 0; i < BEAT_BYTES; i++) begin
      if (i < beat_byte_count)
        mig_app_wdf_mask[i] = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= STATE_IDLE;
      data_buffer <= '0;
      beat_byte_count <= '0;
      remaining_bytes <= '0;
      current_addr <= '0;
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
            if (!base_aligned) begin
              error_pulse <= 1'b1;
            end else if (total_bytes == 64'd0) begin
              done_pulse <= 1'b1;
            end else begin
              data_buffer <= '0;
              beat_byte_count <= '0;
              remaining_bytes <= total_bytes;
              current_addr <= base_byte_addr;
              cmd_sent <= 1'b0;
              wdf_sent <= 1'b0;
              state <= STATE_FILL;
            end
          end
        end

        STATE_FILL: begin
          if (accepted_byte) begin
            data_buffer[beat_byte_count * 8 +: 8] <= byte_data;
            beat_byte_count <= beat_byte_count + COUNT_WIDTH'(1);
            remaining_bytes <= remaining_bytes - 64'd1;

            if ((beat_byte_count == COUNT_WIDTH'(BEAT_BYTES - 1)) || (remaining_bytes == 64'd1))
              begin
                cmd_sent <= 1'b0;
                wdf_sent <= 1'b0;
                state <= STATE_SEND;
              end
          end
        end

        STATE_SEND: begin
          if (mig_app_en && mig_app_rdy)
            cmd_sent <= 1'b1;
          if (mig_app_wdf_wren && mig_app_wdf_rdy)
            wdf_sent <= 1'b1;

          if (send_accepted) begin
            if (remaining_bytes == 64'd0) begin
              done_pulse <= 1'b1;
              state <= STATE_IDLE;
            end else begin
              data_buffer <= '0;
              beat_byte_count <= '0;
              current_addr <= current_addr + 64'(BEAT_BYTES);
              cmd_sent <= 1'b0;
              wdf_sent <= 1'b0;
              state <= STATE_FILL;
            end
          end
        end

        default: state <= STATE_IDLE;
      endcase
    end
  end
endmodule
