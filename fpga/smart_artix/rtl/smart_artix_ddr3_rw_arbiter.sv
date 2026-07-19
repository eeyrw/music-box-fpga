module smart_artix_ddr3_rw_arbiter (
  input  logic                      clk,
  input  logic                      rst,

  input  smart_artix_pkg::mig_app_command_t    read_command,
  output smart_artix_pkg::mig_app_response_t   read_response,

  input  smart_artix_pkg::mig_app_command_t    reg_access_command,
  input  smart_artix_pkg::mig_app_write_data_t reg_access_write_data,
  output smart_artix_pkg::mig_app_response_t   reg_access_response,

  input  smart_artix_pkg::mig_app_command_t    write_command,
  input  smart_artix_pkg::mig_app_write_data_t write_data,
  output smart_artix_pkg::mig_app_response_t   write_response,

  output smart_artix_pkg::mig_app_command_t    mig_app_command,
  output smart_artix_pkg::mig_app_write_data_t mig_app_write_data,
  input  smart_artix_pkg::mig_app_response_t   mig_app_response
);
  localparam logic [2:0] MIG_CMD_WRITE = 3'b000;
  localparam logic [2:0] MIG_CMD_READ = 3'b001;

  typedef enum logic [1:0] {
    OWNER_NONE,
    OWNER_READ,
    OWNER_REG_ACCESS,
    OWNER_WRITE
  } owner_t;

  owner_t read_owner;
  owner_t write_owner;
  owner_t cmd_owner;
  owner_t wdf_owner;
  logic write_cmd_sent;
  logic write_wdf_sent;
  logic command_accept;
  logic wdf_accept;
  logic selected_cmd_is_write;
  logic selected_cmd_is_read;
  logic selected_wdf_valid;
  logic write_pair_done;
  logic read_response_done;

  always_comb begin
    cmd_owner = OWNER_NONE;
    if (write_owner != OWNER_NONE) begin
      cmd_owner = write_owner;
    end else if (read_command.en && read_owner == OWNER_NONE) begin
      cmd_owner = OWNER_READ;
    end else if (reg_access_command.en && read_owner == OWNER_NONE) begin
      cmd_owner = OWNER_REG_ACCESS;
    end else if (write_command.en) begin
      cmd_owner = OWNER_WRITE;
    end
  end

  always_comb begin
    unique case (cmd_owner)
      OWNER_READ: mig_app_command = read_command;
      OWNER_REG_ACCESS: mig_app_command = reg_access_command;
      OWNER_WRITE: mig_app_command = write_command;
      default: mig_app_command = '0;
    endcase

    if (write_owner != OWNER_NONE && write_cmd_sent)
      mig_app_command.en = 1'b0;
  end

  always_comb begin
    wdf_owner = OWNER_NONE;
    if (write_owner != OWNER_NONE) begin
      wdf_owner = write_owner;
    end else if (cmd_owner == OWNER_REG_ACCESS && reg_access_command.cmd == MIG_CMD_WRITE && reg_access_write_data.wren) begin
      wdf_owner = OWNER_REG_ACCESS;
    end else if (cmd_owner == OWNER_WRITE && write_command.cmd == MIG_CMD_WRITE && write_data.wren) begin
      wdf_owner = OWNER_WRITE;
    end
  end

  always_comb begin
    unique case (wdf_owner)
      OWNER_REG_ACCESS: mig_app_write_data = reg_access_write_data;
      OWNER_WRITE: mig_app_write_data = write_data;
      default: mig_app_write_data = '0;
    endcase

    if (write_owner != OWNER_NONE && write_wdf_sent)
      mig_app_write_data.wren = 1'b0;
  end

  assign command_accept = mig_app_command.en && mig_app_response.rdy;
  assign wdf_accept = mig_app_write_data.wren && mig_app_response.wdf_rdy;
  assign selected_cmd_is_write = mig_app_command.cmd == MIG_CMD_WRITE;
  assign selected_cmd_is_read = mig_app_command.cmd == MIG_CMD_READ;
  assign selected_wdf_valid = mig_app_write_data.wren;
  assign write_pair_done = ((write_owner != OWNER_NONE) || (selected_cmd_is_write && command_accept)
      || selected_wdf_valid)
      && (write_cmd_sent || (selected_cmd_is_write && command_accept))
      && (write_wdf_sent || wdf_accept);
  assign read_response_done = mig_app_response.rd_data_valid && mig_app_response.rd_data_end;

  always_comb begin
    read_response = '0;
    reg_access_response = '0;
    write_response = '0;

    read_response.rdy = (cmd_owner == OWNER_READ) ? mig_app_response.rdy : 1'b0;
    reg_access_response.rdy = (cmd_owner == OWNER_REG_ACCESS) ? mig_app_response.rdy : 1'b0;
    write_response.rdy = (cmd_owner == OWNER_WRITE) ? mig_app_response.rdy : 1'b0;

    reg_access_response.wdf_rdy = (wdf_owner == OWNER_REG_ACCESS) ? mig_app_response.wdf_rdy : 1'b0;
    write_response.wdf_rdy = (wdf_owner == OWNER_WRITE) ? mig_app_response.wdf_rdy : 1'b0;

    read_response.rd_data = mig_app_response.rd_data;
    reg_access_response.rd_data = mig_app_response.rd_data;
    write_response.rd_data = mig_app_response.rd_data;

    read_response.rd_data_valid = (read_owner == OWNER_READ) ? mig_app_response.rd_data_valid : 1'b0;
    read_response.rd_data_end = (read_owner == OWNER_READ) ? mig_app_response.rd_data_end : 1'b0;
    reg_access_response.rd_data_valid = (read_owner == OWNER_REG_ACCESS) ? mig_app_response.rd_data_valid : 1'b0;
    reg_access_response.rd_data_end = (read_owner == OWNER_REG_ACCESS) ? mig_app_response.rd_data_end : 1'b0;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      read_owner <= OWNER_NONE;
      write_owner <= OWNER_NONE;
      write_cmd_sent <= 1'b0;
      write_wdf_sent <= 1'b0;
    end else begin
      if (command_accept && selected_cmd_is_read)
        read_owner <= cmd_owner;
      if (read_response_done)
        read_owner <= OWNER_NONE;

      if (write_owner == OWNER_NONE) begin
        if (selected_cmd_is_write && command_accept) begin
          write_owner <= cmd_owner;
          write_cmd_sent <= 1'b1;
          write_wdf_sent <= wdf_accept && (wdf_owner == cmd_owner);
        end else if (wdf_accept) begin
          write_owner <= wdf_owner;
          write_cmd_sent <= 1'b0;
          write_wdf_sent <= 1'b1;
        end
      end else begin
        if (selected_cmd_is_write && command_accept)
          write_cmd_sent <= 1'b1;
        if (wdf_accept)
          write_wdf_sent <= 1'b1;
      end

      if (write_pair_done) begin
        write_owner <= OWNER_NONE;
        write_cmd_sent <= 1'b0;
        write_wdf_sent <= 1'b0;
      end
    end
  end
endmodule
