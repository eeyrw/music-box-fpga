#!/usr/bin/env python3

"""Direct Python bindings and Smart Artix protocols for the official CH347 SO."""

from __future__ import annotations

import binascii
import ctypes
import glob
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Protocol, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LIBRARY = REPO_ROOT / "third_party/ch347_linux/lib/x64/libch347.so"
DEFAULT_REGISTER_MAP = REPO_ROOT / "spec/register_map.json"

CLOCK_CHOICES = (
    (60_000_000, 0),
    (30_000_000, 1),
    (15_000_000, 2),
    (7_500_000, 3),
    (3_750_000, 4),
    (1_875_000, 5),
    (937_500, 6),
    (468_750, 7),
)

MAILBOX_REQUEST = 0x5A
MAILBOX_FETCH = 0x5B
REGISTER_READ = 0
REGISTER_WRITE = 1
RESPONSE_OK = 0
RESPONSE_BUS_ERROR = 1
RESPONSE_BUSY = 2
RESPONSE_EMPTY = 3
COMMAND_STREAM = 0xA5
COMMAND_FLUSH = 0xA6

DDR_ACCESS_CONTROL = 0x9060
DDR_ACCESS_STATUS = 0x9064
DDR_ACCESS_ADDR = 0x9068
DDR_ACCESS_BYTE_ENABLE = 0x906C
DDR_ACCESS_DATA0 = 0x9070
DDR_CONTROL_START = 1 << 0
DDR_CONTROL_WRITE = 1 << 1
DDR_CONTROL_CLEAR = 1 << 2
DDR_STATUS_PRESENT = 1 << 0
DDR_STATUS_READY = 1 << 1
DDR_STATUS_DONE = 1 << 3
DDR_STATUS_ERROR = 1 << 4


class Ch347Error(RuntimeError):
    pass


class MailboxCrcError(Ch347Error):
    pass


class RegisterIo(Protocol):
    def read_register(self, address: int) -> int: ...

    def write_register(self, address: int, data: int) -> None: ...


class SpiConfig(ctypes.Structure):
    """Packed mSpiCfgS from the vendor ch347_lib.h header."""

    _pack_ = 1
    _fields_ = [
        ("iMode", ctypes.c_uint8),
        ("iClock", ctypes.c_uint8),
        ("iByteOrder", ctypes.c_uint8),
        ("iSpiWriteReadInterval", ctypes.c_uint16),
        ("iSpiOutDefaultData", ctypes.c_uint8),
        ("iChipSelect", ctypes.c_uint32),
        ("CS1Polarity", ctypes.c_uint8),
        ("CS2Polarity", ctypes.c_uint8),
        ("iIsAutoDeativeCS", ctypes.c_uint16),
        ("iActiveDelay", ctypes.c_uint16),
        ("iDelayDeactive", ctypes.c_uint32),
    ]


@dataclass(frozen=True)
class RegisterResponse:
    status: int
    operation: int
    address: int
    data: int


@dataclass(frozen=True)
class RegisterDefinition:
    name: str
    address: int
    fields: tuple[dict[str, object], ...]


def selected_clock(requested_hz: int) -> tuple[int, int]:
    if requested_hz <= 0:
        raise ValueError("SPI clock must be positive")
    for frequency, code in CLOCK_CHOICES:
        if requested_hz >= frequency:
            return frequency, code
    raise ValueError("SPI clock is below the CH347 468750 Hz minimum")


def discover_device(requested: str = "auto") -> str:
    if requested != "auto":
        return f"/dev/ch34x_pis{requested}" if requested.isdecimal() else requested
    devices = sorted(glob.glob("/dev/ch34x_pis*"))
    if not devices:
        raise Ch347Error("no /dev/ch34x_pis* device found")
    if len(devices) != 1:
        raise Ch347Error("multiple CH347 devices found; select one with --device")
    return devices[0]


def register_crc32(byte0: int, byte1: int, address: int, data: int) -> int:
    payload = bytes((byte0, byte1)) + address.to_bytes(2, "big") + data.to_bytes(4, "big")
    return binascii.crc32(payload) & 0xFFFFFFFF


