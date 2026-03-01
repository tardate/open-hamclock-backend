#!/usr/bin/env bash
# update_all_sdo.sh
# Fetch SDO MP4 “latest” products, extract first frame, generate BMP3 squares for all sizes,
# then zlib-compress to .bmp.z for HamClock.

set -euo pipefail

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/SDO"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need curl
need ffmpeg
need convert
need python3

mkdir -p "$OUTDIR"
mkdir -p "$TMPDIR"

# Sizes HamClock uses across builds
SIZES=(170 340 510 680)

SOURCES=(
  "COMP|https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_211193171.mp4|f_211_193_171_{S}.bmp"
  "HMIB|https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_HMIB.mp4|latest_{S}_HMIB.bmp"
  "HMIIC|https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_HMIIC.mp4|latest_{S}_HMIIC.bmp"
  "A131|https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0131.mp4|f_131_{S}.bmp"
  "A193|https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0193.mp4|f_193_{S}.bmp"
  "A211|https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0211.mp4|f_211_{S}.bmp"
  "A304|https://sdo.gsfc.nasa.gov/assets/img/latest/mpeg/latest_1024_0304.mp4|f_304_{S}.bmp"
)

extract_frame_png() {
  local mp4="$1"
  local png="$2"

  mkdir -p "$(dirname "$png")"

  # Get video duration in seconds
  local duration
  duration=$(ffprobe -v error -select_streams v:0 \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$mp4")

  # Seek to 5 seconds before end to land on last keyframe area
  local seek
  seek=$(echo "$duration - 5" | bc)
  # Safety: don't seek to negative
  if (( $(echo "$seek < 0" | bc -l) )); then seek=0; fi

  ffmpeg -hide_banner -loglevel error -y \
    -ss "$seek" \
    -i "$mp4" \
    -vframes 1 \
    -pix_fmt rgb24 \
    "$png"
}

zwrite() {
  local in="$1"
  local out="$2"
  python3 - "$in" "$out" <<'PY'
import sys, zlib
inp, outp = sys.argv[1], sys.argv[2]
data = open(inp, "rb").read()
open(outp, "wb").write(zlib.compress(data, 9))
PY
}

verify_bmp() {
  local bmp="$1"
  python3 - "$bmp" <<'PY'
import sys
p=sys.argv[1]
with open(p,'rb') as f:
    sig=f.read(2)
if sig != b'BM':
    raise SystemExit(f"BAD BMP signature for {p}: {sig!r}")
PY
}

for entry in "${SOURCES[@]}"; do
  IFS='|' read -r key url tmpl <<<"$entry"

  mp4="$TMPDIR/${key}.mp4"
  png="$TMPDIR/${key}.png"

  echo "Fetching $key ..."
  curl -fsS -A "open-hamclock-backend/1.0" --retry 2 --retry-delay 2 "$url" -o "$mp4"

  extract_frame_png "$mp4" "$png"

  for S in "${SIZES[@]}"; do
    outbmp="${OUTDIR}/${tmpl/\{S\}/$S}"
    outz="${outbmp}.z"

    convert "$png" \
      -alpha off -type TrueColor \
      -resize "${S}x${S}!" \
      "BMP3:$outbmp"

    verify_bmp "$outbmp"
    zwrite "$outbmp" "$outz"
    chmod 0644 "$outbmp" "$outz"
  done
done

echo "OK: SDO artifacts updated in $OUTDIR"

