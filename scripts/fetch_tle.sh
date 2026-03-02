#!/usr/bin/env bash
set -euo pipefail

TLEDIR="/opt/hamclock-backend/tle"
ARCHIVE="$TLEDIR/archive"
TLEFILE="$TLEDIR/tles.txt"
TMPFILE="$TLEDIR/tles.new"
ESATS_OUT="/opt/hamclock-backend/htdocs/ham/HamClock/esats/esats.txt"

FILTER="/opt/hamclock-backend/scripts/filter_amsat_active.pl"

mkdir -p "$TLEDIR" "$ARCHIVE" "$(dirname "$ESATS_OUT")"

URLS=(
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle"
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=tle"
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle"
)

ts() { date -u +"%Y%m%dT%H%M%SZ"; }

echo "[$(date -u)] Fetching TLEs..."

: > "$TMPFILE"

for u in "${URLS[@]}"; do
    curl -fsSL "$u" >> "$TMPFILE"
    echo >> "$TMPFILE"
done

# Sanity check
if ! grep -q '^1 ' "$TMPFILE"; then
    echo "ERROR: no TLE records"
    exit 1
fi

STAMP="$(ts)"
cp "$TLEFILE" "$ARCHIVE/tles-${STAMP}-old.txt" 2>/dev/null || true
mv "$TMPFILE" "$TLEFILE"
echo "TLEs installed ($STAMP)"

# Keep last 60 snapshots
mapfile -t old_archives < <(ls -1t "$ARCHIVE"/tles-* 2>/dev/null | tail -n +61)
[[ ${#old_archives[@]} -gt 0 ]] && rm -- "${old_archives[@]}"

# Always run AMSAT filter
echo "[$(ts)] Running AMSAT status filter..."
if env ESATS_TLE_CACHE="$TLEFILE" ESATS_OUT="$ESATS_OUT" perl "$FILTER"; then
    echo "[$(ts)] AMSAT filter complete — esats.txt updated"
else
    echo "WARNING: AMSAT filter failed — esats.txt not updated"
fi
