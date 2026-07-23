module envelope_state_store (
  input  logic clk,
  input  logic rst,
  input  logic write_en,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] write_voice,
  input  logic [2:0] write_mode,
  input  logic signed [synth_pkg::ENV_GAIN_Q23_WIDTH-1:0] write_gain_q23,
  input  logic [synth_pkg::ENV_CB_WIDTH-1:0] write_cb_q8_8,
  input  logic [31:0] write_step,
  input  logic [31:0] write_target,
  input  logic [31:0] write_phase,
  input  logic [31:0] write_duration,
  input  logic write_active,
  input  logic [synth_pkg::VOICE_ID_WIDTH-1:0] read_voice,
  output logic [2:0] read_mode,
  output logic signed [synth_pkg::ENV_GAIN_Q23_WIDTH-1:0] read_gain_q23,
  output logic [synth_pkg::ENV_CB_WIDTH-1:0] read_cb_q8_8,
  output logic [31:0] read_step,
  output logic [31:0] read_target,
  output logic [31:0] read_phase,
  output logic [31:0] read_duration,
  output logic read_active
);
  import synth_pkg::*;

  (* ram_style = "distributed" *) logic [2:0] mode [NUM_VOICES];
  (* ram_style = "distributed" *) logic signed [ENV_GAIN_Q23_WIDTH-1:0] gain_q23 [NUM_VOICES];
  (* ram_style = "distributed" *) logic [ENV_CB_WIDTH-1:0] cb_q8_8 [NUM_VOICES];
  (* ram_style = "distributed" *) logic [31:0] step [NUM_VOICES];
  (* ram_style = "distributed" *) logic [31:0] target [NUM_VOICES];
  (* ram_style = "distributed" *) logic [31:0] phase [NUM_VOICES];
  (* ram_style = "distributed" *) logic [31:0] duration [NUM_VOICES];
  (* ram_style = "distributed" *) logic active [NUM_VOICES];

  always_ff @(posedge clk) begin
    if (rst) begin
      mode <= '{default: '0};
      gain_q23 <= '{default: '0};
      cb_q8_8 <= '{default: '0};
      step <= '{default: '0};
      target <= '{default: '0};
      phase <= '{default: '0};
      duration <= '{default: '0};
      active <= '{default: 1'b0};
      read_mode <= '0;
      read_gain_q23 <= '0;
      read_cb_q8_8 <= '0;
      read_step <= '0;
      read_target <= '0;
      read_phase <= '0;
      read_duration <= '0;
      read_active <= 1'b0;
    end else begin
      if (write_en) begin
        mode[write_voice] <= write_mode;
        gain_q23[write_voice] <= write_gain_q23;
        cb_q8_8[write_voice] <= write_cb_q8_8;
        step[write_voice] <= write_step;
        target[write_voice] <= write_target;
        phase[write_voice] <= write_phase;
        duration[write_voice] <= write_duration;
        active[write_voice] <= write_active;
      end
      read_mode <= mode[read_voice];
      read_gain_q23 <= gain_q23[read_voice];
      read_cb_q8_8 <= cb_q8_8[read_voice];
      read_step <= step[read_voice];
      read_target <= target[read_voice];
      read_phase <= phase[read_voice];
      read_duration <= duration[read_voice];
      read_active <= active[read_voice];
    end
  end
endmodule
