#!/bin/bash
# ============================================================
#
#   ██████╗ ██╗  ██╗██████╗
#  ██╔═══██╗██║  ██║██╔══██╗
#  ██║   ██║███████║██████╔╝
#  ██║   ██║██╔══██║██╔══██╗
#  ╚██████╔╝██║  ██║██████╔╝
#   ╚═════╝ ╚═╝  ╚═╝╚═════╝
#
#  Open HamClock Backend
#  update_aurora_maps.sh
#
#  MIT License
#  Copyright (C) 2026 Open HamClock Backend (OHB) Contributors
#
#  Permission is hereby granted, free of charge, to any person
#  obtaining a copy of this software and associated documentation
#  files (the "Software"), to deal in the Software without
#  restriction, including without limitation the rights to use,
#  copy, modify, merge, publish, distribute, sublicense, and/or
#  sell copies of the Software, and to permit persons to whom the
#  Software is furnished to do so, subject to the following
#  conditions:
#
#  The above copyright notice and this permission notice shall be
#  included in all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
#  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
#  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
#  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
#  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
#  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
#  FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
#  OTHER DEALINGS IN THE SOFTWARE.
#
# ============================================================

set -e

export GMT_USERDIR=/opt/hamclock-backend/tmp
cd $GMT_USERDIR

source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes

JSON=ovation.json
XYZ=ovation.xyz

echo "Fetching OVATION..."
curl -fs https://services.swpc.noaa.gov/json/ovation_aurora_latest.json -o "$JSON"

python3 <<'EOF'
import json
d=json.load(open("ovation.json"))
with open("ovation.xyz","w") as f:
    for lon,lat,val in d["coordinates"]:
        if val <= 4:
            continue
        if lat == 0.0:
            continue
        if lon > 180.0:
            lon -= 360.0
        f.write(f"{lon:.6f} {lat:.6f} {val:.6f}\n")
EOF

echo "Gridding aurora..."
gmt nearneighbor "$XYZ" -R-180/180/-90/90 -I0.25 -S8 -Lx -Gaurora_raw.nc
gmt grdfilter aurora_raw.nc -Fg6 -D0 -Gaurora.nc
gmt grdclip aurora.nc -Sb5/NaN -Gaurora_clipped.nc

cat > aurora.cpt <<EOF
# COLOR_MODEL = RGB
5    8/208/8     10   48/252/0
10   48/252/0    20   152/252/0
20   152/252/0   30   248/252/0
30   248/252/0   40   240/200/16
40   240/200/16  50   232/136/32
50   232/136/32  60   232/84/32
60   232/84/32   70   240/40/16
70   240/40/16   80   248/8/0
80   248/8/0    100   248/8/0
EOF

make_bmp_v4_rgb565_topdown() {
  local inraw="$1" outbmp="$2" W="$3" H="$4"
  python3 - <<'PY' "$inraw" "$outbmp" "$W" "$H"
import struct, sys
inraw, outbmp, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
raw = open(inraw, "rb").read()
exp = W*H*3
if len(raw) != exp:
    raise SystemExit(f"RAW size {len(raw)} != expected {exp}")
pix = bytearray(W*H*2)
j = 0
for i in range(0, len(raw), 3):
    r = raw[i]; g = raw[i+1]; b = raw[i+2]
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    pix[j:j+2] = struct.pack("<H", v)
    j += 2
bfOffBits = 14 + 108
bfSize = bfOffBits + len(pix)
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, bfOffBits)
biSize = 108
rmask, gmask, bmask, amask = 0xF800, 0x07E0, 0x001F, 0x0000
cstype = 0x73524742
endpoints = b"\x00"*36
gamma = b"\x00"*12
v4hdr = struct.pack("<IiiHHIIIIII",
    biSize, W, -H, 1, 16, 3, len(pix), 0, 0, 0, 0
) + struct.pack("<IIII", rmask, gmask, bmask, amask) \
  + struct.pack("<I", cstype) + endpoints + gamma
with open(outbmp, "wb") as f:
    f.write(filehdr); f.write(v4hdr); f.write(pix)
PY
}

zlib_compress() {
  local in="$1" out="$2"
  python3 -c "
import zlib, sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(zlib.compress(data, 9))
" "$in" "$out"
}

