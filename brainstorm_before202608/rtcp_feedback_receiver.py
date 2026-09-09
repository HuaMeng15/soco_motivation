#!/usr/bin/env python3
"""Receive synthetic RTCP feedback packets and summarize what arrived."""

from __future__ import annotations

import argparse
import json
import signal
import socket
import struct
import time
from pathlib import Path


STOP = False


def _handle_stop(_signum, _frame):
    global STOP
    STOP = True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Receive UDP RTCP-like feedback packets and write a JSON summary."
    )
    parser.add_argument("--bind-ip", default="0.0.0.0", help="Local IP to bind.")
    parser.add_argument("--port", type=int, default=5005, help="UDP port to listen on.")
    parser.add_argument(
        "--expected-packets",
        type=int,
        default=0,
        help="Optional packet count to stop on. 0 means run until idle timeout or signal.",
    )
    parser.add_argument(
        "--idle-timeout-sec",
        type=float,
        default=3.0,
        help="Stop after this many seconds without packets once traffic has started.",
    )
    parser.add_argument(
        "--max-runtime-sec",
        type=float,
        default=0.0,
        help="Optional hard stop even if no packets arrive. 0 means disabled.",
    )
    parser.add_argument(
        "--output-json",
        required=True,
        help="Path to write the receiver summary JSON.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    signal.signal(signal.SIGINT, _handle_stop)
    signal.signal(signal.SIGTERM, _handle_stop)

    out_path = Path(args.output_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.bind_ip, args.port))
    sock.settimeout(0.5)

    total_packets = 0
    total_payload_bytes = 0
    malformed_packets = 0
    min_payload_bytes = None
    max_payload_bytes = 0
    first_packet_ts = None
    last_packet_ts = None
    first_sender = None
    start_ts = time.time()

    while not STOP:
        now = time.time()
        if args.max_runtime_sec > 0 and now - start_ts >= args.max_runtime_sec:
            break
        if (
            first_packet_ts is not None
            and now - last_packet_ts >= args.idle_timeout_sec
        ):
            break
        if args.expected_packets > 0 and total_packets >= args.expected_packets:
            break

        try:
            data, addr = sock.recvfrom(65535)
        except socket.timeout:
            continue

        recv_ts = time.time()
        if first_packet_ts is None:
            first_packet_ts = recv_ts
            first_sender = {"ip": addr[0], "port": addr[1]}
        last_packet_ts = recv_ts
        total_packets += 1
        payload_len = len(data)
        total_payload_bytes += payload_len
        min_payload_bytes = payload_len if min_payload_bytes is None else min(
            min_payload_bytes, payload_len
        )
        max_payload_bytes = max(max_payload_bytes, payload_len)

        if payload_len < 4:
            malformed_packets += 1
            continue

        expected_payload_len = (struct.unpack("!H", data[2:4])[0] + 1) * 4
        if expected_payload_len != payload_len:
            malformed_packets += 1

    sock.close()

    duration_sec = 0.0
    if first_packet_ts is not None and last_packet_ts is not None:
        duration_sec = max(0.0, last_packet_ts - first_packet_ts)

    summary = {
        "bind_ip": args.bind_ip,
        "port": args.port,
        "expected_packets": args.expected_packets,
        "total_packets": total_packets,
        "total_payload_bytes": total_payload_bytes,
        "malformed_packets": malformed_packets,
        "min_payload_bytes": min_payload_bytes or 0,
        "max_payload_bytes": max_payload_bytes,
        "duration_sec": duration_sec,
        "first_sender": first_sender,
        "started_receiving": first_packet_ts is not None,
        "stopped_by_signal": STOP,
        "idle_timeout_sec": args.idle_timeout_sec,
        "max_runtime_sec": args.max_runtime_sec,
        "completed_at_unix_sec": time.time(),
    }

    out_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
