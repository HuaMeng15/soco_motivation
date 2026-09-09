#!/bin/bash
#
# Compare immediate RTCP feedback vs grouped-per-frame RTCP feedback.
# Local machine runs the UDP receiver. Remote Linux host (e.g. myserver) sends
# RTCP-like packets over WiFi and measures energy/CPU/context-switch counters.
#
# Usage:
#   ./test_rtcp_feedback_energy.sh myserver wlan0 en0
#   ./test_rtcp_feedback_energy.sh myserver wlan0 en0 30 5005 3
#
# Args:
#   $1 remote host alias or user@host
#   $2 remote WiFi interface used for tx_bytes/RAPL test context
#   $3 local WiFi interface used to resolve the reachable local IP
#   $4 duration seconds per run (default: 30)
#   $5 UDP port on local receiver (default: 5005)
#   $6 repeats per mode (default: 3)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_HOST="${1:-}"
REMOTE_WIFI_IF="${2:-}"
LOCAL_WIFI_IF="${3:-}"
DURATION_SEC="${4:-30}"
PORT="${5:-5005}"
REPEATS="${6:-3}"

FPS="${FPS:-30}"
PACKETS_PER_FRAME="${PACKETS_PER_FRAME:-100}"
ENTRY_BYTES="${ENTRY_BYTES:-12}"
INTRA_FRAME_MODE="${INTRA_FRAME_MODE:-burst}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/rtcp_feedback_energy}"
LOCAL_RESULTS_DIR="${LOCAL_RESULTS_DIR:-${SCRIPT_DIR}/rtcp_feedback_results}"
CSV_PATH="${CSV_PATH:-${SCRIPT_DIR}/rtcp_feedback_energy.csv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SKIP_ENERGY="${SKIP_ENERGY:-0}"

if [ -z "$REMOTE_HOST" ] || [ -z "$REMOTE_WIFI_IF" ] || [ -z "$LOCAL_WIFI_IF" ]; then
  echo "Usage: $0 <remote_host> <remote_wifi_if> <local_wifi_if> [duration_sec] [port] [repeats]"
  exit 1
fi

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "python3 is required"
  exit 1
fi

get_iface_ip() {
  local iface="$1"
  local ip=""
  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
  fi
  if [ -z "$ip" ]; then
    ip=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2}' | head -1)
  fi
  echo "$ip"
}

LOCAL_IP="$(get_iface_ip "$LOCAL_WIFI_IF")"
if [ -z "$LOCAL_IP" ]; then
  echo "Could not resolve an IPv4 address for local interface: $LOCAL_WIFI_IF"
  exit 1
fi

mkdir -p "$LOCAL_RESULTS_DIR"

if [ ! -f "$CSV_PATH" ]; then
  echo "RunLabel,Mode,Repeat,RequestedDurationSec,MeasuredDurationSec,FPS,PacketsPerFrame,EntryBytes,SingleFeedbackPacketBytes,GroupedFeedbackPacketBytes,GroupedPayloadExceedsSafeUdpPayload,FeedbackEntries,SendCalls,SenderPackets,SenderPayloadBytes,SenderIfaceTxBytes,IdlePowerW,TotalEnergyJ,SenderOnlyEnergyJ,TotalPowerW,SenderOnlyPowerW,SystemCpuAvgPct,SystemCpuMaxPct,UserCpuSec,SysCpuSec,VoluntaryCtxSwitches,InvoluntaryCtxSwitches,RouteIface,ReceiverPackets,ReceiverPayloadBytes,ReceiverMalformedPackets,ReceiverDurationSec,ReceiverMinPayloadBytes,ReceiverMaxPayloadBytes" > "$CSV_PATH"
fi

echo "Using local WiFi IP: $LOCAL_IP on $LOCAL_WIFI_IF"
echo "Copying sender script to $REMOTE_HOST:$REMOTE_DIR"
ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR'"
scp "${SCRIPT_DIR}/rtcp_feedback_sender.py" "${REMOTE_HOST}:${REMOTE_DIR}/"

