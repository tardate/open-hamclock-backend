#!/opt/hamclock-backend/venv/bin/python3
# kindex_simple.py
#
# Build HamClock geomag/kindex.txt (72 lines) from SWPC:
# - daily-geomagnetic-indices.txt -> most recent 55 valid observed Planetary Kp bins
# - 3-day-geomag-forecast.txt -> 17 forecast Kp bins using a dynamic window:
#    start at the NEXT 3-hour bin after current UTC time, column-major,
#    always producing exactly 17 forecast values.
#
# Output path is atomically written:
# /opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt

from __future__ import annotations

import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd
import requests

DAILY_URL = "https://services.swpc.noaa.gov/text/daily-geomagnetic-indices.txt"
FCST_URL = "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt"
OUTFILE = "/opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt"

TIMEOUT = 20
HEADERS = {"User-Agent": "OHB kindex_simple.py"}

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

BIN_STARTS = [0, 3, 6, 9, 12, 15, 18, 21]


def fetch_text(url: str) -> str | None: # Changed return type to allow returning None on error
    try:
        r = requests.get(url, headers=HEADERS, timeout=TIMEOUT)
        r.raise_for_status()
        r.encoding = 'utf-8'
        return r.text
    except requests.exceptions.HTTPError as errh:
        # Handles 4xx or 5xx errors
        print(f"HTTP Error: {errh}", file=sys.stderr)
        return None
    except requests.exceptions.ConnectionError as conerr:
        # Handles connection issues (e.g., DNS failure, refused connection)
        print(f"Connection Error: {conerr}", file=sys.stderr)
        return None
    except requests.exceptions.ReadTimeout as errrt:
        # Handles timeout errors
        print(f"Timeout Error: {errrt}", file=sys.stderr)
        return None
    except requests.exceptions.RequestException as errex:
        # Handles any other exception from the requests library (general exception)
        print(f"An unexpected error occurred: {errex}", file=sys.stderr)
        return None

def get_forecast_start(now: datetime | None = None) -> tuple[str, int]:
    """
    Determine the forecast window start row and column based on current UTC time.

    The current 3-hour bin is considered "being observed" so the forecast
    starts at the NEXT bin. If that next bin rolls over midnight, we start
    on day2 (col_idx=1).

    Returns:
        (start_row, start_col_idx) e.g. ("15-18UT", 0) or ("00-03UT", 1)
    """
    if now is None:
        now = datetime.now(timezone.utc)

    hour = now.hour

    # Find the current 3-hour bin index (0-7)
    # 00-03 is index 0, 03-06 is index 1, etc.
    current_bin_idx = max(i for i, b in enumerate(BIN_STARTS) if b <= hour)

    # CHANGE: Start forecast at the CURRENT bin instead of current + 1
    # This ensures no 3-hour gap exists between observed and forecast.
    start_bin_idx = current_bin_idx

    start_bin_start = BIN_STARTS[start_bin_idx]
    start_bin_end = (start_bin_start + 3) % 24

    if start_bin_end == 0:
        row_label = "21-00UT"
    else:
        row_label = f"{start_bin_start:02d}-{start_bin_end:02d}UT"

    # col_idx 0 is Day 1 of the forecast file (Today)
    col_idx = 0

    return row_label, col_idx

def parse_daily_kp_observed(text: str) -> pd.Series:
    """
    Parse SWPC daily-geomagnetic-indices.txt and return chronological valid
    Planetary Kp bins.

    Assumption (matches SWPC product): the LAST 8 numeric fields on each data
    row are Planetary Kp values for 00-03, 03-06, ..., 21-24 UTC.
    """
    vals = []
    date_row_re = re.compile(r"^\s*(\d{4})\s+(\d{2})\s+(\d{2})\b")

    for line in text.splitlines():
        if not date_row_re.match(line):
            continue

        nums = re.findall(r"-?\d+(?:\.\d+)?", line)
        if len(nums) < 11:
            continue

        try:
            kp8 = [float(x) for x in nums[-8:]]
        except ValueError:
            continue

        vals.extend(kp8)

    if not vals:
        raise RuntimeError("No Kp rows parsed from daily-geomagnetic-indices.txt")

    s = pd.Series(vals, dtype="float64")

    # 1. Drop future placeholders (-1) so they don't pollute the tail(55)
    s = s[s >= 0].reset_index(drop=True)

    # 2. Grab the most recent 55 valid observations
    s = s.tail(55).reset_index(drop=True)

    # Need 55 for historical
    if len(s) < 55:
        raise RuntimeError(f"Need at least 55 valid observed Kp bins, got {len(s)}")

    return s

