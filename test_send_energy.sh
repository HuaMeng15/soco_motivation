#!/bin/bash
#
# Send all result/*/.../output.mp4 over WiFi and measure energy (RAPL).
# Ensures traffic uses the WiFi interface by binding SSH to the WiFi IP.
#
# Usage: $0 <user@host:path> <wifi_interface>
#   user@host:path   e.g. myuser@192.168.1.10:/home/myuser/recv/
#   wifi_interface   e.g. wlan0 (script will use this interface's IP for binding)
#
# Requires: rsync, ssh, bc. RAPL: /sys/class/powercap/intel-rapl/ (sudo read).
# On the receiver: ensure SSH allows login and path exists (e.g. mkdir -p /home/myuser/recv).
#

set -e

if [ $# -lt 2 ]; then
  echo "Usage: $0 <user@host:path> <wifi_interface>"
  echo "  Example: $0 myuser@192.168.1.10:/home/myuser/recv/ wlan0"
  echo "  This sends result/ to the remote path over WiFi and measures energy."
  exit 1
fi

DEST="$1"
WIFI_IF="$2"
RAPL_PATH="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULT_DIR="${SCRIPT_DIR}/result"
BITRATE=(100 200 500 700 1000 2000 3000 4000 5000 7000 10000 20000 30000 50000)
CODEC=(libx264 libx265 libvpx-vp9 libsvtav1 libaom-av1 libvvenc)
# BITRATE=(10000 20000)
CODEC=(libsvtav1 libaom-av1 libvvenc)

if [ ! -f "$RAPL_PATH" ]; then
  echo "RAPL not supported; cannot measure energy."
  exit 1
fi

# Resolve WiFi interface to IPv4 address (so we bind to WiFi, not eth)
get_wifi_ip() {
  local iface="$1"
  if [ -z "$iface" ]; then
    echo ""; return
  fi
  # Prefer 'ip'; fallback to 'ifconfig'
  local ip
  ip=$(ip -4 addr show "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
  if [ -z "$ip" ]; then
    ip=$(ifconfig "$iface" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
  fi
  echo "$ip"
}

WIFI_IP=$(get_wifi_ip "$WIFI_IF")
if [ -z "$WIFI_IP" ]; then
  echo "Could not get IP for interface: $WIFI_IF"
  echo "Use a WiFi interface name (e.g. wlan0) or ensure the interface is up."
  exit 1
fi
echo "Using WiFi interface $WIFI_IF -> bind address $WIFI_IP (traffic will use WiFi)"

# Optional: verify that the route to the destination host goes via WiFi
DEST_HOST="${DEST%%:*}"
DEST_HOST="${DEST_HOST#*@}"
if command -v ip &>/dev/null; then
  ROUTE_IF=$(ip route get "$DEST_HOST" 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
  if [ -n "$ROUTE_IF" ] && [ "$ROUTE_IF" != "$WIFI_IF" ]; then
    echo "Warning: default route to $DEST_HOST uses '$ROUTE_IF', not '$WIFI_IF'. Binding to $WIFI_IP will force WiFi."
  fi
  # If receiver is on a different subnet than WiFi (e.g. eth=143.x, wifi=10.x), SSH BindAddress=WiFi_IP can still work,
  # but the receiver must be reachable from the WiFi subnet. If tx_delta stays 0, receiver may be only reachable via eth.
fi

if [ ! -d "$RESULT_DIR" ]; then
  echo "Result directory not found: $RESULT_DIR"
  exit 1
fi

# Build rsync remote path so result/ contents go under DEST (e.g. path/result/)
DEST_USERHOST="${DEST%%:*}"
DEST_PATH="${DEST#*:}"
REMOTE_PATH="${DEST_PATH%/}/result/"
SSH_OPTS="-o BindAddress=$WIFI_IP -o StrictHostKeyChecking=accept-new"
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
    echo "=== Measuring idle power (please keep the server idle) ==="
    sleep 1
    e0_idle=$(sudo cat $RAPL_PATH)
    sleep 2
    e1_idle=$(sudo cat $RAPL_PATH)
    power_idle=$(echo "scale=2; ($e1_idle - $e0_idle)/1000000/2" | bc)
    echo "Idle Power: ${power_idle} W"

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
    file_bytes=$(stat -c%s "$local_file" 2>/dev/null || echo "0")
    remote_dir="${REMOTE_PATH}${codec}/${bitrate}/"
    echo "Sending ${codec} ${bitrate} bytes: ${file_bytes} ..."

    # Create remote directory first (rsync does not create parent dirs on receiver)
    ssh $SSH_OPTS "$DEST_USERHOST" "mkdir -p '${REMOTE_PATH}${codec}/${bitrate}'"

    # Measure energy for this single file send
    e0=$(sudo cat "$RAPL_PATH")
    start=$(date +%s.%N)
    [ -r "$WIFI_TX_PATH" ] && tx0=$(cat "$WIFI_TX_PATH") || tx0=""

    rsync -az -e "ssh $SSH_OPTS" "$local_file" "${DEST_USERHOST}:${remote_dir}"

    e1=$(sudo cat "$RAPL_PATH")
    end=$(date +%s.%N)
    [ -n "$tx0" ] && [ -r "$WIFI_TX_PATH" ] && tx1=$(cat "$WIFI_TX_PATH") || tx1=""

    energy_uj=$((e1 - e0))
    energy_j=$(echo "scale=6; $energy_uj / 1000000" | bc)
    duration=$(echo "scale=6; $end - $start" | bc)
    power_total=$(echo "scale=2; $energy_j / $duration" | bc)
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
