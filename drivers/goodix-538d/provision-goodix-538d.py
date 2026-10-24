#!/usr/bin/env python3
"""
Self-contained TLS-PSK & Firmware Provisioner for Goodix 27c6:538d (GF5298_GM168SEC).

Why this exists:
  On GM168SEC-based Goodix 53xd sensors (27c6:538d), the application firmware
  (GF5298_GM168SEC_APP_13016) cryptographically binds its firmware HMAC to the
  provisioned Pre-Shared Master Key (PMK) and locks preset_psk_write (0xe0)
  while running in APP mode.
  If the sensor was previously initialized by Windows (which provisions a
  DPAPI-wrapped random key), libfprint cannot establish a TLS-PSK session
  or overwrite the PSK in APP mode.

  Following the canonical goodix-fp-dump (driver_53xd.py) provisioning flow:
    1. Check firmware_version() and preset_psk_read(0xbb020001).
    2. If firmware == GF5298_GM168SEC_APP_13016 and PMK_HASH matches the
       all-zeros PSK (66687aad...), exit 0 immediately (no-op).
    3. Otherwise, enter ROM IAP bootloader (MILAN_GM168SEC_IAP_10007) via
       mcu_erase_app, write the 96-byte PSK_WHITE_BOX (wrapped 126-byte
       payload), re-flash GF5298_GM168SEC_APP_13016.bin, verify the HMAC-SHA256
       signature, soft-reset the MCU, and verify the provisioned state.

Zero external Python dependencies: binds directly to system libusb-1.0.so.0
via ctypes.
"""

from __future__ import annotations

import ctypes
import hashlib
import hmac
import os
import re
import struct
import sys
import time

VENDOR_ID = 0x27C6
PRODUCT_ID = 0x538D

INTERFACE_NUM = 0
ENDPOINT_OUT = 0x01
ENDPOINT_IN = 0x83

TARGET_FIRMWARE = "GF5298_GM168SEC_APP_13016"
VALID_FIRMWARE_RE = r"GF5298_GM168SEC_APP_130[0-9]{2}"
IAP_FIRMWARE_RE = r"(MILAN|GF5298)_GM168SEC_IAP_.*"

EXPECTED_FW_SIZE = 24268
EXPECTED_FW_SHA256 = (
    "0f28f8f52860afea86bd56d869cd7f4fe41ba943edd1d56100113e94ecfd6c0d"
)

PSK = bytes.fromhex(
    "0000000000000000000000000000000000000000000000000000000000000000"
)

PSK_WHITE_BOX = bytes.fromhex(
    "ec35ae3abb45ed3f12c4751f1e5c2cc05b3c5452e9104d9f2a3118644f37a04b"
    "6fd66b1d97cf80f1345f76c84f03ff30bb51bf308f2a9875c41e6592cd2a2f9e"
    "60809b17b5316037b69bb2fa5d4c8ac31edb3394046ec06bbdacc57da6a756c5"
)

PSK_PRE_FLAGS = bytes.fromhex("56a5bb956b7c8d9e0000")

PMK_HASH = bytes.fromhex(
    "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"
)

FLAGS_MESSAGE_PROTOCOL = 0xA0

COMMAND_NOP = 0x00
COMMAND_RESET = 0xA2
COMMAND_MCU_ERASE_APP = 0xA4
COMMAND_FIRMWARE_VERSION = 0xA8
COMMAND_ACK = 0xB0
COMMAND_PRESET_PSK_WRITE_R = 0xE0
COMMAND_PRESET_PSK_READ_R = 0xE4
COMMAND_WRITE_FIRMWARE = 0xF0
COMMAND_CHECK_FIRMWARE = 0xF4


class USBError(Exception):
    def __init__(self, code: int, message: str):
        super().__init__(f"{message} (libusb code {code})")
        self.backend_error_code = code


class USBTimeoutError(USBError):
    pass


