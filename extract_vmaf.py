#!/usr/bin/env python3
import argparse
import json
import os
import sys

def read_vmaf_json(json_path: str, out_log_path: str) -> float:
    with open(json_path) as f:
        data = json.load(f)

    pooled = data.get("pooled_metrics", {}).get("vmaf", {})
    vmaf_mean = float(pooled.get("mean", 0))

    os.makedirs(os.path.dirname(out_log_path) or ".", exist_ok=True)
    with open(out_log_path, "w") as f_log:
        for frame in data.get("frames", []):
            frame_num = frame.get("frameNum", "")
            vmaf = frame.get("metrics", {}).get("vmaf", "")
            f_log.write(f"{frame_num},{vmaf}\n")

    return vmaf_mean


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract VMAF metrics from JSON and write per-frame log.")
    parser.add_argument("--output-dir", help="Use as both rec-dir and res-dir (overrides them)")
    args = parser.parse_args()

    json_path = os.path.join(args.output_dir, "output_vmaf.json")
    if not json_path:
        print("VMAF JSON not found in {} (looked for output_vmaf.json)".format(args.output_dir), file=sys.stderr)
        return 1

    log_path = os.path.join(args.output_dir, "vmaf_score.log")
    if os.path.exists(log_path):
        os.remove(log_path)

    mean = read_vmaf_json(json_path, log_path)
    # Single line for shell: mean
    print(f"{mean:.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
