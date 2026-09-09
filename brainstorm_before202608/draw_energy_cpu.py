#!/usr/bin/env python3
"""
Read result.csv and send_energy.csv; plot 3x2 (three rows):
  Row 1: FFmpeg Energy | VMAF
  Row 2: Send Energy vs File size | File size vs Bitrate
  Row 3: CPU Avg | CPU Max
- FFmpeg/CPU/VMAF from result.csv; send metrics from send_energy.csv.

Requires: pip install pandas matplotlib
"""
import argparse
import os
from typing import Optional

import pandas as pd
import matplotlib.pyplot as plt


def load_data(csv_path: str) -> pd.DataFrame:
    """Load CSV: averaged energy/CPU per (Bitrate, Codec); VMAF from first run only."""
    df = pd.read_csv(csv_path)
    # Average over runs for energy and CPU
    df_avg = df.groupby(["Bitrate", "Codec"], as_index=False).mean(numeric_only=True)
    # VMAF: first run only (no average)
    df_vmaf = df.drop_duplicates(subset=["Bitrate", "Codec"], keep="first")[
        ["Bitrate", "Codec", "VMAF Mean"]
    ]
    if "VMAF Mean" in df_avg.columns:
        df_avg = df_avg.drop(columns=["VMAF Mean"])
    # Merge so we have avg energy/cpu + first-run VMAF
    df_plot = df_avg.merge(df_vmaf, on=["Bitrate", "Codec"], how="left")
    return df_plot