run_mode() {
  local mode="$1"
  local repeat="$2"
  local run_label="${mode}_r${repeat}_$(date +%Y%m%d_%H%M%S)"
  local expected_packets
  expected_packets=$(
    "$PYTHON_BIN" - "$mode" "$DURATION_SEC" "$FPS" "$PACKETS_PER_FRAME" <<'PY'
import sys

mode, duration_sec, fps, packets_per_frame = sys.argv[1:]
total_frames = max(1, int(round(float(duration_sec) * int(fps))))
if mode == "immediate":
    print(total_frames * int(packets_per_frame))
else:
    print(total_frames)
PY
  )

  local receiver_json="${LOCAL_RESULTS_DIR}/${run_label}_receiver.json"
  local sender_json_remote="${REMOTE_DIR}/${run_label}_sender.json"
  local sender_json_local="${LOCAL_RESULTS_DIR}/${run_label}_sender.json"

  echo "Starting local receiver for ${mode}, repeat ${repeat}"
  "$PYTHON_BIN" "${SCRIPT_DIR}/rtcp_feedback_receiver.py" \
    --bind-ip "$LOCAL_IP" \
    --port "$PORT" \
    --expected-packets "$expected_packets" \
    --idle-timeout-sec 3 \
    --output-json "$receiver_json" &
  local receiver_pid=$!
  trap 'kill "$receiver_pid" 2>/dev/null || true' RETURN
  sleep 1

  local remote_cmd=(
    cd "$REMOTE_DIR"
    "&&" "$PYTHON_BIN" rtcp_feedback_sender.py
    --dest-ip "$LOCAL_IP"
    --port "$PORT"
    --mode "$mode"
    --duration-sec "$DURATION_SEC"
    --fps "$FPS"
    --packets-per-frame "$PACKETS_PER_FRAME"
    --entry-bytes "$ENTRY_BYTES"
    --intra-frame-mode "$INTRA_FRAME_MODE"
    --iface "$REMOTE_WIFI_IF"
    --output-json "$sender_json_remote"
  )
  if [ "$SKIP_ENERGY" = "1" ]; then
    remote_cmd+=(--skip-energy)
  fi
  local remote_cmd_str=""
  printf -v remote_cmd_str '%q ' "${remote_cmd[@]}"

  echo "Running remote sender on $REMOTE_HOST for ${mode}, repeat ${repeat}"
  ssh "$REMOTE_HOST" "$remote_cmd_str"

  wait "$receiver_pid"
  trap - RETURN
  scp "${REMOTE_HOST}:${sender_json_remote}" "$sender_json_local"

  "$PYTHON_BIN" - "$CSV_PATH" "$run_label" "$mode" "$repeat" "$receiver_json" "$sender_json_local" <<'PY'
import csv
import json
import sys

csv_path, run_label, mode, repeat, receiver_path, sender_path = sys.argv[1:]
with open(receiver_path, "r", encoding="utf-8") as fh:
    receiver = json.load(fh)
with open(sender_path, "r", encoding="utf-8") as fh:
    sender = json.load(fh)

row = [
    run_label,
    mode,
    repeat,
    sender.get("requested_duration_sec"),
    sender.get("duration_sec"),
    sender.get("fps"),
    sender.get("packets_per_frame"),
    sender.get("entry_bytes"),
    sender.get("single_feedback_packet_bytes"),
    sender.get("grouped_feedback_packet_bytes"),
    sender.get("grouped_payload_exceeds_safe_udp_payload"),
    sender.get("feedback_entries"),
    sender.get("send_calls"),
    sender.get("packet_count"),
    sender.get("payload_bytes"),
    sender.get("iface_tx_bytes"),
    sender.get("idle_power_w"),
    sender.get("total_energy_j"),
    sender.get("sender_only_energy_j"),
    sender.get("total_power_w"),
    sender.get("sender_only_power_w"),
    sender.get("cpu_avg_pct"),
    sender.get("cpu_max_pct"),
    sender.get("user_cpu_sec"),
    sender.get("sys_cpu_sec"),
    sender.get("voluntary_ctx_switches"),
    sender.get("involuntary_ctx_switches"),
    sender.get("route_iface"),
    receiver.get("total_packets"),
    receiver.get("total_payload_bytes"),
    receiver.get("malformed_packets"),
    receiver.get("duration_sec"),
    receiver.get("min_payload_bytes"),
    receiver.get("max_payload_bytes"),
]

with open(csv_path, "a", encoding="utf-8", newline="") as fh:
    csv.writer(fh).writerow(row)
PY
}

for mode in immediate grouped; do
  repeat=1
  while [ "$repeat" -le "$REPEATS" ]; do
    run_mode "$mode" "$repeat"
    repeat=$((repeat + 1))
    sleep 2
  done
done

echo "Finished. Results:"
echo "  CSV:  $CSV_PATH"
echo "  JSON: $LOCAL_RESULTS_DIR"
