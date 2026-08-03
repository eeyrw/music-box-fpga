#!/usr/bin/env python3

import ctypes
import unittest

from ch347_transport import (
    DDR_ACCESS_ADDR,
    DDR_ACCESS_CONTROL,
    DDR_ACCESS_DATA0,
    DDR_ACCESS_STATUS,
    DDR_CONTROL_CLEAR,
    DDR_CONTROL_START,
    DDR_STATUS_DONE,
    DDR_STATUS_READY,
    DdrDebugAccess,
    MailboxCrcError,
    SpiConfig,
    command_crc16,
    decode_register_response,
    encode_command_transaction,
    encode_flush_transaction,
    encode_register_request,
    register_crc32,
    selected_clock,
)


class FakeRegisters:
    def __init__(self) -> None:
        self.writes: list[tuple[int, int]] = []
        self.reads = {
            DDR_ACCESS_STATUS: [DDR_STATUS_READY, DDR_STATUS_READY, DDR_STATUS_DONE],
            DDR_ACCESS_DATA0: [0x03020100],
            DDR_ACCESS_DATA0 + 4: [0x07060504],
            DDR_ACCESS_DATA0 + 8: [0x0B0A0908],
            DDR_ACCESS_DATA0 + 12: [0x0F0E0D0C],
        }

    def write_register(self, address: int, data: int) -> None:
        self.writes.append((address, data))

    def read_register(self, address: int) -> int:
        return self.reads[address].pop(0)


class Ch347TransportTest(unittest.TestCase):
    def test_vendor_spi_config_is_packed(self) -> None:
        self.assertEqual(ctypes.sizeof(SpiConfig), 20)

    def test_clock_selection_rounds_down(self) -> None:
        self.assertEqual(selected_clock(30_000_000), (30_000_000, 1))
        self.assertEqual(selected_clock(29_999_999), (15_000_000, 2))
        with self.assertRaises(ValueError):
            selected_clock(100_000)

    def test_register_request_and_response_crc(self) -> None:
        request = encode_register_request(False, 0x9000)
        self.assertEqual(request[:8], bytes.fromhex("5a00900000000000"))
        self.assertEqual(int.from_bytes(request[8:], "big"), register_crc32(0x5A, 0, 0x9000, 0))

        body = bytes.fromhex("00009000000f0000")
        transfer = bytes(4) + body + register_crc32(0, 0, 0x9000, 0x000F0000).to_bytes(4, "big")
        response = decode_register_response(transfer)
        self.assertEqual((response.address, response.data), (0x9000, 0x000F0000))
        with self.assertRaises(MailboxCrcError):
            decode_register_response(transfer[:-1] + bytes((transfer[-1] ^ 1,)))

    def test_command_transaction(self) -> None:
        words = [0x21000004, 0x00000001, 0x00200000, 0x00010000, 0x00001000]
        encoded = encode_command_transaction(words)
        self.assertEqual(encoded[:2], bytes((0xA5, 5)))
        self.assertEqual(int.from_bytes(encoded[2:4], "big"), command_crc16(words))
        self.assertEqual(encoded[4:], b"".join(word.to_bytes(4, "big") for word in words))
        with self.assertRaises(ValueError):
            encode_command_transaction([0x21000004, 0])

    def test_flush_transaction(self) -> None:
        self.assertEqual(encode_flush_transaction(), bytes.fromhex("a600aad7"))

    def test_ddr_read_sequence_and_byte_order(self) -> None:
        registers = FakeRegisters()
        data = DdrDebugAccess(registers).read_beat(0x100)
        self.assertEqual(data, bytes(range(16)))
        self.assertEqual(
            registers.writes,
            [
                (DDR_ACCESS_CONTROL, DDR_CONTROL_CLEAR),
                (DDR_ACCESS_ADDR, 0x100),
                (DDR_ACCESS_CONTROL, DDR_CONTROL_START),
            ],
        )


if __name__ == "__main__":
    unittest.main()
