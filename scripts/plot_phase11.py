#!/usr/bin/env python3
# Purpose: Generate Phase 11 reference plots from audited experiment results.

import argparse
import csv
import os
import re
from pathlib import Path

os.environ.setdefault("MPLCONFIGDIR", "/tmp/ros2exp_mplconfig")

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np


def read_key_value_file(path):
    values = {}
    for line in path.read_text().splitlines():
        key, value = line.split("=", 1)
        values[key] = value
    return values


def resolve_artifact(manifest_path, value):
    path = Path(value)
    return path if path.is_absolute() else manifest_path.parent / path


def load_runs(manifest_path):
    runs = []
    with manifest_path.open(newline="") as manifest_file:
        for manifest_row in csv.DictReader(manifest_file):
            if manifest_row["status"] != "valid":
                continue

            analysis_path = resolve_artifact(
                manifest_path, manifest_row["analysis_log"]
            )
            raw_path = resolve_artifact(manifest_path, manifest_row["raw_csv"])
            analysis = read_key_value_file(analysis_path)
            with raw_path.open(newline="") as raw_file:
                raw_rows = list(csv.DictReader(raw_file))

            latencies = np.array(
                [float(row["latency_ms"]) for row in raw_rows], dtype=float
            )
            runs.append(
                {
                    "run_id": manifest_row["run_id"],
                    "qos": manifest_row["qos_reliability"],
                    "depth": int(manifest_row["depth"]),
                    "condition": manifest_row["network_condition"],
                    "latencies": latencies,
                    "analysis": analysis,
                }
            )
    return runs


def write_summary(runs, output_path):
    fields = [
        "run_id",
        "qos_reliability",
        "depth",
        "network_condition",
        "received",
        "inferred_lost",
        "avg_latency_ms",
        "p95_latency_ms",
        "min_latency_ms",
        "max_latency_ms",
        "latency_jitter_stddev_ms",
        "duration_s",
        "receive_rate_hz",
    ]

    with output_path.open("w", newline="") as summary_file:
        writer = csv.DictWriter(
            summary_file, fieldnames=fields, lineterminator="\n"
        )
        writer.writeheader()
        for run in runs:
            analysis = run["analysis"]
            writer.writerow(
                {
                    "run_id": run["run_id"],
                    "qos_reliability": run["qos"],
                    "depth": run["depth"],
                    "network_condition": run["condition"],
                    "received": analysis["received"],
                    "inferred_lost": analysis["inferred_lost"],
                    "avg_latency_ms": analysis["avg_latency_ms"],
                    "p95_latency_ms": analysis["p95_latency_ms"],
                    "min_latency_ms": analysis["min_latency_ms"],
                    "max_latency_ms": analysis["max_latency_ms"],
                    "latency_jitter_stddev_ms": analysis[
                        "latency_jitter_stddev_ms"
                    ],
                    "duration_s": analysis["duration_s"],
                    "receive_rate_hz": analysis["receive_rate_hz"],
                }
            )


def save_figure(figure, output_path):
    figure.savefig(output_path, dpi=160, bbox_inches="tight")
    plt.close(figure)


def pure_delay_ms(condition):
    match = re.fullmatch(r"delay(\d+)", condition)
    return float(match.group(1)) if match else None


def pure_loss_pct(condition):
    match = re.fullmatch(r"loss(\d+)", condition)
    return float(match.group(1)) if match else None


def make_delay_plot(runs, output_dir):
    selected = [
        run
        for run in runs
        if run["qos"] == "reliable" and pure_delay_ms(run["condition"]) is not None
    ]
    selected.sort(key=lambda run: pure_delay_ms(run["condition"]))
    if not selected:
        return

    x = [pure_delay_ms(run["condition"]) for run in selected]
    average = [float(run["analysis"]["avg_latency_ms"]) for run in selected]
    p95 = [float(run["analysis"]["p95_latency_ms"]) for run in selected]

    figure, axis = plt.subplots(figsize=(7, 4.5))
    axis.plot(x, average, "o-", label="average")
    axis.plot(x, p95, "s--", label="P95")
    axis.set_xlabel("Injected delay (ms)")
    axis.set_ylabel("Latency (ms)")
    axis.set_title("ROS 2 latency versus netem delay")
    axis.grid(True, alpha=0.3)
    axis.legend()
    save_figure(figure, output_dir / "phase11_delay_curve.png")


