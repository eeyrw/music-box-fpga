module smart_artix_voice_major_synth_top (
  input  logic                                      clk_in,
  input  logic                                      rst_n,

  inout  wire [15:0]                                ddr3_dq,
  inout  wire [1:0]                                 ddr3_dqs_n,
  inout  wire [1:0]                                 ddr3_dqs_p,
  output logic [14:0]                               ddr3_addr,
  output logic [2:0]                                ddr3_ba,
  output logic                                      ddr3_ras_n,
  output logic                                      ddr3_cas_n,
  output logic                                      ddr3_we_n,
  output logic                                      ddr3_reset_n,
  output logic [0:0]                                ddr3_ck_p,
  output logic [0:0]                                ddr3_ck_n,
  output logic [0:0]                                ddr3_cke,
  output logic [1:0]                                ddr3_dm,
  output logic [0:0]                                ddr3_odt,

  output logic                                      sd_clk,
  inout  wire                                       sd_cmd,
  input  logic [3:0]                                sd_dat,
  input  logic                                      sd_cd_n,

  input  logic                                      install_valid,
  output logic                                      install_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      install_voice,
  input  synth_pkg::block_voice_state_snapshot_t   install_state,
  input  logic                                      params_write_valid,
  output logic                                      params_write_ready,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]      params_write_voice,
  input  logic [synth_pkg::VOICE_GENERATION_WIDTH-1:0]
                                                    params_write_generation,
  input  synth_pkg::voice_event_params_t            params_write_event,
  input  synth_pkg::volume_env_params_t             params_write_env,
  output logic                                      stale_params_write_pulse,
  output logic                                      stale_dynamic_write_pulse,
  input  logic                                      block_req_valid,
  output logic                                      block_req_ready,
  input  synth_pkg::render_block_req_t              block_req,
  output logic                                      render_busy,
  output logic                                      block_complete_valid,
  input  logic                                      block_complete_ready,
  output synth_pkg::render_block_complete_t         block_complete,
  input  logic                                      block_read_req_valid,
  output logic                                      block_read_req_ready,
  input  synth_pkg::render_block_read_req_t         block_read_req,
  output logic                                      block_read_rsp_valid,
  input  logic                                      block_read_rsp_ready,
  output synth_pkg::render_block_read_rsp_t         block_read_rsp,
  input  logic                                      block_release_valid,
  output logic                                      block_release_ready,
  input  logic [synth_pkg::BLOCK_BUFFER_ID_WIDTH-1:0]
                                                    block_release_buffer_id,
  output logic                                      asset_loaded
);
  localparam int SD_DIV_WIDTH = 16;

  logic clk;
  logic rst;
  logic clk_mig_200m;
  logic mig_ui_clk;
  logic mig_ui_clk_sync_rst;
  logic mig_init_calib_complete;
  logic core_rst;
  logic sd_cmd_o;
  logic sd_cmd_oe;

  logic line_req_valid;
  logic line_req_ready;
  synth_pkg::ordered_line_req_t line_req;
  logic line_rsp_valid;
  logic line_rsp_ready;
  synth_pkg::ordered_line_rsp_t line_rsp;
  smart_artix_pkg::line_read_request_t board_line_req;
  smart_artix_pkg::line_read_response_t board_line_rsp;
  logic board_line_req_ready;
  logic board_rsp_valid_q;
  logic [smart_artix_pkg::LINE_BITS-1:0] board_rsp_data_q;

  smart_artix_pkg::mig_app_command_t mig_app_command;
  smart_artix_pkg::mig_app_write_data_t mig_app_write_data;
  smart_artix_pkg::mig_app_response_t mig_app_response;
  smart_artix_pkg::platform_status_t platform_status;
  smart_artix_pkg::ddr_reg_access_request_t ddr_reg_access_request;
  smart_artix_pkg::ddr_reg_access_status_t ddr_reg_access_status;
  logic [11:0] mig_device_temp;
  logic mig_app_sr_active;
  logic mig_app_ref_ack;
  logic mig_app_zq_ack;

  assign clk = mig_ui_clk;
  assign core_rst = mig_ui_clk_sync_rst || !mig_init_calib_complete ||
      !platform_status.asset_loaded;
  assign rst = core_rst;
  assign asset_loaded = platform_status.asset_loaded;
  assign sd_cmd = sd_cmd_oe ? sd_cmd_o : 1'bz;

  // The board line reader has no response backpressure. Hold its pulse until
  // the generic ordered-line consumer accepts it.
  assign board_line_req.valid = line_req_valid &&
      (!board_rsp_valid_q || line_rsp_ready);
  assign board_line_req.addr = line_req.aligned_line_addr;
  assign line_req_ready = board_line_req_ready &&
      (!board_rsp_valid_q || line_rsp_ready);
  assign line_rsp_valid = board_rsp_valid_q;
  assign line_rsp.words = board_rsp_data_q;

  always_ff @(posedge mig_ui_clk) begin
    if (core_rst) begin
      board_rsp_valid_q <= 1'b0;
    end else begin
      if (line_rsp_ready)
        board_rsp_valid_q <= 1'b0;
      if (board_line_rsp.valid) begin
        board_rsp_valid_q <= 1'b1;
        board_rsp_data_q <= board_line_rsp.data;
      end
    end
  end

  assign ddr_reg_access_request = '0;

  smart_artix_clk_50m_to_200m board_clock_generator (
    .clk_out1(clk_mig_200m),
    .resetn(rst_n),
    .clk_in1(clk_in)
  );

  smart_artix_ddr3_mig ddr3_memory_controller (
    .ddr3_dq,
    .ddr3_dqs_n,
    .ddr3_dqs_p,
    .ddr3_addr,
    .ddr3_ba,
    .ddr3_ras_n,
    .ddr3_cas_n,
    .ddr3_we_n,
    .ddr3_reset_n,
    .ddr3_ck_p,
    .ddr3_ck_n,
    .ddr3_cke,
    .ddr3_dm,
    .ddr3_odt,
    .sys_clk_i(clk_mig_200m),
    .app_addr(mig_app_command.addr),
    .app_cmd(mig_app_command.cmd),
    .app_en(mig_app_command.en),
    .app_wdf_data(mig_app_write_data.data),
    .app_wdf_end(mig_app_write_data.end_),
    .app_wdf_mask(mig_app_write_data.mask),
    .app_wdf_wren(mig_app_write_data.wren),
    .app_rd_data(mig_app_response.rd_data),
    .app_rd_data_end(mig_app_response.rd_data_end),
    .app_rd_data_valid(mig_app_response.rd_data_valid),
    .app_rdy(mig_app_response.rdy),
    .app_wdf_rdy(mig_app_response.wdf_rdy),
    .app_sr_req(1'b0),
    .app_ref_req(1'b0),
    .app_zq_req(1'b0),
    .app_sr_active(mig_app_sr_active),
    .app_ref_ack(mig_app_ref_ack),
    .app_zq_ack(mig_app_zq_ack),
    .ui_clk(mig_ui_clk),
    .ui_clk_sync_rst(mig_ui_clk_sync_rst),
    .init_calib_complete(mig_init_calib_complete),
    .device_temp(mig_device_temp),
    .sys_rst(rst_n)
  );

  smart_artix_ddr3_subsystem #(
    .LBA_WIDTH(32),
    .SD_DIV_WIDTH(SD_DIV_WIDTH)
  ) memory_subsystem (
    .clk(mig_ui_clk),
    .rst(mig_ui_clk_sync_rst || !mig_init_calib_complete),
    .loader_rst(mig_ui_clk_sync_rst),
    .core_rst,
    .start(mig_init_calib_complete),
    .sd_init_clk_div(SD_DIV_WIDTH'(124)),
    .sd_default_clk_div(SD_DIV_WIDTH'(1)),
    .sd_transfer_clk_div(SD_DIV_WIDTH'(0)),
    .ddr_init_calib_complete(mig_init_calib_complete),
    .ddr_ui_rst(mig_ui_clk_sync_rst),
    .ddr_device_temp(mig_device_temp),
    .sd_clk,
    .sd_cmd_o,
    .sd_cmd_oe,
    .sd_cmd_i(sd_cmd),
    .sd_dat_i(sd_dat),
    .sd_card_detect_n(sd_cd_n),
    .line_req(board_line_req),
    .line_req_ready(board_line_req_ready),
    .line_rsp(board_line_rsp),
    .ddr_reg_access_request,
    .ddr_reg_access_status,
    .platform_status,
    .mig_app_command,
    .mig_app_write_data,
    .mig_app_response
  );

  voice_major_render_core #(
    .CACHE_SET_COUNT(512),
    .MSHR_DEPTH(8)
  ) core (.*);

  logic unused_status;
  assign unused_status = ddr_reg_access_status.ready ^ ddr_reg_access_status.busy ^
      ddr_reg_access_status.done ^ ddr_reg_access_status.error ^
      (^ddr_reg_access_status.rdata) ^ mig_app_sr_active ^ mig_app_ref_ack ^
      mig_app_zq_ack;
endmodule