def _load_libusb() -> ctypes.CDLL:
    lib = ctypes.CDLL("libusb-1.0.so.0")

    lib.libusb_init.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
    lib.libusb_init.restype = ctypes.c_int

    lib.libusb_exit.argtypes = [ctypes.c_void_p]
    lib.libusb_exit.restype = None

    lib.libusb_open_device_with_vid_pid.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint16,
        ctypes.c_uint16,
    ]
    lib.libusb_open_device_with_vid_pid.restype = ctypes.c_void_p

    lib.libusb_close.argtypes = [ctypes.c_void_p]
    lib.libusb_close.restype = None

    lib.libusb_kernel_driver_active.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_kernel_driver_active.restype = ctypes.c_int

    lib.libusb_detach_kernel_driver.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_detach_kernel_driver.restype = ctypes.c_int

    lib.libusb_set_configuration.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_set_configuration.restype = ctypes.c_int

    lib.libusb_claim_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_claim_interface.restype = ctypes.c_int

    lib.libusb_release_interface.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.libusb_release_interface.restype = ctypes.c_int

    lib.libusb_control_transfer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_uint8,
        ctypes.c_uint8,
        ctypes.c_uint16,
        ctypes.c_uint16,
        ctypes.c_void_p,
        ctypes.c_uint16,
        ctypes.c_uint,
    ]
    lib.libusb_control_transfer.restype = ctypes.c_int

    lib.libusb_bulk_transfer.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ubyte,
        ctypes.c_void_p,
        ctypes.c_int,
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
    ]
    lib.libusb_bulk_transfer.restype = ctypes.c_int

    return lib


_LIBUSB = _load_libusb()


class LibUSBProtocol:
    def __init__(
        self,
        vendor: int = VENDOR_ID,
        product: int = PRODUCT_ID,
        timeout: float = 8.0,
    ):
        self.ctx = ctypes.c_void_p()
        rc = _LIBUSB.libusb_init(ctypes.byref(self.ctx))
        if rc != 0:
            raise USBError(rc, "libusb_init failed")

        self.handle: ctypes.c_void_p | None = None
        self.claimed = False

        deadline = time.time() + timeout
        status_buf = ctypes.create_string_buffer(2)
        last_rc = -5

        while True:
            handle = _LIBUSB.libusb_open_device_with_vid_pid(
                self.ctx, vendor, product
            )
            if handle:
                rc = _LIBUSB.libusb_control_transfer(
                    handle, 0x80, 0x00, 0, 0, status_buf, 2, 1000
                )
                if rc >= 0:
                    self.handle = handle
                    break
                last_rc = rc
                _LIBUSB.libusb_close(handle)
                if rc not in (-1, -4, -7, -9, -99):
                    self.close()
                    raise USBError(rc, "Unexpected error in USB GET_STATUS")

            if time.time() > deadline:
                self.close()
                raise TimeoutError(
                    f"Goodix {vendor:04x}:{product:04x} device not ready "
                    f"(last_rc={last_rc})"
                )
            time.sleep(0.02)

        if _LIBUSB.libusb_kernel_driver_active(self.handle, INTERFACE_NUM) == 1:
            _LIBUSB.libusb_detach_kernel_driver(self.handle, INTERFACE_NUM)

        _LIBUSB.libusb_set_configuration(self.handle, 1)

        rc = _LIBUSB.libusb_claim_interface(self.handle, INTERFACE_NUM)
        if rc < 0:
            self.close()
            raise USBError(
                rc,
                f"Failed to claim USB interface {INTERFACE_NUM} "
                "(ensure fprintd.service is stopped)",
            )
        self.claimed = True

    def write(self, data: bytes, timeout: float | None = 5.0) -> None:
        timeout_ms = 0 if timeout is None else round(timeout * 1000)
        length = len(data)
        if length % 0x40:
            data += b"\x00" * (0x40 - length % 0x40)

        for i in range(0, length, 0x40):
            chunk = data[i : i + 0x40]
            buf = ctypes.create_string_buffer(chunk, len(chunk))
            transferred = ctypes.c_int(0)
            rc = _LIBUSB.libusb_bulk_transfer(
                self.handle,
                ENDPOINT_OUT,
                buf,
                len(chunk),
                ctypes.byref(transferred),
                timeout_ms,
            )
            if rc < 0:
                if rc == -7:
                    raise USBTimeoutError(rc, "USB bulk write timed out")
                raise USBError(rc, "USB bulk write failed")

    def read(
        self,
        size: int = 0x10000,
        timeout: float | None = 5.0,
        raw_single: bool = False,
    ) -> bytes:
        timeout_ms = 0 if timeout is None else round(timeout * 1000)
        buf = ctypes.create_string_buffer(size)
        transferred = ctypes.c_int(0)
        rc = _LIBUSB.libusb_bulk_transfer(
            self.handle,
            ENDPOINT_IN,
            buf,
            size,
            ctypes.byref(transferred),
            timeout_ms,
        )
        if rc < 0:
            if rc == -7:
                raise USBTimeoutError(rc, "USB bulk read timed out")
            raise USBError(rc, "USB bulk read failed")

        data = buf.raw[: transferred.value]
        if (
            not raw_single
            and len(data) >= 4
            and ((data[0] + data[1] + data[2]) & 0xFF) == data[3]
        ):
            expected_total = 4 + struct.unpack("<H", data[1:3])[0]
            while len(data) < expected_total:
                rc = _LIBUSB.libusb_bulk_transfer(
                    self.handle,
                    ENDPOINT_IN,
                    buf,
                    size,
                    ctypes.byref(transferred),
                    timeout_ms,
                )
                if rc < 0:
                    if rc == -7:
                        raise USBTimeoutError(
                            rc, "USB bulk read continuation timed out"
                        )
                    raise USBError(rc, "USB bulk read continuation failed")
                data += buf.raw[: transferred.value]
        return data

    def disconnect(self, timeout: float = 5.0) -> None:
        deadline = time.time() + timeout
        status_buf = ctypes.create_string_buffer(2)
        while time.time() <= deadline:
            if not self.handle:
                break
            rc = _LIBUSB.libusb_control_transfer(
                self.handle, 0x80, 0x00, 0, 0, status_buf, 2, 500
            )
            if rc < 0:
                break
            time.sleep(0.01)
        self.close()

    def close(self) -> None:
        if self.handle:
            if self.claimed:
                _LIBUSB.libusb_release_interface(self.handle, INTERFACE_NUM)
                self.claimed = False
            _LIBUSB.libusb_close(self.handle)
            self.handle = None
        if self.ctx:
            _LIBUSB.libusb_exit(self.ctx)
            self.ctx = ctypes.c_void_p()