def encode_register_request(write: bool, address: int, data: int = 0) -> bytes:
    if not 0 <= address <= 0xFFFF or not 0 <= data <= 0xFFFFFFFF:
        raise ValueError("register address or data is out of range")
    operation = REGISTER_WRITE if write else REGISTER_READ
    body = bytes((MAILBOX_REQUEST, operation)) + address.to_bytes(2, "big") + data.to_bytes(4, "big")
    return body + register_crc32(MAILBOX_REQUEST, operation, address, data).to_bytes(4, "big")


def decode_register_response(transfer: bytes) -> RegisterResponse:
    if len(transfer) != 16:
        raise ValueError("mailbox fetch transfer must contain 16 bytes")
    status = transfer[4]
    operation = transfer[5]
    address = int.from_bytes(transfer[6:8], "big")
    data = int.from_bytes(transfer[8:12], "big")
    received_crc = int.from_bytes(transfer[12:16], "big")
    expected_crc = register_crc32(status, operation, address, data)
    if received_crc != expected_crc:
        raise MailboxCrcError("CH347 mailbox response CRC mismatch")
    return RegisterResponse(status, operation, address, data)


def command_crc16(words: Sequence[int]) -> int:
    validate_command_words(words)
    crc = 0xFFFF
    payload = bytes((len(words),)) + b"".join(word.to_bytes(4, "big") for word in words)
    for byte in payload:
        crc ^= byte << 8
        for _ in range(8):
            crc = (
                ((crc << 1) ^ 0x1021) & 0xFFFF
                if crc & 0x8000
                else (crc << 1) & 0xFFFF
            )
    return crc


def encode_flush_transaction() -> bytes:
    payload = bytes((COMMAND_FLUSH, 0))
    crc = 0xFFFF
    for byte in payload:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return payload + crc.to_bytes(2, "big")


def validate_command_words(words: Sequence[int]) -> None:
    if not words or len(words) > 63:
        raise ValueError("command transaction must contain 1 through 63 words")
    if any(not 0 <= word <= 0xFFFFFFFF for word in words):
        raise ValueError("command word is out of range")
    offset = 0
    while offset < len(words):
        payload_count = words[offset] & 0xFF
        if payload_count > 16:
            raise ValueError("command payload exceeds 16 words")
        if offset + payload_count >= len(words):
            raise ValueError("command transaction ends with an incomplete command")
        offset += payload_count + 1


def encode_command_transaction(words: Sequence[int]) -> bytes:
    crc = command_crc16(words)
    return bytes((COMMAND_STREAM, len(words), crc >> 8, crc & 0xFF)) + b"".join(
        word.to_bytes(4, "big") for word in words
    )


class RegisterMap:
    def __init__(self, path: Path = DEFAULT_REGISTER_MAP):
        document = json.loads(path.read_text(encoding="utf-8"))
        definitions: list[RegisterDefinition] = []
        for peripheral in document["device"]["peripherals"]:
            base = int(peripheral["baseAddress"], 0)
            for register in peripheral["registers"]:
                definitions.append(
                    RegisterDefinition(
                        register["name"],
                        base + int(register["addressOffset"], 0),
                        tuple(register.get("fields", ())),
                    )
                )
        self.by_name = {definition.name.upper(): definition for definition in definitions}
        self.by_address = {definition.address: definition for definition in definitions}

    def resolve(self, value: str) -> int:
        definition = self.by_name.get(value.upper())
        if definition is not None:
            return definition.address
        try:
            address = int(value, 0)
        except ValueError as error:
            raise ValueError(f"unknown register name: {value}") from error
        if not 0 <= address <= 0xFFFF:
            raise ValueError("register address is out of range")
        return address

    def name(self, address: int) -> str:
        definition = self.by_address.get(address)
        return definition.name if definition else f"0x{address:04x}"

    def decode_fields(self, address: int, value: int) -> dict[str, int]:
        definition = self.by_address.get(address)
        if definition is None:
            return {}
        result = {}
        for field in definition.fields:
            offset = int(field["bitOffset"])
            width = int(field["bitWidth"])
            result[str(field["name"]).lower()] = (value >> offset) & ((1 << width) - 1)
        return result


