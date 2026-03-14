#!/opt/hamclock-backend/venv/bin/python3
# kindex_simple.py
#
# Build HamClock geomag/kindex.txt (72 lines) from SWPC:
# - daily-geomagnetic-indices.txt -> last 56 valid observed Planetary Kp bins
#   (position 56 = "now" per HamClock's KP_NHD*KP_VPD-1 index)
# - 3-day-geomag-forecast.txt -> 16 forecast bins starting at the bin
#   immediately after the last valid DGD bin
#
# This approach ensures:
# - "now" (position 56) always reflects the most recent observed value from DGD
# - forecast slots 57-72 always contain future predictions from the forecast file
#
# Output path is atomically written:
# /opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt

from __future__ import annotations

import os
import re
import sys
import tempfile
from datetime import date, datetime, timedelta, timezone

import requests

DAILY_URL = "https://services.swpc.noaa.gov/text/daily-geomagnetic-indices.txt"
FCST_URL = "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt"
OUTFILE = "/opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt"
TIMEOUT = 20
HEADERS = {"User-Agent": "OHB kindex_simple.py"}

# 3-hour bin definitions
BIN_STARTS = [0, 3, 6, 9, 12, 15, 18, 21]
ROW_ORDER = [
    "00-03UT",
    "03-06UT",
    "06-09UT",
    "09-12UT",
    "12-15UT",
    "15-18UT",
    "18-21UT",
    "21-00UT",
]


def fetch_text(url: str) -> str:
    r = requests.get(url, headers=HEADERS, timeout=TIMEOUT)
    r.raise_for_status()
    r.encoding = "utf-8"
    return r.text


def parse_daily_kp_observed(text: str) -> list[tuple[date, int, float]]:
    """
    Parse SWPC daily-geomagnetic-indices.txt.
    Returns a chronological list of (date, bin_idx, kp_value) tuples,
    dropping -1 placeholders. bin_idx is 0-7 matching BIN_STARTS.
    """
    records: list[tuple[date, int, float]] = []
    date_row_re = re.compile(r"^\s*(\d{4})\s+(\d{2})\s+(\d{2})\b")

    for line in text.splitlines():
        m = date_row_re.match(line)
        if not m:
            continue

        nums = re.findall(r"-?\d+(?:\.\d+)?", line)
        if len(nums) < 11:
            continue

        try:
            kp8 = [float(x) for x in nums[-8:]]
        except ValueError:
            continue

        row_date = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
        for bin_idx, val in enumerate(kp8):
            if val >= 0:
                records.append((row_date, bin_idx, val))

    if not records:
        raise RuntimeError("No Kp rows parsed from daily-geomagnetic-indices.txt")

    if len(records) < 56:
        raise RuntimeError(f"Need at least 56 valid observed Kp bins, got {len(records)}")

    return records


def next_bin_after(last_date: date, last_bin_idx: int) -> tuple[date, int]:
    """Return the (date, bin_idx) of the bin immediately after the given one."""
    next_idx = last_bin_idx + 1
    if next_idx > 7:
        return last_date + timedelta(days=1), 0
    return last_date, next_idx


def parse_kp_forecast(
    text: str,
    start_date: date,
    start_bin_idx: int,
) -> list[float]:
    """
    Parse the NOAA 3-day Kp forecast table and return exactly 16 values
    in chronological order starting at (start_date, start_bin_idx).
    The forecast table covers 3 days; we locate start_date among the day
    columns and traverse column-major from there.
    """
    lines = text.splitlines()

    # Locate the Kp forecast section
    kp_header_idx = None
    for i, line in enumerate(lines):
        if line.strip().startswith("NOAA Kp index forecast"):
            kp_header_idx = i
            break
    if kp_header_idx is None:
        raise RuntimeError("Could not find 'NOAA Kp index forecast' section")

    # Find the date header line
    date_line_idx = None
    for i in range(kp_header_idx + 1, min(kp_header_idx + 8, len(lines))):
        if lines[i].strip():
            date_line_idx = i
            break
    if date_line_idx is None:
        raise RuntimeError("Could not find Kp forecast date header line")

    # Parse day labels into dates, using start_date's year as anchor
    raw_labels = re.findall(r"([A-Z][a-z]{2})\s+(\d{1,2})", lines[date_line_idx])
    if len(raw_labels) < 3:
        raise RuntimeError(
            f"Could not parse 3 forecast day labels from: {lines[date_line_idx]!r}"
        )

    col_dates: list[date] = []
    for mon_str, day_str in raw_labels[:3]:
        month = datetime.strptime(mon_str, "%b").month
        year = start_date.year
        d = date(year, month, int(day_str))

        # Handle year rollover (e.g. Dec 31 -> Jan 1)
        if col_dates and d < col_dates[-1]:
            d = date(year + 1, month, int(day_str))
        col_dates.append(d)

    # Parse the 8 UT rows into a table: row_label -> [col0, col1, col2]
    row_re = re.compile(
        r"^\s*(\d{2}-\d{2}UT)\s+"
        r"(-?\d+(?:\.\d+)?)\s+"
        r"(-?\d+(?:\.\d+)?)\s+"
        r"(-?\d+(?:\.\d+)?)\s*$"
    )
    table: dict[str, list[float]] = {}
    for i in range(date_line_idx + 1, min(date_line_idx + 24, len(lines))):
        m = row_re.match(lines[i])
        if not m:
            continue
        table[m.group(1)] = [float(m.group(2)), float(m.group(3)), float(m.group(4))]
        if len(table) == 8:
            break

    missing = [r for r in ROW_ORDER if r not in table]
    if missing:
        raise RuntimeError(f"Missing Kp forecast rows: {missing}")

    # Locate start_date in the column dates
    if start_date not in col_dates:
        raise RuntimeError(
            f"start_date {start_date} not found in forecast columns {col_dates}"
        )
    start_col = col_dates.index(start_date)

    # Traverse column-major collecting 16 values
    out_vals: list[float] = []
    col = start_col
    r_idx = start_bin_idx
    while len(out_vals) < 16:
        if col > 2:
            raise RuntimeError(
                f"Forecast window overruns available data after {len(out_vals)} values"
            )
        out_vals.append(table[ROW_ORDER[r_idx]][col])
        r_idx += 1
        if r_idx > 7:
            r_idx = 0
            col += 1

    return out_vals


def atomic_write_lines(path: str, values: list[float]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = "".join(f"{v:.2f}\n" for v in values)
    fd, tmp = tempfile.mkstemp(
        prefix=".kindex.",
        suffix=".tmp",
        dir=os.path.dirname(path),
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main() -> int:
    try:
        daily_text = fetch_text(DAILY_URL)
        fcst_text = fetch_text(FCST_URL)

        # 56 observed bins; last entry is "now" (position 56 per HamClock)
        records = parse_daily_kp_observed(daily_text)
        obs56 = records[-56:]
        obs_vals = [v for _, _, v in obs56]

        # Anchor forecast start to the bin immediately after the last DGD bin
        last_date, last_bin_idx, _ = obs56[-1]
        fc_date, fc_bin_idx = next_bin_after(last_date, last_bin_idx)
        fc_vals = parse_kp_forecast(fcst_text, fc_date, fc_bin_idx)

        out = obs_vals + fc_vals
        if len(out) != 72:
            raise RuntimeError(f"Expected 72 output values, got {len(out)}")

        atomic_write_lines('./foo.txt', out)
        #print(*out, sep='\n')
        return 0
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
