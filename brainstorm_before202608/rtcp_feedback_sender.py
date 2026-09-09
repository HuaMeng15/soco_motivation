#!/usr/bin/env python3
"""Send synthetic RTCP feedback packets and measure Linux energy/CPU stats."""

from __future__ import annotations

import argparse
import json
import os
import resource
import shutil
import socket
import struct
import subprocess
import threading
import time
from pathlib import Path


DEFAULT_RAPL_PATH = "/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
DEFAULT_SAFE_UDP_PAYLOAD_BYTES = 1472
DEFAULT_RAPL_HELPER = "/usr/local/bin/read_rapl_energy"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send RTCP-like UDP feedback packets and measure Linux energy."
    )
    parser.add_argument("--dest-ip", required=True, help="Destination IP address.")
    parser.add_argument("--port", type=int, required=True, help="Destination UDP port.")
    parser.add_argument(
        "--mode",
        choices=("immediate", "grouped"),
        required=True,
        help="Immediate: 100 RTCP sends per frame. Grouped: 1 RTCP send per frame with 100 entries.",
    )
    parser.add_argument("--duration-sec", type=float, default=30.0, help="Test duration.")
    parser.add_argument("--fps", type=int, default=30, help="Frames per second.")
    parser.add_argument(
        "--packets-per-frame",
        type=int,
        default=100,
        help="Media packets per frame, and feedback entries per frame.",
    )
    parser.add_argument(
        "--entry-bytes",
        type=int,
        default=12,
        help="Bytes per feedback entry. Must be >= 12 and divisible by 4.",
    )
    parser.add_argument(
        "--intra-frame-mode",
        choices=("burst", "spread"),
        default="burst",
        help="How immediate-mode packets are paced inside a frame.",
    )
    parser.add_argument(
        "--iface",
        default="",
        help="Optional Linux interface name for tx_bytes accounting or socket binding.",
    )
    parser.add_argument(
        "--bind-ip",
        default="",
        help="Optional source IPv4 address to bind the UDP socket to before connect().",
    )
    parser.add_argument(
        "--rapl-path",
        default=DEFAULT_RAPL_PATH,
        help="RAPL energy_uj path on the Linux sender.",
    )
    parser.add_argument(
        "--rapl-helper",
        default=DEFAULT_RAPL_HELPER,
        help="Optional helper command that prints RAPL energy_uj, e.g. /usr/local/bin/read_rapl_energy.",
    )
    parser.add_argument(
        "--idle-sample-sec",
        type=float,
        default=2.0,
        help="Seconds used to estimate idle power before sending.",
    )
    parser.add_argument(
        "--monitor-interval-sec",
        type=float,
        default=0.1,
        help="Sampling interval for system CPU usage.",
    )
    parser.add_argument(
        "--skip-energy",
        action="store_true",
        help="Skip RAPL reads and report energy as null.",
    )
    parser.add_argument(
        "--output-json",
        required=True,
        help="Where to write the sender summary JSON.",
    )
    return parser.parse_args()


def read_int(path: str) -> int:
    with open(path, "r", encoding="utf-8") as fh:
        return int(fh.read().strip())


def read_energy_uj(rapl_path: str, rapl_helper: str) -> int:
    try:
        return read_int(rapl_path)
    except PermissionError:
        helper_path = shutil.which(rapl_helper) if os.path.sep not in rapl_helper else rapl_helper
        if helper_path and os.path.exists(helper_path):
            result = subprocess.run(
                ["sudo", "-n", helper_path, "pkg"],
                check=True,
                capture_output=True,
                text=True,
            )
            return int(result.stdout.strip())
        result = subprocess.run(
            ["sudo", "-n", "cat", rapl_path],
            check=True,
            capture_output=True,
            text=True,
        )
        return int(result.stdout.strip())


def maybe_read_energy_uj(rapl_path: str, rapl_helper: str, skip_energy: bool) -> int | None:
    if skip_energy:
        return None
    return read_energy_uj(rapl_path, rapl_helper)


def maybe_read_tx_bytes(iface: str) -> int | None:
    if not iface:
        return None
    path = f"/sys/class/net/{iface}/statistics/tx_bytes"
    if not os.path.exists(path):
        return None
    try:
        return read_int(path)
    except (PermissionError, OSError, ValueError):
        return None


