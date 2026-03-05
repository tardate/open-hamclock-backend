#!/usr/bin/env python3
"""
Build ssn-31.txt (YYYY MM DD SSN) using:
- NOAA SWPC daily-solar-indices.txt  (last 30 days of SESC sunspot numbers)
- The oldest line from the existing ssn-31.txt as the 31st (carry-forward) entry
- SWPC JSON (swpc_observed_ssn.json) ONLY to fill in today if NOAA hasn't published it yet

Logic matches the CSI backend:
  1. Read 30 rows from daily-solar-indices.txt
  2. Strip any existing entries dated after today (prevents stale future-dated
     entries from a previous bad run from persisting)
  3. Prepend the single oldest line from the current ssn-31.txt that is NOT
     already present in the NOAA data (i.e. it has aged out of NOAA's window)
  4. If today (UTC) is not yet in NOAA's file AND combined is still short,
     fetch today's value from SWPC JSON (only if Obsdate matches today exactly)
  5. Write exactly 31 lines, ascending by date, zero-padded MM/DD
"""

from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import pandas as pd
import requests

NOAA_URL = "https://services.swpc.noaa.gov/text/daily-solar-indices.txt"
SWPC_JSON_URL = "https://services.swpc.noaa.gov/json/solar-cycle/swpc_observed_ssn.json"
OUT = Path("/opt/hamclock-backend/htdocs/ham/HamClock/ssn/ssn-31.txt")
N_DAYS = 31


def read_existing(out_path: Path) -> pd.DataFrame:
    """Read existing ssn-31.txt; return empty DataFrame if missing."""
    if not out_path.exists():
        return pd.DataFrame(columns=["date", "ssn"])

    df = pd.read_csv(
        out_path,
        sep=r"\s+",
        header=None,
        names=["year", "month", "day", "ssn"],
        dtype={"year": int, "month": int, "day": int, "ssn": int},
        engine="python",
    )
    df["date"] = pd.to_datetime(
        df[["year", "month", "day"]].astype(str).agg("-".join, axis=1),
        errors="coerce",
        utc=True,
    ).dt.date
    return df.dropna(subset=["date"])[["date", "ssn"]].reset_index(drop=True)


def read_noaa_swpc(url: str) -> pd.DataFrame:
    """Fetch daily-solar-indices.txt and return a DataFrame of (date, ssn)."""
    r = requests.get(url, timeout=20)
    r.raise_for_status()

    rows = []
    for line in r.text.splitlines():
        s = line.strip()
        # Data rows: YYYY MM DD ...
        if len(s) >= 10 and s[:4].isdigit() and s[4] == " ":
            parts = s.split()
            if len(parts) >= 5 and all(p.lstrip("-").isdigit() for p in parts[:3]):
                y, m, d, ssn_str = parts[0], parts[1], parts[2], parts[4]
                if ssn_str.lstrip("-").isdigit():
                    rows.append((y, m, d, int(ssn_str)))

    if not rows:
        raise RuntimeError("No data rows parsed from NOAA SWPC (format may have changed)")

    df = pd.DataFrame(rows, columns=["year", "month", "day", "ssn"])
    df["date"] = pd.to_datetime(
        df[["year", "month", "day"]].astype(str).agg("-".join, axis=1),
        errors="coerce",
        utc=True,
    ).dt.date
    return df.dropna(subset=["date"])[["date", "ssn"]].reset_index(drop=True)


def get_swpc_json_today(url: str, today) -> Optional[int]:
    """Return today's swpc_ssn from SWPC JSON only if Obsdate matches today, else None."""
    r = requests.get(url, timeout=20)
    r.raise_for_status()
    data = r.json()
    if not isinstance(data, list):
        return None
    for obj in reversed(data):
        if not isinstance(obj, dict):
            continue
        obsdate = obj.get("Obsdate", "")
        if not obsdate.startswith(today.isoformat()):
            continue
        v = obj.get("swpc_ssn")
        if v is None:
            return None
        try:
            return int(v)
        except Exception:
            return None
    return None


def main() -> int:
    today_utc = datetime.now(timezone.utc).date()

    try:
        existing = read_existing(OUT)
        noaa = read_noaa_swpc(NOAA_URL)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    noaa_dates = set(noaa["date"])

    # Strip any future-dated entries from a previous bad run
    existing = existing[existing["date"] <= today_utc]

    # Find the oldest existing entry that has already aged out of NOAA's window
    carry = existing[~existing["date"].isin(noaa_dates)].sort_values("date")

    if carry.empty:
        print(
            "WARNING: no carry-forward entry available; output will have fewer than "
            f"{N_DAYS} lines on first run. Seed {OUT} once to fix.",
            file=sys.stderr,
        )
        combined = noaa.sort_values("date")
    else:
        # Take only the single most-recent aged-out entry (matches CSI behaviour)
        carry_row = carry.tail(1)
        combined = (
            pd.concat([carry_row, noaa], ignore_index=True)
            .drop_duplicates(subset=["date"], keep="last")
            .sort_values("date")
        )

    # If today isn't in NOAA's file yet AND we're short, try SWPC JSON
    if today_utc not in noaa_dates and len(combined) < N_DAYS:
        try:
            v = get_swpc_json_today(SWPC_JSON_URL, today_utc)
            if v is not None:
                combined = (
                    pd.concat(
                        [combined, pd.DataFrame([{"date": today_utc, "ssn": v}])],
                        ignore_index=True,
                    )
                    .drop_duplicates(subset=["date"], keep="last")
                    .sort_values("date")
                )
        except Exception as e:
            print(f"WARNING: SWPC JSON fetch failed: {e}", file=sys.stderr)

    if len(combined) < N_DAYS:
        print(
            f"WARNING: only {len(combined)} days available (need {N_DAYS}). "
            "Output will be short until NOAA publishes today or carry-forward is seeded.",
            file=sys.stderr,
        )

    # Keep at most N_DAYS (shoulders off the carry-forward when today is appended)
    combined = combined.tail(N_DAYS)

    # Write CSI-style: YYYY MM DD SSN  (zero-padded month/day)
    dt = pd.to_datetime(combined["date"])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as f:
        for y, m, d, ssn in zip(
            dt.dt.year, dt.dt.month, dt.dt.day,
            combined["ssn"].astype(int).to_numpy(),
        ):
            f.write(f"{int(y):04d} {int(m):02d} {int(d):02d} {int(ssn)}\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