def encode_message_pack(
    payload: bytes, flags: int = FLAGS_MESSAGE_PROTOCOL
) -> bytes:
    length = len(payload)
    header = struct.pack("<BH", flags, length)
    return header + struct.pack("<B", sum(header) & 0xFF) + payload


def check_message_pack(
    data: bytes, flags: int = FLAGS_MESSAGE_PROTOCOL
) -> bytes:
    if len(data) < 4:
        raise ValueError(f"Message pack too short ({len(data)} bytes)")
    length = struct.unpack("<H", data[1:3])[0]
    if (sum(data[0:3]) & 0xFF) != data[3]:
        raise ValueError("Invalid message pack header checksum")
    if data[0] != flags or len(data) < 4 + length:
        raise ValueError(
            f"Invalid message pack (flags=0x{data[0]:02x}, len={len(data)}, expected={4 + length})"
        )
    return data[4 : 4 + length]


def encode_message_protocol(
    payload: bytes, command: int, checksum: bool = True
) -> bytes:
    length = len(payload)
    data = struct.pack("<BH", command, length + 1) + payload
    csum = (0xAA - sum(data)) & 0xFF if checksum else 0x88
    return data + struct.pack("<B", csum)


def check_message_protocol(
    data: bytes, command: int, checksum: bool = True
) -> bytes:
    if len(data) < 4:
        raise ValueError(f"Protocol message too short ({len(data)} bytes)")
    length = struct.unpack("<H", data[1:3])[0]
    if len(data) < 2 + length:
        raise ValueError("Protocol message truncated")
    expected_csum = (0xAA - sum(data[0 : 2 + length])) & 0xFF if checksum else 0x88
    if data[2 + length] != expected_csum:
        raise ValueError("Invalid protocol message checksum")
    if data[0] != command:
        raise ValueError(
            f"Unexpected command in reply: got 0x{data[0]:02x}, expected 0x{command:02x}"
        )
    return data[3 : 2 + length]