class Ch347Transport:
    def __init__(
        self,
        device: str = "auto",
        library: str | Path = DEFAULT_LIBRARY,
        clock_hz: int = 30_000_000,
        chip_select_mask: int = 0x80,
        mailbox_fetch_limit: int = 1000,
    ):
        self.device = discover_device(device)
        self.library_path = str(library)
        self.clock_hz, clock_code = selected_clock(clock_hz)
        self.chip_select_mask = chip_select_mask
        self.mailbox_fetch_limit = mailbox_fetch_limit
        self._library = ctypes.CDLL(self.library_path)
        self._configure_abi()
        self._fd = self._library.CH347OpenDevice(self.device.encode())
        if self._fd < 0:
            raise Ch347Error(f"CH347OpenDevice failed for {self.device}")
        try:
            config = SpiConfig()
            config.iMode = 0
            config.iClock = clock_code
            config.iByteOrder = 1
            config.iChipSelect = chip_select_mask
            config.iIsAutoDeativeCS = 1
            if not self._library.CH347SPI_Init(self._fd, ctypes.byref(config)):
                raise Ch347Error(f"CH347SPI_Init failed for {self.device}")
            if hasattr(self._library, "CH347SPI_SetFrequency"):
                if not self._library.CH347SPI_SetFrequency(self._fd, self.clock_hz):
                    raise Ch347Error(f"CH347SPI_SetFrequency failed for {self.clock_hz} Hz")
        except Exception:
            self.close()
            raise

    def _configure_abi(self) -> None:
        lib = self._library
        lib.CH347GetLibInfo.argtypes = []
        lib.CH347GetLibInfo.restype = ctypes.c_char_p
        lib.CH347OpenDevice.argtypes = [ctypes.c_char_p]
        lib.CH347OpenDevice.restype = ctypes.c_int
        lib.CH347CloseDevice.argtypes = [ctypes.c_int]
        lib.CH347CloseDevice.restype = ctypes.c_bool
        lib.CH347SPI_Init.argtypes = [ctypes.c_int, ctypes.POINTER(SpiConfig)]
        lib.CH347SPI_Init.restype = ctypes.c_bool
        if hasattr(lib, "CH347SPI_SetFrequency"):
            lib.CH347SPI_SetFrequency.argtypes = [ctypes.c_int, ctypes.c_uint32]
            lib.CH347SPI_SetFrequency.restype = ctypes.c_bool
        lib.CH347SPI_Write.argtypes = [
            ctypes.c_int,
            ctypes.c_bool,
            ctypes.c_uint8,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
        ]
        lib.CH347SPI_Write.restype = ctypes.c_bool
        lib.CH347SPI_WriteRead.argtypes = [
            ctypes.c_int,
            ctypes.c_bool,
            ctypes.c_uint8,
            ctypes.c_int,
            ctypes.c_void_p,
        ]
        lib.CH347SPI_WriteRead.restype = ctypes.c_bool

    @property
    def library_info(self) -> str:
        value = self._library.CH347GetLibInfo()
        return value.decode(errors="replace") if value else "unknown"

    def close(self) -> None:
        fd = getattr(self, "_fd", -1)
        if fd >= 0:
            self._library.CH347CloseDevice(fd)
            self._fd = -1

    def __enter__(self) -> "Ch347Transport":
        return self

    def __exit__(self, _type: object, _value: object, _traceback: object) -> None:
        self.close()

    def send(self, payload: bytes) -> None:
        buffer = (ctypes.c_uint8 * len(payload)).from_buffer_copy(payload)
        if not self._library.CH347SPI_Write(
            self._fd, False, self.chip_select_mask, len(payload), len(payload), buffer
        ):
            raise Ch347Error(f"CH347SPI_Write failed for {len(payload)} bytes")

    def exchange(self, payload: bytes) -> bytes:
        buffer = (ctypes.c_uint8 * len(payload)).from_buffer_copy(payload)
        if not self._library.CH347SPI_WriteRead(
            self._fd, False, self.chip_select_mask, len(payload), buffer
        ):
            raise Ch347Error(f"CH347SPI_WriteRead failed for {len(payload)} bytes")
        return bytes(buffer)

    def _transact_register(self, write: bool, address: int, data: int = 0) -> RegisterResponse:
        self.send(encode_register_request(write, address, data))
        expected_operation = REGISTER_WRITE if write else REGISTER_READ
        for _ in range(self.mailbox_fetch_limit):
            try:
                response = decode_register_response(self.exchange(bytes((MAILBOX_FETCH,)) + bytes(15)))
            except MailboxCrcError:
                continue
            if response.status == RESPONSE_BUSY:
                continue
            if response.status == RESPONSE_EMPTY:
                raise Ch347Error("mailbox request was rejected")
            if response.operation != expected_operation or response.address != address:
                raise Ch347Error("mailbox response does not match request")
            if response.status == RESPONSE_BUS_ERROR:
                raise Ch347Error(f"register bus error at 0x{address:04x}")
            if response.status != RESPONSE_OK:
                raise Ch347Error(f"unknown mailbox status {response.status}")
            return response
        raise Ch347Error("mailbox register request timed out")

    def read_register(self, address: int) -> int:
        return self._transact_register(False, address).data

    def write_register(self, address: int, data: int) -> None:
        self._transact_register(True, address, data)

    def write_command_words(self, words: Sequence[int]) -> None:
        self.send(encode_command_transaction(words))

    def flush_command_stream(self) -> None:
        self.send(encode_flush_transaction())


