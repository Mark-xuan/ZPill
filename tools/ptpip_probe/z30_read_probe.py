"""Isolated single-JPEG Nikon STA read and timing probe."""

import argparse
import json
import socket
import struct
import time
from pathlib import Path

import probe as ptp


def run(cmd, args):
    tid = ptp.Tid()
    if ptp.open_session_with_heal(cmd, tid) != ptp.PTP_OK:
        raise ptp.ProtocolError("Could not open PTP session")
    changed_mode = False
    cursor_started = False
    high_speed = args.route == "highspeed"
    handle = args.handle

    def transact(opcode, params=(), data_in=True):
        start = time.perf_counter()
        tx, data, stats, (rc, echoed, returned) = ptp.cmd_xact(
            cmd, tid, opcode, params,
            dp=ptp.DP_DATA_IN if data_in else ptp.DP_NO_DATA,
        )
        elapsed = time.perf_counter() - start
        print(f"op=0x{opcode:04X} tid={tx} params={list(params)} "
              f"rc=0x{rc:04X} bytes={len(data)} response={returned} "
              f"elapsed_ms={elapsed * 1000:.1f}", flush=True)
        if tx != echoed or (stats["declared"] is not None
                            and stats["declared"] != len(data)):
            raise ptp.ProtocolError("Transaction ID or data length mismatch")
        return rc, data, returned

    def require_ok(result):
        rc, data, returned = result
        if rc != ptp.PTP_OK:
            raise ptp.ProtocolError(f"Camera returned 0x{rc:04X}")
        return data, returned

    try:
        handles, _ = require_ok(transact(ptp.GET_OBJECT_HANDLES, [0xFFFFFFFF, 0, 0]))
        count, = struct.unpack_from("<I", handles)
        if len(handles) != 4 + count * 4:
            raise ptp.ProtocolError("Invalid handle list")
        objects = [value for (value,) in struct.iter_unpack("<I", handles[4:])]
        if handle not in objects:
            print(f"Current session handles ({count}): {objects}")
            if handle is None:
                return
            raise ptp.ProtocolError("Requested handle absent in this session")
        size_data, _ = require_ok(transact(0x9421, [handle]))
        if len(size_data) != 8:
            raise ptp.ProtocolError("Unexpected GetObjectSize layout")
        size, = struct.unpack("<Q", size_data)
        if size < 4 or (args.expect_bytes is not None and size != args.expect_bytes):
            raise ptp.ProtocolError(f"Unexpected object size: {size} bytes")
        print(f"Object {handle}: {size} bytes")
        if args.enable_application_mode:
            require_ok(transact(0x9435, [1], data_in=False))
            changed_mode = True

        offset = 0
        last_bytes = b""
        start = time.perf_counter()
        while offset < size:
            want = min(args.chunk_kib * 1024, size - offset)
            if high_speed:
                rc, data, returned = transact(0x9400, [handle, want, 0])
                cursor_started = rc == ptp.PTP_OK or cursor_started
                data, returned = require_ok((rc, data, returned))
                if (len(returned) < 3 or returned[0] != len(data)
                        or (returned[1] | (returned[2] << 32)) != offset):
                    raise ptp.ProtocolError(f"Invalid high-speed cursor at {offset}")
            else:
                data, _ = require_ok(transact(
                    0x9431, [handle, offset & 0xFFFFFFFF, offset >> 32, want, 0]))
            if not data or len(data) > want:
                raise ptp.ProtocolError(f"Unexpected block length at {offset}")
            if offset == 0 and not data.startswith(b"\xff\xd8"):
                raise ptp.ProtocolError("Object does not begin with JPEG SOI")
            offset += len(data)
            last_bytes = (last_bytes + data[-2:])[-2:]
            if not args.full:
                break
        elapsed = time.perf_counter() - start
        if offset == size and last_bytes != b"\xff\xd9":
            raise ptp.ProtocolError("Object does not end with JPEG EOI")
        print(f"RESULT route={args.route} bytes={offset}/{size} "
              f"elapsed_s={elapsed:.3f} MB/s={offset / elapsed / 1e6:.3f}")
    finally:
        try:
            if cursor_started:
                require_ok(transact(0x9400, [handle, 0, 1]))
        finally:
            try:
                if changed_mode:
                    require_ok(transact(0x9435, [0], data_in=False))
            finally:
                require_ok(transact(ptp.CLOSE_SESSION, data_in=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("--port", type=int, default=ptp.PORT)
    parser.add_argument("--client-identity", type=Path)
    parser.add_argument("--handle", type=lambda value: int(value, 0))
    parser.add_argument("--expect-bytes", type=int)
    parser.add_argument("--route", choices=("highspeed", "extended"), default="highspeed")
    parser.add_argument("--chunk-kib", type=int, choices=(512, 1024, 2048), default=512)
    parser.add_argument("--enable-application-mode", action="store_true")
    parser.add_argument("--full", action="store_true")
    args = parser.parse_args()
    if args.enable_application_mode and (args.route != "highspeed" or args.handle is None):
        parser.error("--enable-application-mode requires highspeed and --handle")
    name, guid = "Android Device", ptp.NIKON_ANDROID_GUID
    try:
        if args.client_identity:
            identity = json.loads(args.client_identity.read_text(encoding="utf-8-sig"))
            name, guid = identity["name"], bytes.fromhex(identity["uuid"])
            if not isinstance(name, str) or not name or "\0" in name or len(guid) != 16:
                raise ValueError("Invalid ZPill client identity")
        address = (args.host, args.port)
        with socket.create_connection(address, timeout=ptp.READ_TIMEOUT) as cmd:
            cmd.sendall(ptp.init_command_request(name, guid))
            packet_type, body = ptp.read_packet(cmd)
            if packet_type != ptp.INIT_CMD_RESP:
                raise ptp.ProtocolError(ptp.describe(packet_type, body))
            connection, = struct.unpack_from("<I", body)
            with socket.create_connection(address, timeout=ptp.READ_TIMEOUT) as evt:
                evt.sendall(ptp.init_event_request(connection))
                packet_type, body = ptp.read_packet(evt)
                if packet_type != ptp.INIT_EVENT_RESP:
                    raise ptp.ProtocolError(ptp.describe(packet_type, body))
                run(cmd, args)
    except (OSError, ValueError, KeyError, TypeError, struct.error, ptp.ProtocolError) as exc:
        print(f"ERROR: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
