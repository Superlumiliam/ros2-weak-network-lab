#!/usr/bin/env python3

import argparse
import csv
from pathlib import Path


def read_analysis(path):
    values = {}
    for line in path.read_text().splitlines():
        key, value = line.split("=", 1)
        values[key] = value
    return values


def resolve_artifact(manifest_path, value):
    path = Path(value)
    return path if path.is_absolute() else manifest_path.parent / path


def audit(manifest_path):
    errors = []
    rows = list(csv.DictReader(manifest_path.open(newline="")))
    seen_run_ids = set()

    for row in rows:
        run_id = row["run_id"]
        if run_id in seen_run_ids:
            errors.append(f"{run_id}: duplicate run_id")
        seen_run_ids.add(run_id)

        paths = {
            name: resolve_artifact(manifest_path, row[name])
            for name in (
                "raw_csv",
                "subscriber_log",
                "publisher_log",
                "tc_log",
                "analysis_log",
            )
        }
        for name, path in paths.items():
            if not path.is_file():
                errors.append(f"{run_id}: missing {name}: {path}")

        if not all(path.is_file() for path in paths.values()):
            continue

        with paths["raw_csv"].open(newline="") as raw_file:
            raw_rows = sum(1 for _ in csv.DictReader(raw_file))

        analysis = read_analysis(paths["analysis_log"])
        received = int(analysis["received"])
        out_of_order = int(analysis["out_of_order"])
        summary_count = paths["subscriber_log"].read_text().count("summary:")

        if raw_rows != received:
            errors.append(
                f"{run_id}: raw_rows={raw_rows} != received={received}"
            )
        if summary_count != 1:
            errors.append(
                f"{run_id}: subscriber summary count={summary_count}"
            )
        if out_of_order != 0:
            errors.append(f"{run_id}: out_of_order={out_of_order}")
        if row["status"] != "valid":
            errors.append(f"{run_id}: status={row['status']}")

    print(f"manifest_runs={len(rows)}")
    print(f"unique_run_ids={len(seen_run_ids)}")
    print(f"audit_errors={len(errors)}")
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        raise SystemExit(1)
    print("audit=PASS")


def main():
    parser = argparse.ArgumentParser(description="Audit Phase 11 artifacts")
    parser.add_argument("manifest", type=Path)
    args = parser.parse_args()
    audit(args.manifest)


if __name__ == "__main__":
    main()