class DdrDebugAccess:
    def __init__(self, registers: RegisterIo, timeout_polls: int = 10_000):
        self.registers = registers
        self.timeout_polls = timeout_polls

    def _prepare(self, address: int) -> None:
        if address < 0 or address > 0xFFFFFFFF or address & 0xF:
            raise ValueError("DDR byte address must be 16-byte aligned and 32-bit")
        self.registers.write_register(DDR_ACCESS_CONTROL, DDR_CONTROL_CLEAR)
        status = self.registers.read_register(DDR_ACCESS_STATUS)
        if not status & DDR_STATUS_READY:
            raise Ch347Error(f"DDR debug aperture is not ready: status=0x{status:08x}")
        self.registers.write_register(DDR_ACCESS_ADDR, address)

    def _wait_done(self) -> int:
        for _ in range(self.timeout_polls):
            status = self.registers.read_register(DDR_ACCESS_STATUS)
            if status & DDR_STATUS_ERROR:
                raise Ch347Error(f"DDR debug command failed: status=0x{status:08x}")
            if status & DDR_STATUS_DONE:
                return status
        raise Ch347Error("DDR debug command timed out")

    def read_beat(self, address: int) -> bytes:
        self._prepare(address)
        self.registers.write_register(DDR_ACCESS_CONTROL, DDR_CONTROL_START)
        self._wait_done()
        words = [self.registers.read_register(DDR_ACCESS_DATA0 + 4 * index) for index in range(4)]
        return b"".join(word.to_bytes(4, "little") for word in words)

    def read(self, address: int, beats: int) -> bytes:
        if beats <= 0:
            raise ValueError("DDR beat count must be positive")
        return b"".join(self.read_beat(address + 16 * index) for index in range(beats))

    def write_beat(self, address: int, words: Iterable[int], byte_enable: int = 0xFFFF) -> None:
        word_list = list(words)
        if len(word_list) != 4 or any(not 0 <= word <= 0xFFFFFFFF for word in word_list):
            raise ValueError("DDR write requires four 32-bit words")
        if not 0 < byte_enable <= 0xFFFF:
            raise ValueError("DDR byte-enable must be a nonzero 16-bit mask")
        self._prepare(address)
        self.registers.write_register(DDR_ACCESS_BYTE_ENABLE, byte_enable)
        for index, word in enumerate(word_list):
            self.registers.write_register(DDR_ACCESS_DATA0 + 4 * index, word)
        self.registers.write_register(
            DDR_ACCESS_CONTROL, DDR_CONTROL_START | DDR_CONTROL_WRITE
        )
        self._wait_done()