def check_ack(data: bytes, command: int) -> bool:
    if len(data) < 2 or not (data[1] & 0x1):
        raise ValueError("Invalid ACK packet")
    if data[0] != command:
        raise ValueError(
            f"ACK command mismatch: got 0x{data[0]:02x}, expected 0x{command:02x}"
        )
    return (data[1] & 0x2) == 0x2


class GoodixDevice:
    def __init__(self, timeout: float = 8.0):
        self.protocol = LibUSBProtocol(VENDOR_ID, PRODUCT_ID, timeout=timeout)
        self.empty_buffer()

    def close(self) -> None:
        self.protocol.close()

    def empty_buffer(self) -> None:
        try:
            while True:
                self.protocol.read(timeout=0.1, raw_single=True)
        except USBTimeoutError:
            return

    def nop(self) -> None:
        self.protocol.write(
            encode_message_pack(
                encode_message_protocol(
                    b"\x00\x00\x00\x00", COMMAND_NOP, checksum=False
                )
            )
        )
        try:
            message = self.protocol.read(timeout=0.1)
        except USBTimeoutError:
            return
        check_ack(
            check_message_protocol(check_message_pack(message), COMMAND_ACK),
            COMMAND_NOP,
        )

    def firmware_version(self) -> str:
        self.protocol.write(
            encode_message_pack(
                encode_message_protocol(b"\x00\x00", COMMAND_FIRMWARE_VERSION)
            )
        )
        check_ack(
            check_message_protocol(
                check_message_pack(self.protocol.read()), COMMAND_ACK
            ),
            COMMAND_FIRMWARE_VERSION,
        )
        reply = check_message_protocol(
            check_message_pack(self.protocol.read()), COMMAND_FIRMWARE_VERSION
        )
        return reply.split(b"\x00")[0].decode("ascii", errors="replace")

    def preset_psk_read(
        self, flags: int, length: int, offset: int
    ) -> tuple[bool, int | None, bytes | None]:
        payload = (
            struct.pack("<I", length)
            + struct.pack("<I", offset)
            + struct.pack("<I", flags)
            + struct.pack("<I", 0)
        )
        self.protocol.write(
            encode_message_pack(
                encode_message_protocol(payload, COMMAND_PRESET_PSK_READ_R)
            )
        )
        check_ack(
            check_message_protocol(
                check_message_pack(self.protocol.read()), COMMAND_ACK
            ),
            COMMAND_PRESET_PSK_READ_R,
        )
        msg = check_message_protocol(
            check_message_pack(self.protocol.read()), COMMAND_PRESET_PSK_READ_R
        )
        if len(msg) < 1 or msg[0] != 0x00:
            return False, None, None
        if len(msg) < 9:
            return False, None, None
        resp_flags = struct.unpack("<I", msg[1:5])[0]
        psk_len = struct.unpack("<I", msg[5:9])[0]
        if len(msg) - 9 < psk_len:
            return False, resp_flags, None
        return True, resp_flags, msg[9 : 9 + psk_len]

    def preset_psk_write(
        self,
        flags: int,
        payload: bytes,
        length: int,
        offset: int,
        pre_flags: bytes,
    ) -> bool:
        data = (
            pre_flags
            + struct.pack("<I", flags)
            + struct.pack("<I", len(payload))
            + payload
        )
        total_length = len(data)
        framed = (
            struct.pack("<I", total_length)
            + struct.pack("<I", length)
            + struct.pack("<I", offset)
            + data[offset : offset + length]
        )
        self.protocol.write(
            encode_message_pack(
                encode_message_protocol(framed, COMMAND_PRESET_PSK_WRITE_R)
            )
        )
        check_ack(
            check_message_protocol(
                check_message_pack(self.protocol.read(timeout=10.0)),
                COMMAND_ACK,
            ),
            COMMAND_PRESET_PSK_WRITE_R,
        )
        msg = check_message_protocol(
            check_message_pack(self.protocol.read(timeout=10.0)),
            COMMAND_PRESET_PSK_WRITE_R,
        )
        return len(msg) >= 1 and msg[0] == 0x00

    def mcu_erase_app(self, sleep_time: int = 50, reply: bool = True) -> bool:
        self.protocol.write(
            encode_message_pack(
                encode_message_protocol(
                    b"\x00" + struct.pack("<B", sleep_time),
                    COMMAND_MCU_ERASE_APP,
                )
            )
        )
        check_ack(
            check_message_protocol(
                check_message_pack(self.protocol.read(timeout=10.0)),
                COMMAND_ACK,
            ),
            COMMAND_MCU_ERASE_APP,
        )
        if not reply:
            return True
        msg = check_message_protocol(
            check_message_pack(self.protocol.read(timeout=10.0)),
            COMMAND_MCU_ERASE_APP,
        )
        return len(msg) >= 1 and msg[0] == 0x01

    def write_firmware(
        self, offset: int, payload: bytes, number: int = 2
    ) -> bool:
        data = (
            struct.pack("<I", offset)
            + struct.pack("<I", len(payload))
            + struct.pack("<I", number)
            + payload
        )
        self.protocol.write(
            encode_message_pack(
                encode_message_protocol(data, COMMAND_WRITE_FIRMWARE)
            )
        )
        check_ack(
            check_message_protocol(
                check_message_pack(self.protocol.read(timeout=10.0)),
                COMMAND_ACK,
            ),
            COMMAND_WRITE_FIRMWARE,
        )
        msg = check_message_protocol(
            check_message_pack(self.protocol.read(timeout=10.0)),
            COMMAND_WRITE_FIRMWARE,
        )
        return len(msg) >= 1 and msg[0] == 0x01

    def check_firmware(self, fw_hmac: bytes) -> bool:
        self.protocol.write(
            encode_message_pack(
                encode_message_protocol(fw_hmac, COMMAND_CHECK_FIRMWARE)
            )
        )
        check_ack(
            check_message_protocol(
                check_message_pack(self.protocol.read(timeout=10.0)),
                COMMAND_ACK,
            ),
            COMMAND_CHECK_FIRMWARE,
        )
        msg = check_message_protocol(
            check_message_pack(self.protocol.read(timeout=10.0)),
            COMMAND_CHECK_FIRMWARE,
        )
        return len(msg) >= 1 and msg[0] == 0x01

    def reset_mcu(self, sleep_time: int = 50) -> None:
        # reset_sensor=False, soft_reset_mcu=True -> flags byte = 0x02
        payload = struct.pack("<BB", 0x02, sleep_time)
        self.protocol.write(
            encode_message_pack(encode_message_protocol(payload, COMMAND_RESET))
        )
        check_ack(
            check_message_protocol(
                check_message_pack(self.protocol.read()), COMMAND_ACK
            ),
            COMMAND_RESET,
        )
        self.protocol.disconnect(timeout=5.0)