def parse_kp_forecast_window(
    text: str,
    start_row: str = "15-18UT",
    start_col_idx: int = 0,
    end_row: str = "12-15UT",
    end_col_idx: int = 2,
) -> pd.Series:
    """
    Parse the NOAA Kp forecast table from 3-day-geomag-forecast.txt and return
    a pandas Series traversed in column-major order from (start_col_idx,
    start_row) to (end_col_idx, end_row), inclusive.

    Always produces exactly 17 values by dynamically computing the end
    position from the start position.

    Returns a Series of floats.
    """
    lines = text.splitlines()

    # Locate the Kp table section
    kp_header_idx = None
    for i, line in enumerate(lines):
        if line.strip().startswith("NOAA Kp index forecast"):
            kp_header_idx = i
            break
    if kp_header_idx is None:
        raise RuntimeError("Could not find 'NOAA Kp index forecast' section")

    # Find the date header line (e.g., "Feb 25    Feb 26    Feb 27")
    date_line_idx = None
    for i in range(kp_header_idx + 1, min(kp_header_idx + 8, len(lines))):
        if lines[i].strip():
            date_line_idx = i
            break
    if date_line_idx is None:
        raise RuntimeError("Could not find Kp forecast date header line")

    date_line = lines[date_line_idx]
    day_labels = re.findall(r"[A-Z][a-z]{2}\s+\d{1,2}", date_line)
    if len(day_labels) < 3:
        raise RuntimeError(
            f"Could not parse 3 forecast day labels from line: {date_line!r}"
        )
    day_labels = day_labels[:3]

    # Parse the 8 UT rows
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
        row_label = m.group(1)
        table[row_label] = [float(m.group(2)), float(m.group(3)), float(m.group(4))]
        if len(table) == 8:
            break

    missing = [r for r in ROW_ORDER if r not in table]
    if missing:
        raise RuntimeError(f"Missing Kp forecast rows: {missing}")

    if start_row not in ROW_ORDER:
        raise RuntimeError(f"Invalid start row label: {start_row}")
    if not (0 <= start_col_idx <= 2):
        raise RuntimeError("Column index must be in range 0..2")

    # Build ordered matrix
    df = pd.DataFrame(
        [table[r] for r in ROW_ORDER],
        index=ROW_ORDER,
        columns=day_labels,
        dtype="float64",
    )

    # Dynamically compute end position from start so we always get 17 values
    total_bins = len(ROW_ORDER) * 3  # 24 total bins across 3 days
    start_flat = start_col_idx * len(ROW_ORDER) + ROW_ORDER.index(start_row)
    end_flat = start_flat + 16  # 17 values inclusive = +16

    if end_flat >= total_bins:
        raise RuntimeError(
            f"Forecast window overruns available data: start_flat={start_flat}, "
            f"end_flat={end_flat}, total_bins={total_bins}"
        )

    end_col_idx = end_flat // len(ROW_ORDER)
    end_row_idx = end_flat % len(ROW_ORDER)
    end_row = ROW_ORDER[end_row_idx]

    out_vals: list[float] = []
    start_row_idx = ROW_ORDER.index(start_row)

    for c in range(start_col_idx, end_col_idx + 1):
        r_start = start_row_idx if c == start_col_idx else 0
        r_end = end_row_idx if c == end_col_idx else len(ROW_ORDER) - 1
        for r in range(r_start, r_end + 1):
            out_vals.append(float(df.iloc[r, c]))

    fc = pd.Series(out_vals, dtype="float64").reset_index(drop=True)

    if len(fc) != 17:
        raise RuntimeError(
            f"Expected 17 forecast Kp bins from dynamic window, got {len(fc)}"
        )

    return fc


def atomic_write_lines(path: str, values: pd.Series) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = "".join(f"{v:.2f}\n" for v in values.tolist())

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
    print(datetime.now().strftime("%Y%m%d%H%M") + " kindex_simple.py started")
    try:
        now = datetime.now(timezone.utc)

        daily_text = fetch_text(DAILY_URL)
        fcst_text = fetch_text(FCST_URL)

        # Most recent 55 valid observed Planetary Kp bins
        obs = parse_daily_kp_observed(daily_text).tail(55).reset_index(drop=True)

        # Dynamic forecast window based on current UTC time
        start_row, start_col = get_forecast_start(now)
        fc = parse_kp_forecast_window(fcst_text, start_row=start_row, start_col_idx=start_col)

        out = pd.concat([obs, fc], ignore_index=True)

        if len(out) != 72:
            raise RuntimeError(f"Expected 72 output values, got {len(out)}")

        atomic_write_lines(OUTFILE, out)
        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
