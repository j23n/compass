# /// script
# requires-python = ">=3.11"
# dependencies = ["fitparse"]
# ///
"""
verify_fit_fields.py — Dump contested FIT message fields from live Garmin files.

Inspects the specific (message, field) combinations that are disputed between
Gadgetbridge, Harry, and our current parser, and prints the raw values found
in actual .FIT files from the device.

Usage:
    uv run python scripts/verify_fit_fields.py \\
        --sleep   data/GARMIN/Sleep/S4UA2600.FIT \\
        --monitor data/GARMIN/Monitor/M4UA2600.FIT
"""

from __future__ import annotations

import argparse
from pathlib import Path

import fitparse


def _fmt_val(v) -> str:
    if v is None:
        return "None"
    if isinstance(v, (bytes, bytearray)):
        hex_str = " ".join(f"{b:02x}" for b in v[:24])
        return f"bytes[{len(v)}]: {hex_str}{'…' if len(v) > 24 else ''}"
    return repr(v)


def dump_message(fitfile: fitparse.FitFile, msg_num: int, msg_label: str, field_interest: list[int]) -> None:
    """Print all occurrences of a given global message number from a FIT file."""
    found = 0
    for msg in fitfile.messages:
        if msg.mesg_type is None:
            continue
        if msg.mesg_type.mesg_num != msg_num:
            continue
        found += 1
        if found > 5:
            if found == 6:
                print(f"  … (truncating after 5 records)")
            continue

        print(f"\n  [{msg_label} record #{found}]")
        all_fields = {d.def_num: d for d in msg.fields}
        for fnum in field_interest:
            if fnum in all_fields:
                fd = all_fields[fnum]
                raw = fd.raw_value
                interp = fd.value
                print(f"    field[{fnum}] ({fd.name}): raw={_fmt_val(raw)}  interpreted={_fmt_val(interp)}")
            else:
                print(f"    field[{fnum}]: NOT PRESENT in this record")

        # Also show any other fields present
        other = [f for f in msg.fields if f.def_num not in field_interest]
        if other:
            print(f"    other fields: " + ", ".join(f"{f.def_num}={_fmt_val(f.raw_value)}" for f in other[:8]))

    if found == 0:
        print(f"  (no records for msg {msg_num} in this file)")
    else:
        print(f"\n  total records: {found}")


def run_sleep(path: Path) -> None:
    print(f"\n{'='*60}")
    print(f"SLEEP FILE: {path}")
    print("="*60)
    ff = fitparse.FitFile(str(path))

    # msg 273 — sleep_data_info: is field 1 sample_length (60) or sleep_score (0–100)?
    print("\n--- msg 273 (sleep_data_info) — field 1: sample_length vs sleep_score? ---")
    dump_message(ff, 273, "sleep_data_info", [0, 1, 2, 253])

    # msg 274 — sleep_data_raw: is field 0 raw bytes (20B) or uint8 sleep level?
    print("\n--- msg 274 (sleep_data_raw) — field 0: raw bytes vs uint8 level? ---")
    dump_message(ff, 274, "sleep_data_raw", [0, 253])

    # msg 275 — sleep_stage: does field 1 (invented duration) appear?
    print("\n--- msg 275 (sleep_stage) — field 1: duration invented? ---")
    dump_message(ff, 275, "sleep_stage", [0, 1, 253])

    # msg 276 — sleep_assessment: what fields appear?
    print("\n--- msg 276 (sleep_assessment) — full field dump ---")
    dump_message(ff, 276, "sleep_assessment", list(range(16)) + [253])

    # msg 346 — sleep_stats: confirm sub-score fields
    print("\n--- msg 346 (sleep_stats) — confirm sub-score fields ---")
    dump_message(ff, 346, "sleep_stats", list(range(16)) + [253])

    # msg 382 — sleep_restless_moments
    print("\n--- msg 382 (sleep_restless_moments) ---")
    dump_message(ff, 382, "sleep_restless_moments", [0, 1, 2, 253])


def run_monitor(path: Path) -> None:
    print(f"\n{'='*60}")
    print(f"MONITOR FILE: {path}")
    print("="*60)
    ff = fitparse.FitFile(str(path))

    # msg 140 — physiological_metrics: confirm field 1 = new_hr_max, not HR sample
    print("\n--- msg 140 (physiological_metrics) — field 1: new_hr_max? ---")
    dump_message(ff, 140, "physiological_metrics", [1, 4, 9, 25, 253])

    # msg 346 — sleep_stats: confirm NOT body battery
    print("\n--- msg 346 in monitor file (should be sleep_stats, not body_battery) ---")
    dump_message(ff, 346, "sleep_stats_in_monitor", list(range(16)) + [253])

    # msg 314 — hsa_body_battery_data: confirm body battery source
    print("\n--- msg 314 (hsa_body_battery_data) — confirm body battery ---")
    dump_message(ff, 314, "hsa_body_battery_data", [0, 1, 2, 3, 253])


def main() -> None:
    parser = argparse.ArgumentParser(description="Dump contested FIT fields from live Garmin files")
    parser.add_argument("--sleep",   type=Path, help="Sleep FIT file (e.g. data/GARMIN/Sleep/S4UA2600.FIT)")
    parser.add_argument("--monitor", type=Path, help="Monitor FIT file (e.g. data/GARMIN/Monitor/M4UA2600.FIT)")
    args = parser.parse_args()

    if not args.sleep and not args.monitor:
        parser.error("Provide at least one of --sleep or --monitor")

    if args.sleep:
        if not args.sleep.exists():
            print(f"ERROR: sleep file not found: {args.sleep}")
        else:
            run_sleep(args.sleep)

    if args.monitor:
        if not args.monitor.exists():
            print(f"ERROR: monitor file not found: {args.monitor}")
        else:
            run_monitor(args.monitor)


if __name__ == "__main__":
    main()