def init_device() -> GoodixDevice:
    dev = GoodixDevice(timeout=8.0)
    dev.nop()
    return dev


def check_psk(device: GoodixDevice) -> bool:
    success, flags, psk = device.preset_psk_read(0xBB020001, len(PMK_HASH), 0)
    if not success or flags != 0xBB020001 or psk is None:
        print(
            f"[INFO] Device PSK read returned success={success}, flags={hex(flags) if flags else None}"
        )
        return False
    is_valid = psk == PMK_HASH
    print(f"[INFO] Device PMK hash: {psk.hex()} (matches Linux PSK: {is_valid})")
    return is_valid


def write_psk(device: GoodixDevice) -> bool:
    print("[INFO] Writing Linux TLS-PSK whitebox in IAP mode...")
    if not device.preset_psk_write(
        0xBB010003, PSK_WHITE_BOX, 114, 0, PSK_PRE_FLAGS
    ):
        return False
    return check_psk(device)


def load_verified_firmware(fw_path: str) -> tuple[bytes, bytes]:
    if not os.path.isfile(fw_path):
        raise FileNotFoundError(f"Firmware binary not found at: {fw_path}")
    with open(fw_path, "rb") as f:
        firmware = f.read()
    if len(firmware) != EXPECTED_FW_SIZE:
        raise ValueError(
            f"Firmware size mismatch: got {len(firmware)}, expected {EXPECTED_FW_SIZE}"
        )
    sha256_hex = hashlib.sha256(firmware).hexdigest()
    if sha256_hex != EXPECTED_FW_SHA256:
        raise ValueError(
            f"Firmware SHA-256 mismatch: got {sha256_hex}, expected {EXPECTED_FW_SHA256}"
        )

    mod = bytes(range(1, 65))
    raw_pmk = (struct.pack(">H", len(PSK)) + PSK) * 2
    pmk = hashlib.sha256(raw_pmk).digest()
    pmk_hmac = hmac.new(pmk, mod, hashlib.sha256).digest()
    firmware_hmac = hmac.new(pmk_hmac, firmware, hashlib.sha256).digest()
    return firmware, firmware_hmac