# ---------------------------------------------------------------------------
# ImageMagick 6: raised resource limits for very large maps
# ---------------------------------------------------------------------------
export MAGICK_LIMIT_WIDTH=65536
export MAGICK_LIMIT_HEIGHT=65536
export MAGICK_LIMIT_AREA=4096MB
export MAGICK_LIMIT_MEMORY=2048MB
export MAGICK_LIMIT_MAP=4096MB
export MAGICK_LIMIT_DISK=8192MB
im_convert() {
  convert \
    -limit width    65536  \
    -limit height   65536  \
    -limit area     4096MB \
    -limit memory   2048MB \
    -limit map      4096MB \
    -limit disk     8192MB \
    "$@"
}

echo "Rendering maps..."

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$OUTDIR"

for DN in D N; do
for SZ in "${SIZES[@]}"; do
  BASE="$GMT_USERDIR/aurora_${DN}_${SZ}"
  PNG="${BASE}.png"
  PNG_FIXED="${BASE}_fixed.png"
  BMP="$OUTDIR/map-${DN}-${SZ}-Aurora.bmp"

  W=${SZ%x*}
  H=${SZ#*x}
  MAX_RENDER=7000
  if (( W * 2 > MAX_RENDER )); then
    RENDER_W=$W
    RENDER_H=$H
  else
    RENDER_W=$((W * 2))
    RENDER_H=$((H * 2))
  fi

  echo "  -> ${DN} ${SZ}"

  PS="${BASE}.ps"
  W_cm=$(awk "BEGIN{printf \"%.4f\", $RENDER_W * 2.54 / 72}")
  H_cm=$(awk "BEGIN{printf \"%.4f\", $RENDER_H * 2.54 / 72}")
  GMT_CONF="$GMT_USERDIR/gmtconf_aurora_${DN}_${SZ}"
  mkdir -p "$GMT_CONF"
  GMT_USERDIR="$GMT_CONF" gmt set \
    PS_MEDIA "${W_cm}cx${H_cm}c" \
    MAP_ORIGIN_X 0c \
    MAP_ORIGIN_Y 0c

  (
    cd "$GMT_USERDIR" || exit 1
    if [[ "$DN" == "D" ]]; then
      FILL="74/73/74"
    else
      FILL="0/0/0"
    fi
    GMT_USERDIR="$GMT_CONF" \
    gmt pscoast -R-180/180/-90/90 -JQ0/${RENDER_W}p -G${FILL} -S${FILL} -A10000 \
      --MAP_FRAME_AXES= -P -K > "$PS"
    GMT_USERDIR="$GMT_CONF" \
    gmt grdimage aurora_clipped.nc -R-180/180/-90/90 -JQ0/${RENDER_W}p \
      -Caurora.cpt -Q -n+b --MAP_FRAME_AXES= -O -K >> "$PS"
    GMT_USERDIR="$GMT_CONF" \
    gmt pscoast -R-180/180/-90/90 -JQ0/${RENDER_W}p \
      -W1.25p,white -N1/1.10p,white -A10000 --MAP_FRAME_AXES= -O -K >> "$PS"
    gmt psxy -R -J -T -O >> "$PS"
    gs -dBATCH -dNOPAUSE -dSAFER -dQUIET \
       -sDEVICE=png16m \
       -r72 \
       -dDEVICEWIDTHPOINTS=${RENDER_W} \
       -dDEVICEHEIGHTPOINTS=${RENDER_H} \
       -sOutputFile="$PNG" \
       "$PS"
  ) || { echo "gmt/gs failed for ${DN} $SZ" >&2; continue; }

  im_convert "$PNG" -filter Lanczos -resize "${SZ}!" "$PNG_FIXED" || { echo "resize failed for $SZ"; continue; }

  RAW="$GMT_USERDIR/aurora_${DN}_${SZ}.raw"
  im_convert "$PNG_FIXED" RGB:"$RAW" || { echo "raw extract failed for $SZ"; continue; }
  make_bmp_v4_rgb565_topdown "$RAW" "$BMP" "$W" "$H" || { echo "bmp write failed for $SZ"; continue; }
  rm -f "$RAW" "$PNG" "$PNG_FIXED" "$PS"

  zlib_compress "$BMP" "${BMP}.z"
  chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true

  echo "  -> Done: $BMP"
done
done

rm -f aurora_raw.nc aurora.nc aurora_clipped.nc aurora.cpt ovation.xyz

echo "Done."