def get_route_iface(dest_ip: str) -> str:
    if shutil.which("ip") is None:
        return ""
    result = subprocess.run(
        ["ip", "route", "get", dest_ip],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    parts = result.stdout.strip().split()
    for idx, token in enumerate(parts):
        if token == "dev" and idx + 1 < len(parts):
            return parts[idx + 1]
    return ""


def get_iface_ipv4(iface: str) -> str:
    if not iface or shutil.which("ip") is None:
        return ""
    result = subprocess.run(
        ["ip", "-4", "addr", "show", "dev", iface],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    for line in result.stdout.splitlines():
        line = line.strip()
        if line.startswith("inet "):
            return line.split()[1].split("/")[0]
    return ""


def build_entry(packet_id: int, recv_ts_us: int, entry_bytes: int) -> bytes:
    base = struct.pack("!IIHH", packet_id & 0xFFFFFFFF, recv_ts_us & 0xFFFFFFFF, 0, 0)
    if entry_bytes == len(base):
        return base
    padding = bytearray(entry_bytes - len(base))
    for idx in range(len(padding)):
        padding[idx] = (packet_id + idx) & 0xFF
    return base + bytes(padding)


def build_rtcp_payload(entries: list[bytes]) -> bytes:
    feedback_control_info = b"".join(entries)
    packet = (
        struct.pack("!BBH", 0x80 | 15, 205, 0)
        + struct.pack("!II", 0x10203040, 0x55667788)
        + feedback_control_info
    )
    length_words = len(packet) // 4 - 1
    return struct.pack("!BBH", 0x80 | 15, 205, length_words) + packet[4:]


def busy_wait_until(target: float) -> None:
    while True:
        remaining = target - time.perf_counter()
        if remaining <= 0:
            return
        if remaining > 0.002:
            time.sleep(remaining - 0.001)
        else:
            time.sleep(0)


class CpuMonitor:
    def __init__(self, interval_sec: float):
        self.interval_sec = interval_sec
        self.samples: list[float] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join()

    def _run(self) -> None:
        prev_total = None
        prev_idle = None
        while not self._stop.is_set():
            with open("/proc/stat", "r", encoding="utf-8") as fh:
                fields = fh.readline().strip().split()
            values = [int(value) for value in fields[1:]]
            total = sum(values)
            idle = values[3] + (values[4] if len(values) > 4 else 0)
            if prev_total is not None and total > prev_total:
                usage = 100.0 * (1.0 - ((idle - prev_idle) / (total - prev_total)))
                self.samples.append(max(0.0, usage))
            prev_total = total
            prev_idle = idle
            self._stop.wait(self.interval_sec)


def main() -> int:
    args = parse_args()
    if args.entry_bytes < 12 or args.entry_bytes % 4 != 0:
        raise SystemExit("--entry-bytes must be >= 12 and divisible by 4")

    total_frames = max(1, int(round(args.duration_sec * args.fps)))
    frame_interval_sec = 1.0 / args.fps
    iface_tx_path = f"/sys/class/net/{args.iface}/statistics/tx_bytes" if args.iface else ""
    source_bind_ip = args.bind_ip or get_iface_ipv4(args.iface)

    idle_power_w = None
    if not args.skip_energy:
        e0_idle = read_energy_uj(args.rapl_path, args.rapl_helper)
        time.sleep(args.idle_sample_sec)
        e1_idle = read_energy_uj(args.rapl_path, args.rapl_helper)
        idle_power_w = (e1_idle - e0_idle) / 1_000_000.0 / args.idle_sample_sec

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if args.iface and hasattr(socket, "SO_BINDTODEVICE"):
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, args.iface.encode() + b"\0")
        except OSError:
            pass
    if source_bind_ip:
        sock.bind((source_bind_ip, 0))
    sock.connect((args.dest_ip, args.port))
    route_iface = get_route_iface(args.dest_ip)

    cpu_monitor = CpuMonitor(args.monitor_interval_sec)
    usage0 = resource.getrusage(resource.RUSAGE_SELF)
    tx0 = maybe_read_tx_bytes(args.iface)
    energy0 = maybe_read_energy_uj(args.rapl_path, args.rapl_helper, args.skip_energy)
    cpu_monitor.start()
    start_perf = time.perf_counter()
    start_wall = time.time()

    send_calls = 0
    packet_count = 0
    payload_bytes = 0
    feedback_entries = 0
    packet_id = 0

    for frame_idx in range(total_frames):
        frame_start = start_perf + frame_idx * frame_interval_sec
        frame_entries = []
        for packet_idx in range(args.packets_per_frame):
            recv_ts_us = int((start_wall + frame_idx * frame_interval_sec) * 1_000_000)
            entry = build_entry(packet_id, recv_ts_us + packet_idx, args.entry_bytes)
            frame_entries.append(entry)
            packet_id += 1

        if args.mode == "grouped":
            busy_wait_until(frame_start + frame_interval_sec)
            payload = build_rtcp_payload(frame_entries)
            sock.send(payload)
            send_calls += 1
            packet_count += 1
            feedback_entries += len(frame_entries)
            payload_bytes += len(payload)
            continue

        if args.intra_frame_mode == "spread":
            for packet_idx, entry in enumerate(frame_entries):
                target = frame_start + ((packet_idx + 1) * frame_interval_sec / args.packets_per_frame)
                busy_wait_until(target)
                payload = build_rtcp_payload([entry])
                sock.send(payload)
                send_calls += 1
                packet_count += 1
                feedback_entries += 1
                payload_bytes += len(payload)
        else:
            busy_wait_until(frame_start)
            for entry in frame_entries:
                payload = build_rtcp_payload([entry])
                sock.send(payload)
                send_calls += 1
                packet_count += 1
                feedback_entries += 1
                payload_bytes += len(payload)
            busy_wait_until(frame_start + frame_interval_sec)

    end_perf = time.perf_counter()
    end_wall = time.time()
    cpu_monitor.stop()
    energy1 = maybe_read_energy_uj(args.rapl_path, args.rapl_helper, args.skip_energy)
    tx1 = maybe_read_tx_bytes(args.iface)
    usage1 = resource.getrusage(resource.RUSAGE_SELF)
    sock.close()

    duration_sec = end_perf - start_perf
    energy_j = None
    total_power_w = None
    sender_only_energy_j = None
    sender_only_power_w = None
    if energy0 is not None and energy1 is not None:
        energy_j = (energy1 - energy0) / 1_000_000.0
        total_power_w = energy_j / duration_sec if duration_sec > 0 else 0.0
        if idle_power_w is not None:
            sender_only_energy_j = energy_j - idle_power_w * duration_sec
            sender_only_power_w = total_power_w - idle_power_w

    tx_bytes = tx1 - tx0 if tx0 is not None and tx1 is not None else None
    cpu_avg = sum(cpu_monitor.samples) / len(cpu_monitor.samples) if cpu_monitor.samples else 0.0
    cpu_max = max(cpu_monitor.samples) if cpu_monitor.samples else 0.0
    user_cpu_sec = usage1.ru_utime - usage0.ru_utime
    sys_cpu_sec = usage1.ru_stime - usage0.ru_stime
    vol_ctx = usage1.ru_nvcsw - usage0.ru_nvcsw
    invol_ctx = usage1.ru_nivcsw - usage0.ru_nivcsw

    summary = {
        "dest_ip": args.dest_ip,
        "port": args.port,
        "mode": args.mode,
        "duration_sec": duration_sec,
        "requested_duration_sec": args.duration_sec,
        "fps": args.fps,
        "frames_sent": total_frames,
        "packets_per_frame": args.packets_per_frame,
        "entry_bytes": args.entry_bytes,
        "single_feedback_packet_bytes": 12 + args.entry_bytes,
        "grouped_feedback_packet_bytes": 12 + args.entry_bytes * args.packets_per_frame,
        "grouped_payload_exceeds_safe_udp_payload": (
            12 + args.entry_bytes * args.packets_per_frame
        ) > DEFAULT_SAFE_UDP_PAYLOAD_BYTES,
        "intra_frame_mode": args.intra_frame_mode,
        "feedback_entries": feedback_entries,
        "send_calls": send_calls,
        "packet_count": packet_count,
        "payload_bytes": payload_bytes,
        "route_iface": route_iface,
        "iface": args.iface,
        "source_bind_ip": source_bind_ip,
        "rapl_helper": args.rapl_helper,
        "iface_tx_path": iface_tx_path,
        "iface_tx_bytes": tx_bytes,
        "idle_power_w": idle_power_w,
        "total_energy_j": energy_j,
        "sender_only_energy_j": sender_only_energy_j,
        "total_power_w": total_power_w,
        "sender_only_power_w": sender_only_power_w,
        "cpu_avg_pct": cpu_avg,
        "cpu_max_pct": cpu_max,
        "user_cpu_sec": user_cpu_sec,
        "sys_cpu_sec": sys_cpu_sec,
        "voluntary_ctx_switches": vol_ctx,
        "involuntary_ctx_switches": invol_ctx,
        "completed_at_unix_sec": end_wall,
    }

    out_path = Path(args.output_json)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