def update_firmware(
    device: GoodixDevice, firmware: bytes, firmware_hmac: bytes
) -> None:
    print(f"[INFO] Flashing {TARGET_FIRMWARE} ({len(firmware)} bytes)...")
    try:
        length = len(firmware)
        for offset in range(0, length, 256):
            chunk = firmware[offset : offset + 256]
            if not device.write_firmware(offset, chunk, 2):
                raise RuntimeError(
                    f"Failed to write firmware chunk at offset {offset}"
                )

        print("[INFO] Verifying firmware HMAC signature on MCU...")
        if not device.check_firmware(firmware_hmac):
            raise RuntimeError("MCU rejected firmware HMAC check")
    except Exception as exc:
        print(
            f"[ERROR] Firmware update interrupted ({exc}); keeping sensor safely in IAP mode..."
        )
        try:
            device.mcu_erase_app(50, True)
        except Exception:
            pass
        raise

    print("[INFO] Rebooting sensor MCU into application firmware...")
    device.reset_mcu(50)
    time.sleep(0.3)


def locate_firmware() -> str:
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = [
        os.path.join(script_dir, f"{TARGET_FIRMWARE}.bin"),
        f"/usr/lib/goodix-538d/{TARGET_FIRMWARE}.bin",
        f"/usr/share/goodix-538d/{TARGET_FIRMWARE}.bin",
    ]
    for path in candidates:
        if os.path.isfile(path):
            return path
    return candidates[0]


def main() -> int:
    fw_path = locate_firmware()
    firmware_bytes, firmware_hmac = load_verified_firmware(fw_path)

    device = init_device()
    previous_firmware = None
    unchanged_count = 0

    try:
        for step in range(8):
            try:
                firmware = device.firmware_version()
            except USBError:
                device.close()
                time.sleep(0.25)
                device = init_device()
                firmware = device.firmware_version()

            print(f"[INFO] Sensor firmware: {firmware}")
            valid_psk = check_psk(device)

            if firmware == previous_firmware:
                unchanged_count += 1
                if unchanged_count >= 3:
                    raise RuntimeError(
                        f"Sensor firmware state did not advance from {firmware}"
                    )
            else:
                unchanged_count = 0
            previous_firmware = firmware

            if re.fullmatch(TARGET_FIRMWARE, firmware):
                if valid_psk:
                    print(
                        f"[OK] Goodix 27c6:538d is running {TARGET_FIRMWARE} with valid Linux TLS-PSK."
                    )
                    return 0

                print(
                    "[INFO] Sensor has non-Linux PSK in APP mode; entering IAP bootloader to provision PSK..."
                )
                device.mcu_erase_app(50, True)
                time.sleep(0.35)
                continue

            if re.fullmatch(VALID_FIRMWARE_RE, firmware):
                print(
                    f"[INFO] Erasing {firmware} to update to {TARGET_FIRMWARE}..."
                )
                device.mcu_erase_app(50, True)
                time.sleep(0.35)
                continue

            if re.fullmatch(IAP_FIRMWARE_RE, firmware):
                if not valid_psk:
                    if not write_psk(device):
                        raise RuntimeError(
                            "Failed to write TLS-PSK whitebox in IAP mode"
                        )
                update_firmware(device, firmware_bytes, firmware_hmac)
                device = init_device()
                continue

            raise RuntimeError(f"Unexpected sensor firmware version: {firmware}")

        raise RuntimeError("Exceeded maximum provisioning state transitions")
    finally:
        device.close()


if __name__ == "__main__":
    sys.exit(main())
