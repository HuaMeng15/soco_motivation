#!/bin/bash
#
# Send all result/*/.../output.mp4 over WiFi and measure energy.
# Ensures traffic uses the WiFi interface by binding SSH to the WiFi IP.
#
# Usage: $0 <user@host:path> <wifi_interface>
#   user@host:path   e.g. myuser@192.168.1.10:/home/myuser/recv/
#   wifi_interface   e.g. wlan0 (Linux) or en0 (macOS WiFi)
#
# To skip binding to WiFi (e.g. if server is not reachable via WiFi): SKIP_WIFI_BIND=1 $0 ...
#
# Requires: rsync, ssh, bc. Linux: RAPL (sudo). macOS: powermetrics (sudo). WiFi TX bytes: Linux only.
# On the receiver: ensure SSH allows login and path exists (e.g. mkdir -p /home/myuser/recv).
#

set -e

if ! command -v bc &>/dev/null; then
  echo "Error: 'bc' is required. On macOS: brew install bc"
  exit 1
fi
if [ $# -lt 2 ]; then
  echo "Usage: $0 <user@host:path> <wifi_interface>"
  echo "  Example (Linux): $0 myuser@192.168.1.10:/home/myuser/recv/ wlan0"
  echo "  Example (macOS): $0 myuser@192.168.1.10:/home/myuser/recv/ en0"
  echo "  This sends result/ to the remote path over WiFi and measures energy."
  exit 1
fi

DEST="$1"
WIFI_IF="$2"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/result"
BITRATE=(100 500 1000 2000 3000 5000 7000 10000 20000 50000)
CODEC=(libx264 libx265 libvpx-vp9 libsvtav1 libaom-av1)
# BITRATE=(10000 20000)
# CODEC=(libsvtav1 libaom-av1 libvvenc)

# macOS: use powermetrics; Linux: use RAPL
IS_MACOS=
[ "$(uname -s)" = "Darwin" ] && IS_MACOS=1

if [ -n "$IS_MACOS" ]; then
  POWER_SAMPLER_INTERVAL=10
  SEND_POWER_LOG="${SCRIPT_DIR}/.send_energy_power.log"
else
  RAPL_PATH="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
  if [ ! -f "$RAPL_PATH" ]; then
    echo "RAPL not supported; cannot measure energy."
    exit 1
  fi
fi

# Resolve WiFi interface to IPv4 address (so we bind to WiFi, not eth)
# Portable: no grep -P (macOS grep doesn't support -P)
get_wifi_ip() {
  local iface="$1"
  if [ -z "$iface" ]; then
    echo ""; return
  fi
  local ip
  if command -v ip &>/dev/null; then
    ip=$(ip -4 addr show "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -1)
  fi
  if [ -z "$ip" ]; then
    ip=$(ifconfig "$iface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -1)
  fi
  echo "$ip"
}

if [ -n "${SKIP_WIFI_BIND:-}" ]; then
  WIFI_IP=""
  echo "SKIP_WIFI_BIND set: not binding to WiFi (using default route). Energy will still be measured."
else
  WIFI_IP=$(get_wifi_ip "$WIFI_IF")
  if [ -z "$WIFI_IP" ]; then
    echo "Could not get IP for interface: $WIFI_IF"
    echo "Use a WiFi interface name (e.g. wlan0 on Linux, en0 on macOS) or ensure the interface is up."
    echo "To run without binding to WiFi: SKIP_WIFI_BIND=1 $0 $*"
    exit 1
  fi
  echo "Using WiFi interface $WIFI_IF -> bind address $WIFI_IP (traffic will use WiFi)"
fi

# Optional: verify that the route to the destination host goes via WiFi (Linux only; macOS has no 'ip')
DEST_HOST="${DEST%%:*}"
DEST_HOST="${DEST_HOST#*@}"
if command -v ip &>/dev/null; then
  ROUTE_IF=$(ip route get "$DEST_HOST" 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}' | head -1)
  if [ -n "$ROUTE_IF" ] && [ "$ROUTE_IF" != "$WIFI_IF" ]; then
    echo "Warning: default route to $DEST_HOST uses '$ROUTE_IF', not '$WIFI_IF'. Binding to $WIFI_IP will force WiFi."
  fi
fi

if [ ! -d "$RESULT_DIR" ]; then
  echo "Result directory not found: $RESULT_DIR"
  exit 1
fi

# Build rsync remote path so result/ contents go under DEST (e.g. path/result/)
DEST_USERHOST="${DEST%%:*}"
DEST_PATH="${DEST#*:}"
REMOTE_PATH="${DEST_PATH%/}/result/"
if [ -n "$WIFI_IP" ]; then
  SSH_OPTS="-o BindAddress=$WIFI_IP -o StrictHostKeyChecking=accept-new"
else
  SSH_OPTS="-o StrictHostKeyChecking=accept-new"
fi
# Linux only; on macOS this path does not exist (WiFi TX bytes left empty)
WIFI_TX_PATH="/sys/class/net/${WIFI_IF}/statistics/tx_bytes"

SEND_CSV="${SCRIPT_DIR}/send_energy.csv"
if [ ! -f "$SEND_CSV" ]; then
  echo "Codec,Bitrate,File_bytes,Duration_s,Total_Energy_J,Send_Energy_J,Idle_Power_W,Total_Power_W,Send_Power_W,WiFi_TX_bytes" > "$SEND_CSV"
fi

for codec in ${CODEC[@]}; do
  for bitrate in ${BITRATE[@]}; do
    # ======================
    # Step A: Measure idle power consumption
    # ======================
    sleep 5
    echo "=== Measuring idle power (please keep the server idle) ==="
    if [ -n "$IS_MACOS" ]; then
      idle_power_log=$(mktemp)
      sudo powermetrics -s cpu_power -i "$POWER_SAMPLER_INTERVAL" -n 2 -o "$idle_power_log" 2>/dev/null || true
      power_idle_raw=$(grep -E "CPU Power:|Package power:" "$idle_power_log" 2>/dev/null | tail -1)
      if echo "$power_idle_raw" | grep -q "mW"; then
        power_idle_mw=$(echo "$power_idle_raw" | sed -n 's/.*[Pp]ower:[[:space:]]*\([0-9.]*\)[[:space:]]*mW.*/\1/p')
        power_idle=$(echo "scale=2; ${power_idle_mw:-0} / 1000" | bc 2>/dev/null || echo "0")
      else
        power_idle_w=$(echo "$power_idle_raw" | sed -n 's/.*[Pp]ower:[[:space:]]*\([0-9.]*\)[[:space:]]*W.*/\1/p')
        power_idle=${power_idle_w:-0}
      fi
      rm -f "$idle_power_log"
      echo "Idle Power: ${power_idle} W (macOS powermetrics)"
    else
      e0_idle=$(sudo cat $RAPL_PATH)
      sleep 2
      e1_idle=$(sudo cat $RAPL_PATH)
      power_idle=$(echo "scale=2; ($e1_idle - $e0_idle)/1000000/2" | bc)
      echo "Idle Power: ${power_idle} W"
    fi

    # ======================
    # Step B: Send file
    # ======================
    result_dir="${RESULT_DIR}/${codec}/${bitrate}_1"
    if [ ! -d "$result_dir" ]; then
      continue
    fi
    local_file="${result_dir}/output.mp4"
    if [ "$codec" == "libvvenc" ] || [ "$codec" == "libaom-av1" ] || [ "$codec" == "libsvtav1" ]; then
      local_file="${result_dir}/output.mp4.bak"
    fi
    if [ ! -f "$local_file" ]; then
      echo "No output.mp4 file in $result_dir, skip"
      continue
    fi
    file_bytes=$([ "$(uname -s)" = "Darwin" ] && stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null) || file_bytes="0"
    remote_dir="${REMOTE_PATH}${codec}/${bitrate}/"
    echo "Sending ${codec} ${bitrate} bytes: ${file_bytes} ..."

    # Create remote directory first (rsync does not create parent dirs on receiver)
    ssh $SSH_OPTS "$DEST_USERHOST" "mkdir -p '${REMOTE_PATH}${codec}/${bitrate}'"

    # Measure energy for this single file send
    start=$(python3 -c 'import time; print("%.6f" % time.time())')
    [ -r "$WIFI_TX_PATH" ] && tx0=$(cat "$WIFI_TX_PATH") || tx0=""

    SEND_POWER_LOG=${result_dir}/send_energy_power.log
    if [ -n "$IS_MACOS" ]; then
      : > "$SEND_POWER_LOG"
      # Pipe through while-read so each line is appended immediately (no buffering); otherwise
      # powermetrics -o file keeps data in buffer and we read an empty file after killing it.
      sudo powermetrics -s cpu_power -i "$POWER_SAMPLER_INTERVAL" -n -1 -o "$SEND_POWER_LOG" 2>/dev/null &
      POWER_PID=$!
    else
      e0=$(sudo cat "$RAPL_PATH")
    fi

    rsync -az -e "ssh " "$local_file" "${DEST_USERHOST}:${remote_dir}"

    end=$(python3 -c 'import time; print("%.6f" % time.time())')
    [ -n "$tx0" ] && [ -r "$WIFI_TX_PATH" ] && tx1=$(cat "$WIFI_TX_PATH") || tx1=""

    if [ -n "$IS_MACOS" ]; then
      sudo kill $POWER_PID 2>/dev/null
      wait $POWER_PID 2>/dev/null
      power_samples_w=$(grep -E "CPU Power:|Package power:" "$SEND_POWER_LOG" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -q "mW"; then
          echo "$line" | sed -n 's/.*[Pp]ower:[[:space:]]*\([0-9.]*\)[[:space:]]*mW.*/\1/p' | awk '{print $1/1000}'
        else
          echo "$line" | sed -n 's/.*[Pp]ower:[[:space:]]*\([0-9.]*\)[[:space:]]*W.*/\1/p'
        fi
      done)
      n_samples=$(echo "$power_samples_w" | grep -c . 2>/dev/null || echo 0)
      sum_power=$(echo "$power_samples_w" | awk '{s+=$1} END {print s+0}')
      sample_interval_sec=$(echo "scale=6; $POWER_SAMPLER_INTERVAL / 1000" | bc)
      [ "$n_samples" -gt 0 ] && energy_j=$(echo "scale=6; $sum_power * $sample_interval_sec" | bc) || energy_j=0
      duration=$(echo "scale=6; $end - $start" | bc)
      [ -n "$duration" ] && [ "$(echo "$duration > 0" | bc)" -eq 1 ] && power_total=$(echo "scale=2; $energy_j / $duration" | bc) || power_total=0
    else
      e1=$(sudo cat "$RAPL_PATH")
      energy_uj=$((e1 - e0))
      energy_j=$(echo "scale=6; $energy_uj / 1000000" | bc)
      duration=$(echo "scale=6; $end - $start" | bc)
      power_total=$(echo "scale=2; $energy_j / $duration" | bc)
    fi
    power_send=$(echo "scale=2; $power_total - $power_idle" | bc)
    energy_send=$(echo "scale=6; $energy_j - $power_idle * $duration" | bc)
    tx_delta=""
    if [ -n "$tx0" ] && [ -n "$tx1" ]; then
      tx_delta=$((tx1 - tx0))
    fi
    echo "  ${duration} s, ${energy_j} J, ${power_send} W"
    # Debug: if WiFi was used, tx_delta should be ~file size (+ overhead). 0 => traffic likely went via another interface (e.g. eth).
    if [ -n "$tx_delta" ]; then
      if [ "$tx_delta" -eq 0 ]; then
        echo "  WARNING: WiFi (${WIFI_IF}) tx_delta=0 — transfer may have used Ethernet, not WiFi. Check: run with same network on receiver as WiFi (e.g. 10.89.x.x)."
      else
        echo "  WiFi TX: ${tx_delta} bytes (confirms traffic over ${WIFI_IF})"
      fi
    fi
    echo "${codec},${bitrate},${file_bytes},${duration},${energy_j},${energy_send},${power_idle},${power_total},${power_send},${tx_delta:-}" >> "$SEND_CSV"
  done
done

echo "Logged per-file send energy to $SEND_CSV"
