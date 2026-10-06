#!/usr/bin/env python3
# Purpose: Analyze one weak-network CSV and calculate latency, loss, rate, and jitter metrics.

import argparse
import csv
import statistics
from pathlib import Path


REQUIRED_COLUMNS = {
    "sequence",
    "receive_steady_ns",
    "latency_ms",
}


def percentile(values, fraction):
    ordered = sorted(values)
    index = int(fraction * (len(ordered) - 1))
    return ordered[index]


def analyze_csv(path):
    with path.open(newline="") as csv_file:
        reader = csv.DictReader(csv_file)
        columns = set(reader.fieldnames or [])
        missing = REQUIRED_COLUMNS - columns
        if missing:
            raise ValueError(
                f"missing required columns: {', '.join(sorted(missing))}"
            )

        sequences = []
        steady_receive_ns = []
        latency_ms = []

        for row in reader:
            sequences.append(int(row["sequence"]))
            steady_receive_ns.append(int(row["receive_steady_ns"]))
            latency_ms.append(float(row["latency_ms"]))

    if not latency_ms:
        raise ValueError("CSV contains no data rows")

    inferred_lost = sum(
        max(0, current - previous - 1)
        for previous, current in zip(sequences, sequences[1:])
    )
    out_of_order = sum(
        current <= previous
        for previous, current in zip(sequences, sequences[1:])
    )

    duration_s = 0.0
    receive_rate_hz = 0.0
    if len(steady_receive_ns) > 1:
        duration_s = (steady_receive_ns[-1] - steady_receive_ns[0]) / 1e9
        if duration_s > 0:
            receive_rate_hz = (len(latency_ms) - 1) / duration_s

    print(f"file={path}")
    print(f"received={len(latency_ms)}")
    print(f"first_sequence={sequences[0]}")
    print(f"last_sequence={sequences[-1]}")
    print(f"inferred_lost={inferred_lost}")
    print(f"out_of_order={out_of_order}")
    print(f"avg_latency_ms={statistics.fmean(latency_ms):.6f}")
    print(f"p95_latency_ms={percentile(latency_ms, 0.95):.6f}")
    print(f"min_latency_ms={min(latency_ms):.6f}")
    print(f"max_latency_ms={max(latency_ms):.6f}")
    print(
        "latency_jitter_stddev_ms="
        f"{statistics.pstdev(latency_ms):.6f}"
    )
    print(f"duration_s={duration_s:.6f}")
    print(f"receive_rate_hz={receive_rate_hz:.6f}")


def main():
    parser = argparse.ArgumentParser(
        description="Analyze a weaknet subscriber raw CSV file"
    )
    parser.add_argument("csv_path", type=Path)
    args = parser.parse_args()

    try:
        analyze_csv(args.csv_path)
    except (OSError, ValueError, csv.Error) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
