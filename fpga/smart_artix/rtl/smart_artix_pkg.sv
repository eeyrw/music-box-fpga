package smart_artix_pkg;
  localparam int LINE_WORDS = 8;
  localparam int LINE_BITS = LINE_WORDS * 16;
  localparam int LINE_BYTES = LINE_WORDS * 2;
  localparam int MIG_ADDR_WIDTH = 29;
  localparam int MIG_DATA_WIDTH = LINE_BITS;
  localparam int MIG_MASK_WIDTH = MIG_DATA_WIDTH / 8;

  typedef struct packed {
    logic                  valid;
    logic [31:0]           addr;
  } line_read_request_t;

  typedef struct packed {
    logic                  valid;
    logic [LINE_BITS-1:0]  data;
  } line_read_response_t;

  typedef struct packed {
    logic [MIG_ADDR_WIDTH-1:0] addr;
    logic [2:0]                cmd;
    logic                      en;
  } mig_app_command_t;

  typedef struct packed {
    logic [MIG_DATA_WIDTH-1:0] data;
    logic [MIG_MASK_WIDTH-1:0] mask;
    logic                      wren;
    logic                      end_;
  } mig_app_write_data_t;

  typedef struct packed {
    logic                      rdy;
    logic                      wdf_rdy;
    logic [MIG_DATA_WIDTH-1:0] rd_data;
    logic                      rd_data_valid;
    logic                      rd_data_end;
  } mig_app_response_t;

  typedef struct packed {
    logic        ddr_init_calib_complete;
    logic        ddr_ui_rst;
    logic [11:0] ddr_device_temp;
    logic        mig_app_rdy;
    logic        mig_app_wdf_rdy;
    logic        mig_app_rd_data_valid;
    logic        mig_app_rd_data_end;
    logic        sd_initialized;
    logic        asset_loaded;
    logic        asset_loader_busy;
    logic [3:0]  asset_loader_state;
    logic [7:0]  sd_error_code;
    logic [7:0]  loader_error_code;
    logic [31:0] bytes_loaded;
    logic [31:0] sf2_size_bytes;
    logic [31:0] current_lba;
  } platform_status_t;

  typedef struct packed {
    logic                 start;
    logic                 write;
    logic [31:0]          addr;
    logic [LINE_BITS-1:0] wdata;
    logic [LINE_BYTES-1:0] byte_enable;
  } ddr_reg_access_request_t;

  typedef struct packed {
    logic                 ready;
    logic                 busy;
    logic                 done;
    logic                 error;
    logic [LINE_BITS-1:0] rdata;
  } ddr_reg_access_status_t;
endpackage