def draw_plots(
    df: pd.DataFrame,
    out_dir: str = ".",
    out_filename: str = "energy_cpu_trends.png",
    df_send: Optional[pd.DataFrame] = None,
) -> None:
    """Plot 3x2: row1 FFmpeg Energy | VMAF; row2 Send Energy vs File size | File size vs Bitrate; row3 CPU Avg | CPU Max."""
    codecs = df["Codec"].unique()
    has_vmaf = "VMAF Mean" in df.columns and df["VMAF Mean"].notna().any()
    has_send = (
        df_send is not None
        and not df_send.empty
        and "File_bytes" in df_send.columns
        and "Send_Energy_J" in df_send.columns
        and "Bitrate" in df_send.columns
    )

    # File size (bytes) -> kbps: file_bytes * 240 / 1199000
    FILE_SIZE_TO_KBPS = 240.0 / 1199000.0

    fig, axes = plt.subplots(3, 2, figsize=(12, 12))
    # Row 1: FFmpeg Energy | VMAF
    ax_energy, ax_vmaf = axes[0, 0], axes[0, 1]
    # Row 2: Send Energy vs File size | File size vs Bitrate
    ax_send_filesize, ax_filesize_bitrate = axes[1, 0], axes[1, 1]
    # Row 3: CPU Avg | CPU Max
    ax_cpu_avg, ax_cpu_max = axes[2, 0], axes[2, 1]

    for codec in codecs:
        sub = df[df["Codec"] == codec].sort_values("Bitrate")
        if sub.empty:
            continue
        x = sub["Bitrate"]
        ax_energy.plot(x, sub["Ffmpeg Energy (J)"], marker="o", label=codec, markersize=4)
        ax_cpu_avg.plot(x, sub["CPU Avg (%)"], marker="s", label=codec, markersize=4)
        ax_cpu_max.plot(x, sub["CPU Max (%)"], marker="^", label=codec, markersize=4)
        if has_vmaf:
            vmaf = pd.to_numeric(sub["VMAF Mean"], errors="coerce").fillna(0)
            ax_vmaf.plot(x, vmaf, marker="d", label=codec, markersize=4)

    if has_send:
        for codec in df_send["Codec"].unique():
            sub_file = df_send[df_send["Codec"] == codec].sort_values("File_bytes")
            sub_br = df_send[df_send["Codec"] == codec].sort_values("Bitrate")
            if not sub_file.empty:
                ax_send_filesize.plot(
                    sub_file["File_bytes"],
                    sub_file["Send_Energy_J"],
                    marker="o",
                    label=codec,
                    markersize=4,
                )
            if not sub_br.empty:
                file_size_kbps = sub_br["File_bytes"] * FILE_SIZE_TO_KBPS
                ax_filesize_bitrate.plot(sub_br["Bitrate"], file_size_kbps, marker="s", label=codec, markersize=4)
        ax_send_filesize.set_xlabel("File size (bytes)")
        ax_send_filesize.set_ylabel("Send Energy (J)")
        ax_send_filesize.set_title("Send Energy vs File size")
        ax_send_filesize.legend(loc="best", fontsize=8)
        ax_send_filesize.grid(True, alpha=0.3)
        ax_filesize_bitrate.set_xlabel("Bitrate (kbps)")
        ax_filesize_bitrate.set_ylabel("File size (kbps)")
        ax_filesize_bitrate.set_title("File size vs Bitrate")
        ax_filesize_bitrate.legend(loc="best", fontsize=8)
        ax_filesize_bitrate.grid(True, alpha=0.3)
    else:
        ax_send_filesize.set_visible(False)
        ax_filesize_bitrate.set_visible(False)

    ax_energy.set_ylabel("FFmpeg Energy (J)")
    ax_energy.set_title("FFmpeg Energy vs Bitrate")
    ax_energy.legend(loc="best", fontsize=8)
    ax_energy.grid(True, alpha=0.3)

    if has_vmaf:
        ax_vmaf.set_ylabel("VMAF Mean")
        ax_vmaf.set_title("VMAF vs Bitrate")
        ax_vmaf.legend(loc="best", fontsize=8)
        ax_vmaf.grid(True, alpha=0.3)
    else:
        ax_vmaf.set_title("VMAF vs Bitrate (no data)")
        ax_vmaf.set_visible(False)

    ax_cpu_avg.set_ylabel("CPU Avg (%)")
    ax_cpu_avg.set_xlabel("Bitrate (kbps)")
    ax_cpu_avg.set_title("CPU Avg vs Bitrate")
    ax_cpu_avg.legend(loc="best", fontsize=8)
    ax_cpu_avg.grid(True, alpha=0.3)

    ax_cpu_max.set_ylabel("CPU Max (%)")
    ax_cpu_max.set_xlabel("Bitrate (kbps)")
    ax_cpu_max.set_title("CPU Max vs Bitrate")
    ax_cpu_max.legend(loc="best", fontsize=8)
    ax_cpu_max.grid(True, alpha=0.3)

    plt.tight_layout()
    out_path = os.path.join(out_dir, out_filename)
    plt.savefig(out_path, dpi=150)
    plt.close()
    print(f"Saved: {out_path}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Plot energy and CPU trends from result.csv and send_energy.csv")
    parser.add_argument("csv", nargs="?", default="result.csv", help="Path to result.csv")
    parser.add_argument("-o", "--output-dir", default=".", help="Directory for output plot")
    parser.add_argument("--send-csv", default="send_energy.csv", help="Path to send_energy.csv for Send Energy subplot")
    args = parser.parse_args()

    if not os.path.isfile(args.csv):
        print(f"Error: file not found: {args.csv}")
        return 1

    df = load_data(args.csv)
    print(f"Loaded {len(df)} rows (energy/CPU averaged, VMAF first-run only) from {args.csv}")

    df_send: Optional[pd.DataFrame] = None
    send_path = os.path.join(os.path.dirname(os.path.abspath(args.csv)), args.send_csv)
    if not os.path.isfile(send_path):
        send_path = args.send_csv
    if os.path.isfile(send_path):
        df_send = pd.read_csv(send_path)
        if "Send_Energy_J" in df_send.columns and "File_bytes" in df_send.columns:
            print(f"Loaded {len(df_send)} rows from {send_path} for Send Energy subplot")
        else:
            df_send = None
    else:
        print(f"Send energy CSV not found: {send_path} (skipping Send Energy subplot)")

    draw_plots(df, args.output_dir, df_send=df_send)
    # Same figure for bitrate <= 10000 kbps only
    bitrate_limit = 5000
    df_low = df[df["Bitrate"] <= bitrate_limit]
    df_send_low = df_send[df_send["Bitrate"] <= bitrate_limit] if df_send is not None else None
    if not df_low.empty:
        draw_plots(df_low, args.output_dir, f"energy_cpu_trends_under_{bitrate_limit}kbps.png", df_send=df_send_low)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
