#!/opt/hamclock-backend/venv/bin/python3
# kindex_simple.py
#
# Build HamClock geomag/kindex.txt (72 lines) from a single SWPC JSON feed:
#   https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json
#
# The feed contains observed, estimated, and predicted 3-hourly Kp bins.
# - Positions  1-56: last 56 observed entries ("now" at position 56)
# - Positions 57-72: first 16 estimated/predicted entries
#
# Output path is atomically written:
# /opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt

from __future__ import annotations

import os
import sys
import tempfile

import requests

KP_URL  = "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json"
OUTFILE = "/opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt"

TIMEOUT = 20
HEADERS = {"User-Agent": "OHB kindex_simple.py"}


def fetch_kp() -> list[dict]:
    r = requests.get(KP_URL, headers=HEADERS, timeout=TIMEOUT)
    r.raise_for_status()
    rows = r.json()
    keys = rows[0]
    return [dict(zip(keys, row)) for row in rows[1:]]


def build_output(records: list[dict]) -> list[float]:
    observed = [float(r["kp"]) for r in records if r["observed"] == "observed"]
    forecast = [float(r["kp"]) for r in records if r["observed"] in ("estimated", "predicted")]

    if len(observed) < 56:
        raise RuntimeError(f"Need at least 56 observed Kp bins, got {len(observed)}")
    if len(forecast) < 16:
        raise RuntimeError(f"Need at least 16 forecast Kp bins, got {len(forecast)}")

    return observed[-56:] + forecast[:16]


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
        records = fetch_kp()
        out = build_output(records)

        if len(out) != 72:
            raise RuntimeError(f"Expected 72 output values, got {len(out)}")

        atomic_write_lines(OUTFILE, out)
        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