def make_loss_plot(runs, output_dir):
    selected = [
        run
        for run in runs
        if run["qos"] == "reliable" and pure_loss_pct(run["condition"]) is not None
    ]
    selected.sort(key=lambda run: pure_loss_pct(run["condition"]))
    if not selected:
        return

    x = [pure_loss_pct(run["condition"]) for run in selected]
    average = [float(run["analysis"]["avg_latency_ms"]) for run in selected]
    p95 = [float(run["analysis"]["p95_latency_ms"]) for run in selected]
    lost = [int(run["analysis"]["inferred_lost"]) for run in selected]

    figure, axis = plt.subplots(figsize=(7, 4.5))
    axis.plot(x, average, "o-", label="average latency")
    axis.plot(x, p95, "s--", label="P95 latency")
    axis.set_xlabel("Injected packet loss (%)")
    axis.set_ylabel("Latency (ms)")
    axis.set_title("Reliable QoS under packet loss")
    axis.grid(True, alpha=0.3)

    loss_axis = axis.twinx()
    loss_axis.plot(x, lost, "^:", color="tab:red", label="inferred lost")
    loss_axis.set_ylabel("Inferred lost messages")

    handles, labels = axis.get_legend_handles_labels()
    handles2, labels2 = loss_axis.get_legend_handles_labels()
    axis.legend(handles + handles2, labels + labels2, loc="upper left")
    save_figure(figure, output_dir / "phase11_loss_curve.png")


def make_qos_cdf_plot(runs, output_dir):
    selected = [
        run
        for run in runs
        if run["condition"] == "loss10"
        and run["depth"] == 10
        and run["qos"] in {"reliable", "best_effort"}
    ]
    if len(selected) < 2:
        return

    figure, axis = plt.subplots(figsize=(7, 4.5))
    for run in selected:
        values = np.sort(run["latencies"])
        probabilities = np.arange(1, len(values) + 1) / len(values)
        axis.plot(values, probabilities, label=run["qos"])

    axis.set_xlabel("Latency (ms)")
    axis.set_ylabel("CDF")
    axis.set_title("Latency CDF: Reliable versus Best Effort")
    axis.set_ylim(0, 1.02)
    axis.grid(True, alpha=0.3)
    axis.legend()
    save_figure(figure, output_dir / "phase11_qos_loss10_cdf.png")


def make_depth_plot(runs, output_dir):
    selected = [
        run
        for run in runs
        if run["condition"] == "outage_loss100_10s_recovery"
        and run["qos"] == "reliable"
    ]
    selected.sort(key=lambda run: run["depth"])
    if not selected:
        return

    x = [run["depth"] for run in selected]
    maximum = [float(run["analysis"]["max_latency_ms"]) for run in selected]
    jitter = [
        float(run["analysis"]["latency_jitter_stddev_ms"]) for run in selected
    ]

    figure, axis = plt.subplots(figsize=(7, 4.5))
    axis.plot(x, maximum, "o-", label="maximum latency")
    axis.plot(x, jitter, "s--", label="latency jitter stddev")
    axis.set_xlabel("KEEP_LAST depth")
    axis.set_ylabel("Latency (ms)")
    axis.set_title("Recovery latency versus queue depth")
    axis.grid(True, alpha=0.3)
    axis.legend()
    save_figure(figure, output_dir / "phase11_depth_recovery.png")


def main():
    parser = argparse.ArgumentParser(description="Plot Phase 11 ROS 2 results")
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--output-dir", type=Path, default=Path("exp/plots"))
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    runs = load_runs(args.manifest)
    write_summary(runs, args.output_dir / "phase11_summary.csv")
    make_delay_plot(runs, args.output_dir)
    make_loss_plot(runs, args.output_dir)
    make_qos_cdf_plot(runs, args.output_dir)
    make_depth_plot(runs, args.output_dir)
    print(f"runs={len(runs)}")
    print(f"output_dir={args.output_dir.resolve()}")
    for path in sorted(args.output_dir.glob("phase11_*.png")):
        print(f"plot={path}")


if __name__ == "__main__":
    main()
