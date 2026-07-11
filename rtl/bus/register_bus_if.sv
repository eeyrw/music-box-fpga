interface register_bus_if;
  // Simple single-beat register bus. This interface is currently not used by
  // the top-level module, but documents the signal grouping expected for a
  // future SPI or host-bus bridge.
  logic        valid;
  logic        write;
  logic [15:0] address;
  logic [31:0] wdata;
  logic [31:0] rdata;
  logic        ready;
  logic        error;

  // Master drives request/control/data fields; slave returns read data and the
  // handshake/error response for that same beat.
  modport master(output valid, write, address, wdata, input rdata, ready, error);
  modport slave(input valid, write, address, wdata, output rdata, ready, error);
endinterface
