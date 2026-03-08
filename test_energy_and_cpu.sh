#!/bin/bash

if [ $# -lt 4 ]; then
    echo "Usage: $0 <INPUT_FILE> <BITRATE> <CODEC>"
    echo "  Example: $0 input/Game.yuv 1000 libvpx-vp9"
    exit 1
fi

INPUT_FILE="$1"
BITRATE="$2"
codec="$3"
RUN_TIMES="$4"
WIDTH=1920
HEIGHT=1080
OUTPUT_DIR="$(pwd)/result/${codec}/${BITRATE}_${RUN_TIMES}"
echo "OUTPUT_DIR: ${OUTPUT_DIR}"
rm -rf ${OUTPUT_DIR}
mkdir -p ${OUTPUT_DIR}

FFMPEG_BASIC_CMD="ffmpeg -s ${WIDTH}x${HEIGHT} -i $INPUT_FILE -g 10000 -c:v $codec -bf 0 -b:v ${BITRATE}k -threads auto"
FFMPEG_CMD="${FFMPEG_BASIC_CMD} -preset superfast -y ${OUTPUT_DIR}/output.mp4"
if [ "$codec" == "libvpx" ]; then
  FFMPEG_CMD="${FFMPEG_BASIC_CMD} -speed 5 -y ${OUTPUT_DIR}/output.webm"
elif [ "$codec" == "libvpx-vp9" ]; then
  FFMPEG_CMD="${FFMPEG_BASIC_CMD} -speed 5 -y ${OUTPUT_DIR}/output.mp4"
elif [ "$codec" == "libsvtav1" ]; then
  FFMPEG_CMD="${FFMPEG_BASIC_CMD} -preset 5 -y ${OUTPUT_DIR}/output.mp4"
elif [ "$codec" == "libaom-av1" ]; then
  FFMPEG_CMD="${FFMPEG_BASIC_CMD} -cpu-used 8 -lag-in-frames 0 -y ${OUTPUT_DIR}/output.mp4"
elif [ "$codec" == "libvvenc" ]; then
  FFMPEG_CMD="${FFMPEG_BASIC_CMD} -preset 0 -y ${OUTPUT_DIR}/output.mp4"
fi
echo "${FFMPEG_CMD}"

# Read initial energy (microjoules µJ)
rapl_path="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
thermal_path="/sys/class/thermal/thermal_zone0/temp"

if [ ! -f "$rapl_path" ]; then
    echo "RAPL not supported, cannot measure power consumption"
    exit 1
fi

# ======================
# Step A: Measure idle power consumption
# ======================
echo "=== Measuring idle power (please keep the server idle) ==="
sleep 1
e0_idle=$(sudo cat $rapl_path)
sleep 2
e1_idle=$(sudo cat $rapl_path)
power_idle=$(echo "scale=2; ($e1_idle - $e0_idle)/1000000/2" | bc)
echo "Idle Power: ${power_idle} W"

# Optional: report idle temperature if available
if [ -f "$thermal_path" ]; then
    temp_idle=$(($(cat $thermal_path) / 1000))
    echo "Idle temperature: ${temp_idle} °C"
fi

# ======================
# Step B: Run ffmpeg and measure total power, CPU, temperature
# ======================
echo -e "\n=== Starting FFmpeg ==="
e0=$(sudo cat $rapl_path)
start=$(date +%s.%N)

# Background monitor for CPU usage and temperature (samples every 1s)
monitor_log=${OUTPUT_DIR}/monitor.log
(
  prev_total=0
  prev_idle=0
  first=1
  while true; do
    read -r cpu u n s i iow irq sirq steal guest gnice < /proc/stat
    total=$((u + n + s + i + iow + irq + sirq + steal + guest + gnice))
    if [ $first -eq 0 ] && [ $prev_total -gt 0 ]; then
      diff_total=$((total - prev_total))
      diff_idle=$((i - prev_idle))
      if [ $diff_total -gt 0 ]; then
        cpu_pct=$(echo "scale=2; 100 * (1 - $diff_idle / $diff_total)" | bc)
      else
        cpu_pct="0"
      fi
      temp_c=""
      if [ -f "$thermal_path" ]; then
        temp_c=$(($(cat $thermal_path 2>/dev/null) / 1000))
      fi
      echo "$cpu_pct $temp_c" >> "$monitor_log"
    fi
    prev_total=$total
    prev_idle=$i
    first=0
    sleep 0.1
  done
) &
MONITOR_PID=$!

eval $FFMPEG_CMD

kill $MONITOR_PID 2>/dev/null
wait $MONITOR_PID 2>/dev/null

e1=$(sudo cat $rapl_path)
end=$(date +%s.%N)

# Aggregate CPU and temperature from monitor log
if [ -s "$monitor_log" ]; then
  cpu_avg=$(awk '{sum+=$1; n++} END {if(n>0) printf "%.2f", sum/n; else print "0"}' "$monitor_log")
  cpu_max=$(awk 'BEGIN{m=0} {if($1+0>m) m=$1+0} END {printf "%.2f", m}' "$monitor_log")
  temp_avg=$(awk '{sum+=$2; n++} END {if(n>0) printf "%.1f", sum/n; else print "0"}' "$monitor_log")
  temp_max=$(awk 'BEGIN{m=0} {if($2+0>m) m=$2+0} END {printf "%.1f", m}' "$monitor_log")
else
  cpu_avg=""
  cpu_max=""
  temp_avg=""
  temp_max=""
fi

# Calculate total energy, total time, average total power
energy_j=$(echo "scale=6; ($e1 - $e0)/1000000" | bc)
duration=$(echo "scale=6; $end - $start" | bc)
power_total=$(echo "scale=2; $energy_j / $duration" | bc)

# ======================
# Step C: Subtract idle power = FFmpeg-only power
# ======================
power_ffmpeg=$(echo "scale=2; $power_total - $power_idle" | bc)

echo -e "\n===== Final Result (FFmpeg Only) ===="
echo "Duration:        ${duration} s"
echo "Idle Power:      ${power_idle} W"
echo "Total Power:     ${power_total} W"
echo "FFmpeg Power:    ${power_ffmpeg} W"
echo "Total Energy:    ${energy_j} J"
echo "Ffmpeg Energy:   $(echo "scale=6; $energy_j - $power_idle * $duration" | bc) J"
[ -n "$cpu_avg" ] && echo "CPU usage (avg): ${cpu_avg}%"
[ -n "$cpu_max" ] && echo "CPU usage (max): ${cpu_max}%"
[ -n "$temp_avg" ] && echo "Temperature (avg): ${temp_avg} °C"
[ -n "$temp_max" ] && echo "Temperature (max): ${temp_max} °C"

if [ "$(echo "$power_total < 0" | bc)" -eq 1 ] || [ "$(echo "$power_ffmpeg < 0" | bc)" -eq 1 ]; then
  echo "Power total or power ffmpeg is less than 0, exiting"
  exit -1
fi

# Calculate output.mp4 VMAF score (easyvmaf writes JSON into OUTPUT_DIR) of times 1
if [ "$RUN_TIMES" -eq 1 ]; then
  cp $(pwd)/input/Game.mp4 ${OUTPUT_DIR}/input.mp4

  if [ "$codec" == "libvvenc" ] || [ "$codec" == "libaom-av1" ] || [ "$codec" == "libsvtav1" ]; then
    # convert output.mp4 to raw frames, then concat to new output.mp4
    mkdir -p ${OUTPUT_DIR}/raw_frames
    ffmpeg -i ${OUTPUT_DIR}/output.mp4 ${OUTPUT_DIR}/raw_frames/%d.png
    cp ${OUTPUT_DIR}/output.mp4 ${OUTPUT_DIR}/output.mp4.bak
    # concat raw frames to new output.mp4
    ffmpeg -framerate 25 -f image2 -i ${OUTPUT_DIR}/raw_frames/%d.png -c:v libx264 -pix_fmt yuv420p -qp 0 -y ${OUTPUT_DIR}/output.mp4
    rm -rf ${OUTPUT_DIR}/raw_frames
  fi

  docker run --rm -v ${OUTPUT_DIR}:/socket gfdavila/easyvmaf -r /socket/input.mp4 -d /socket/output.mp4
  rm ${OUTPUT_DIR}/input.mp4
  vmaf_mean=""
  if vmaf_line=$(python3 "$(pwd)/extract_vmaf.py" --output-dir "${OUTPUT_DIR}" 2>/dev/null); then
    vmaf_mean="${vmaf_line%,*}"
    echo "VMAF mean: ${vmaf_mean}"
  else
    echo "VMAF JSON not found or extract failed; skipping VMAF columns"
  fi
fi

# Output to csv file
result_file="result.csv"
if [ ! -f "$result_file" ]; then
  echo "Bitrate,Codec,RunTimes,Duration,Idle Power (W),Total Power (W),FFmpeg Power (W),Total Energy (J),Ffmpeg Energy (J),CPU Avg (%),CPU Max (%),Temp Avg (°C),Temp Max (°C),VMAF Mean" > $result_file
fi
echo "${BITRATE},${codec},${RUN_TIMES},${duration},${power_idle},${power_total},${power_ffmpeg},${energy_j},$(echo "scale=6; $energy_j - $power_idle * $duration" | bc),${cpu_avg:-},${cpu_max:-},${temp_avg:-},${temp_max:-},${vmaf_mean:-}" >> ${result_file}

echo "Result saved to ${result_file}"