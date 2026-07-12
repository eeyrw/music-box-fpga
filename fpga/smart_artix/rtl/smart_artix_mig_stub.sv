module smart_artix_mig_stub #(
  parameter int ADDR_WIDTH = 28,
  parameter int DATA_WIDTH = 128,
  parameter int INIT_CALIB_CYCLES = 16,
  parameter int READ_LATENCY_CYCLES = 6
) (
  input  logic                  clk,
  input  logic                  rst,

  output logic                  init_calib_complete,
  input  logic [ADDR_WIDTH-1:0] app_addr,
  input  logic [2:0]            app_cmd,
  input  logic                  app_en,
  output logic                  app_rdy,
  output logic [DATA_WIDTH-1:0] app_rd_data,
  output logic                  app_rd_data_valid,
  output logic                  app_rd_data_end
);
  localparam logic [2:0] MIG_CMD_READ = 3'b001;
  localparam int CALIB_WIDTH = (INIT_CALIB_CYCLES <= 1) ? 1 : $clog2(INIT_CALIB_CYCLES + 1);
  localparam int LATENCY_WIDTH = (READ_LATENCY_CYCLES <= 1) ? 1 : $clog2(READ_LATENCY_CYCLES + 1);
  localparam int WORDS = DATA_WIDTH / 16;

  logic [CALIB_WIDTH-1:0] calib_count;
  logic [LATENCY_WIDTH-1:0] latency_count;
  logic request_pending;
  logic [ADDR_WIDTH-1:0] pending_addr;
  logic [15:0] pending_addr_folded;

  assign app_rdy = init_calib_complete && !request_pending;
  assign pending_addr_folded = pending_addr[15:0] ^ {15'd0, ^pending_addr[ADDR_WIDTH-1:16]};

  always_comb begin
    app_rd_data = '0;
    for (int i = 0; i < WORDS; i++) begin
      app_rd_data[i*16 +: 16] = pending_addr_folded + 16'(i);
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      init_calib_complete <= 1'b0;
      calib_count <= '0;
      latency_count <= '0;
      request_pending <= 1'b0;
      pending_addr <= '0;
      app_rd_data_valid <= 1'b0;
      app_rd_data_end <= 1'b0;
    end else begin
      app_rd_data_valid <= 1'b0;
      app_rd_data_end <= 1'b0;

      if (!init_calib_complete) begin
        if (calib_count == CALIB_WIDTH'(INIT_CALIB_CYCLES))
          init_calib_complete <= 1'b1;
        else
          calib_count <= calib_count + 1'b1;
      end

      if (app_en && app_rdy && app_cmd == MIG_CMD_READ) begin
        pending_addr <= app_addr;
        request_pending <= 1'b1;
        latency_count <= '0;
      end else if (request_pending) begin
        if (latency_count == LATENCY_WIDTH'(READ_LATENCY_CYCLES)) begin
          app_rd_data_valid <= 1'b1;
          app_rd_data_end <= 1'b1;
          request_pending <= 1'b0;
        end else begin
          latency_count <= latency_count + 1'b1;
        end
      end
    end
  end
endmodule
