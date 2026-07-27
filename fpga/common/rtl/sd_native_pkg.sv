package sd_native_pkg;
  typedef enum logic [2:0] {
    SD_RESP_NONE,
    SD_RESP_R1,
    SD_RESP_R1B,
    SD_RESP_R2,
    SD_RESP_R3,
    SD_RESP_R6,
    SD_RESP_R7
  } sd_response_type_t;

  typedef enum logic [2:0] {
    SD_STATUS_OK,
    SD_STATUS_TIMEOUT,
    SD_STATUS_CRC_ERROR,
    SD_STATUS_FRAMING_ERROR,
    SD_STATUS_WRONG_INDEX,
    SD_STATUS_BUSY_TIMEOUT,
    SD_STATUS_CANCELLED,
    SD_STATUS_ABORTED
  } sd_transport_status_t;
endpackage
