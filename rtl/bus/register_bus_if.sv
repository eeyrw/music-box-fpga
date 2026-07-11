interface register_bus_if;
  logic        valid;
  logic        write;
  logic [15:0] address;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic        ready;
  logic        error;

  modport master(output valid, write, address, wdata, input rdata, ready, error);
  modport slave(input valid, write, address, wdata, output rdata, ready, error);
endinterface
