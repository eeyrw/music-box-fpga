module voice_descriptor_store (
  input  logic                                      clk,
  input  logic                                      write_en,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]     write_voice,
  input  logic [15:0]                               write_offset,
  input  logic [31:0]                               write_data,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0]     read_voice,
  input  logic [15:0]                               read_offset,
  output logic [31:0]                               read_data
);
  import synth_pkg::*;

  localparam int DESCRIPTOR_WORDS = NUM_VOICES * 32;
  localparam int DESCRIPTOR_WORD_INDEX_WIDTH = $clog2(DESCRIPTOR_WORDS);

  localparam logic [15:0] OFF_LENGTH       = 16'h0008;
  localparam logic [15:0] OFF_LENGTH_R     = 16'h000c;
  localparam logic [15:0] OFF_LOOP_START   = 16'h0010;
  localparam logic [15:0] OFF_LOOP_START_R = 16'h0014;
  localparam logic [15:0] OFF_LOOP_END     = 16'h0018;
  localparam logic [15:0] OFF_LOOP_END_R   = 16'h001c;
  localparam logic [15:0] OFF_REGION_MODE  = 16'h0020;
  localparam logic [15:0] OFF_GAIN_L       = 16'h0040;
  localparam logic [15:0] OFF_GAIN_R       = 16'h0044;
  localparam logic [15:0] OFF_GAIN_RT      = 16'h0048;
  localparam logic [15:0] OFF_ENVELOPE     = 16'h004c;
  localparam logic [15:0] OFF_FILTER_CTL   = 16'h0050;
  localparam logic [15:0] OFF_CONTROL      = 16'h0070;

  logic [DESCRIPTOR_WORD_INDEX_WIDTH-1:0] write_addr;
  logic [DESCRIPTOR_WORD_INDEX_WIDTH-1:0] read_addr;
  logic [31:0] normalized_write_data;

  always_comb begin
    write_addr = {write_voice, write_offset[6:2]};
    read_addr = '0;
    if ((read_offset[15:7] == 9'd0) && (read_offset[1:0] == 2'd0)) begin
      read_addr = {read_voice, read_offset[6:2]};
    end

    normalized_write_data = write_data;
    unique case (write_offset)
      OFF_LENGTH, OFF_LOOP_START, OFF_LOOP_END,
      OFF_LENGTH_R, OFF_LOOP_START_R, OFF_LOOP_END_R: begin
        normalized_write_data = {8'd0, write_data[PHASE_FRAME_WIDTH-1:0]};
      end
      OFF_GAIN_L, OFF_GAIN_R, OFF_ENVELOPE: begin
        normalized_write_data = {{16{write_data[15]}}, write_data[15:0]};
      end
      OFF_GAIN_RT: begin
        normalized_write_data = write_data;
      end
      OFF_REGION_MODE: begin
        normalized_write_data = {29'd0, write_data[2:0]};
      end
      OFF_FILTER_CTL: begin
        normalized_write_data = {31'd0, write_data[0]};
      end
      OFF_CONTROL: begin
        normalized_write_data = {31'd0, write_data[0]};
      end
      default: begin
      end
    endcase
  end

  voice_bram_1r1w #(
    .NUM_WORDS(DESCRIPTOR_WORDS),
    .ADDR_WIDTH(DESCRIPTOR_WORD_INDEX_WIDTH),
    .DATA_WIDTH(32),
    .DEFAULT_WORD(32'd0)
  ) descriptor_ram (
    .clk(clk),
    .write_en(write_en),
    .write_addr(write_addr),
    .write_data(normalized_write_data),
    .read_addr(read_addr),
    .read_data(read_data)
  );
endmodule
