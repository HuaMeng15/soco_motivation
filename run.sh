#!/bin/bash

INPUT_FILE="input/Game.yuv"
BITRATE=(100 200 500 700 1000 2000 3000 4000 5000 7000 10000 20000 30000 50000)
CODEC=(libx264 libx265 libvpx-vp9 libsvtav1 libaom-av1 libvvenc)
RUN_TIMES=3

for codec in ${CODEC[@]}; do
  for bitrate in ${BITRATE[@]}; do
    for i in $(seq 1 ${RUN_TIMES}); do
      echo "Running ${codec} ${bitrate} run ${i}..."
      # codec=libsvtav1
      # bitrate=1000
      until ./test_energy_and_cpu.sh ${INPUT_FILE} ${bitrate} ${codec} ${i}; do
        echo "Retrying ${codec} ${bitrate} run ${i}..."
      done
      # exit 0
    done
    # exit 0
    echo "Done"
  done
done
echo "All done"