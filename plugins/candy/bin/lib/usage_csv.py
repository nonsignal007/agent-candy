import csv
import os
from typing import Dict, Optional


FIELDS = [
    "timestamp",
    "datetime",
    "dow",
    "hour",
    "type",
    "sample_slot",
    "5h_used_pct",
    "5h_resets_at",
    "7d_used_pct",
    "raw_5h_used_pct",
    "effective_5h_used_pct",
    "minutes_to_reset",
    "window_elapsed_min",
    "progress_source",
    "limit_hit_at",
]


def _normalize_row(row: Dict[str, object]) -> Dict[str, object]:
    return {field: row.get(field, "") for field in FIELDS}


def ensure_header(csv_file: str) -> None:
    os.makedirs(os.path.dirname(csv_file), exist_ok=True)

    try:
        with open(csv_file, newline="") as f:
            rows = list(csv.DictReader(f))
    except FileNotFoundError:
        with open(csv_file, "w", newline="") as f:
            csv.DictWriter(f, fieldnames=FIELDS).writeheader()
        return

    current_fields = rows[0].keys() if rows else None
    if list(current_fields or []) == FIELDS:
        return

    with open(csv_file, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        for row in rows:
            writer.writerow(_normalize_row(row))


def append_row(csv_file: str, row: Dict[str, object], max_lines: Optional[int] = None) -> None:
    ensure_header(csv_file)

    with open(csv_file, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS, extrasaction="ignore")
        writer.writerow(_normalize_row(row))

    if max_lines is not None:
        with open(csv_file) as f:
            lines = f.readlines()
        if len(lines) > max_lines + 1:
            with open(csv_file, "w") as f:
                f.write(lines[0])
                f.writelines(lines[-max_lines:])
