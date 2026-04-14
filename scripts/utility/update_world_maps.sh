#!/bin/bash
# update_world_maps.sh
# Generates two map types for HamClock-compatible use:
#   1. Countries map  (political borders, day/night variants)
#   2. Terrain relief map (ETOPO/SRTM shaded relief, day/night variants)
#
# Output: BMP (RGB565, V4 header, top-down) + zlib-compressed .bmp.z
# Sizes: 660x330 1320x660 1980x990 2640x1320 3960x1980 5280x2640 5940x2970 7920x3960

set -e

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
export GMT_USERDIR=/opt/hamclock-backend/tmp
OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$GMT_USERDIR" "$OUTDIR"
cd "$GMT_USERDIR"

ALL_SIZES=(
  "660x330"
  "1320x660"
  "1980x990"
  "2640x1320"
  "3960x1980"
  "5280x2640"
  "5940x2970"
  "7920x3960"
)

# Allow sizes and map types to be filtered via arguments:
#   ./update_world_maps.sh [size ...] [--type Countries|Terrain] [--day] [--night]
#
# Examples:
#   ./update_world_maps.sh                          # all sizes, both types, D+N
#   ./update_world_maps.sh 660x330                  # one size only
#   ./update_world_maps.sh 660x330 1320x660         # two sizes
#   ./update_world_maps.sh --type Terrain 1320x660  # terrain only, one size
#   ./update_world_maps.sh --day 660x330            # day variant only
#   ./update_world_maps.sh --type Countries --night # countries night, all sizes

SIZES=()
FILTER_TYPES=()
FILTER_DN=()
i=1
while [[ $i -le $# ]]; do
  arg="${!i}"
  case "$arg" in
    --type)
      i=$(( i+1 ))
      FILTER_TYPES+=("${!i}") ;;
    --day)   FILTER_DN+=("D") ;;
    --night) FILTER_DN+=("N") ;;
    --cpt)
      i=$(( i+1 ))
      TERRAIN_CPT_DAY="${!i}"
      TERRAIN_CPT_NIGHT="${!i}" ;;
    *x*)     SIZES+=("$arg") ;;
    *)       echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
  i=$(( i+1 ))
done

[[ ${#SIZES[@]}      -eq 0 ]] && SIZES=("${ALL_SIZES[@]}")
[[ ${#FILTER_TYPES[@]} -eq 0 ]] && FILTER_TYPES=("Countries" "Terrain")
[[ ${#FILTER_DN[@]}  -eq 0 ]] && FILTER_DN=("D" "N")

# Terrain CPT defaults (day uses geo, night uses globe dimmed to 55%)
# Override both with --cpt <name>, e.g.: --cpt srtm
# Available GMT built-ins worth trying: geo srtm dem1 dem2 etopo1 relief globe
TERRAIN_CPT_DAY="${TERRAIN_CPT_DAY:-geo}"
TERRAIN_CPT_NIGHT="${TERRAIN_CPT_NIGHT:-globe}"

echo "Sizes   : ${SIZES[*]}"
echo "Types   : ${FILTER_TYPES[*]}"
echo "Variants: ${FILTER_DN[*]}"
echo "CPT day : ${TERRAIN_CPT_DAY}  / night: ${TERRAIN_CPT_NIGHT}"

# ---------------------------------------------------------------------------
# ImageMagick resource limits (same as aurora script)
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

# ---------------------------------------------------------------------------
# Shared helpers (identical to aurora script)
# ---------------------------------------------------------------------------

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

# Rasterize a PostScript file to PNG via Ghostscript, then resize + convert to BMP
render_ps_to_bmp() {
  local PS="$1" PNG="$2" PNG_FIXED="$3" BMP="$4" RENDER_W="$5" RENDER_H="$6" W="$7" H="$8" SZ="$9"

  gs -dBATCH -dNOPAUSE -dSAFER -dQUIET \
     -sDEVICE=png16m \
     -r72 \
     -dDEVICEWIDTHPOINTS=${RENDER_W} \
     -dDEVICEHEIGHTPOINTS=${RENDER_H} \
     -sOutputFile="$PNG" \
     "$PS" || { echo "  gs failed for $SZ" >&2; return 1; }

  im_convert "$PNG" -filter Lanczos -resize "${SZ}!" "$PNG_FIXED" \
    || { echo "  resize failed for $SZ" >&2; return 1; }

  RAW="${BMP%.bmp}.raw"
  im_convert "$PNG_FIXED" RGB:"$RAW" \
    || { echo "  raw extract failed for $SZ" >&2; return 1; }

  make_bmp_v4_rgb565_topdown "$RAW" "$BMP" "$W" "$H" \
    || { echo "  bmp write failed for $SZ" >&2; return 1; }

  rm -f "$RAW" "$PNG" "$PNG_FIXED" "$PS"

  zlib_compress "$BMP" "${BMP}.z"
  chmod 0644 "$BMP" "${BMP}.z" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# CPT colour tables
# ---------------------------------------------------------------------------

# Day terrain: GMT built-in 'geo' CPT — the classic continuous hypsometric
# tint used in most published GMT maps.  No hard colour bands.
gmt makecpt -C"${TERRAIN_CPT_DAY}" -T-8000/8000 -Z > terrain_D.cpt

# Night terrain: GMT built-in 'globe' CPT (darker, more dramatic), then
# dimmed further to ~55% brightness for a night feel.
gmt makecpt -C"${TERRAIN_CPT_NIGHT}" -T-8000/8000 -Z > terrain_N.cpt
python3 - <<'PY'
import re
lines = open("terrain_N.cpt").readlines()
out = []
for line in lines:
    m = re.match(
        r'^(-?[\d.eE+-]+)\s+(\d+)/(\d+)/(\d+)\s+(-?[\d.eE+-]+)\s+(\d+)/(\d+)/(\d+)(.*)',
        line.strip()
    )
    if m:
        v1,r1,g1,b1,v2,r2,g2,b2,rest = m.groups()
        def dim(c): return int(int(c)*0.55)
        out.append(f"{v1}\t{dim(r1)}/{dim(g1)}/{dim(b1)}\t{v2}\t{dim(r2)}/{dim(g2)}/{dim(b2)}{rest}\n")
    else:
        out.append(line)
open("terrain_N.cpt","w").writelines(out)
PY

# ---------------------------------------------------------------------------
# Download ETOPO terrain grid (only once)
# ---------------------------------------------------------------------------
ETOPO_NC="$GMT_USERDIR/etopo_world.nc"

if [[ ! -f "$ETOPO_NC" ]]; then
  echo "Fetching ETOPO terrain grid from GMT server..."
  # GMT's @earth_relief_10m is the 10 arc-minute global relief model (~17 MB).
  # For sharper relief at large sizes you can use 05m (5 arc-min, ~65 MB) or
  # 02m (2 arc-min, ~350 MB) — change the tag below and re-run.
  gmt grdcut @earth_relief_10m -R-180/180/-90/90 -G"$ETOPO_NC" \
    || { echo "gmt earth_relief download failed — check internet / GMT data server" >&2; exit 1; }
  echo "  Terrain grid saved: $ETOPO_NC"
fi

# ---------------------------------------------------------------------------
# Pre-compute hillshade (once, at full resolution)
# ---------------------------------------------------------------------------
# Technique:
#   1. Dual-azimuth gradient (-A315/45): NW sun (cartographic convention) +
#      45 deg catches east-facing slopes too.
#   2. -Ne0.6 normalises to a well-spread intensity range for grdimage.
#   3. grdhisteq stretches contrast over the full range so shading looks
#      punchy even over low-relief abyssal plains.
SHADE_NC="$GMT_USERDIR/hillshade.nc"
SHADE_RAW="$GMT_USERDIR/hillshade_raw.nc"
if [[ ! -f "$SHADE_NC" ]]; then
  echo "Computing hillshade (dual-azimuth + histogram equalisation)..."
  gmt grdgradient "$ETOPO_NC" -A315/45 -Ne0.6 -G"$SHADE_RAW"
  gmt grdhisteq "$SHADE_RAW" -G"$SHADE_NC" -N
  MAXVAL=$(gmt grdinfo "$SHADE_NC" -C | awk '{print $7}')
  gmt grdmath "$SHADE_NC" "$MAXVAL" DIV = "$SHADE_NC"
  rm -f "$SHADE_RAW"
fi

# ===========================================================================
#  LOOP: map types x day/night x sizes
# ===========================================================================

for MAPTYPE in "${FILTER_TYPES[@]}"; do
for DN in "${FILTER_DN[@]}"; do
  echo ""
  echo "=== ${MAPTYPE} / ${DN} ==="

  for SZ in "${SIZES[@]}"; do
    W=${SZ%x*}
    H=${SZ#*x}

    # Render at 2x then downscale (same logic as aurora script)
    MAX_RENDER=7000
    if (( W * 2 > MAX_RENDER )); then
      RENDER_W=$W
      RENDER_H=$H
    else
      RENDER_W=$((W * 2))
      RENDER_H=$((H * 2))
    fi

    BASE="$GMT_USERDIR/${MAPTYPE}_${DN}_${SZ}"
    PS="${BASE}.ps"
    PNG="${BASE}.png"
    PNG_FIXED="${BASE}_fixed.png"
    BMP="$OUTDIR/map-${DN}-${SZ}-${MAPTYPE}.bmp"

    echo "  -> ${DN} ${SZ} (render ${RENDER_W}x${RENDER_H})"

    # Per-size GMT config dir (avoids concurrent write collisions)
    GMT_CONF="$GMT_USERDIR/gmtconf_${MAPTYPE}_${DN}_${SZ}"
    mkdir -p "$GMT_CONF"
    GMT_USERDIR="$GMT_CONF" gmt set \
      PS_MEDIA "${RENDER_W}px${RENDER_H}p" \
      MAP_ORIGIN_X 0c \
      MAP_ORIGIN_Y 0c

    # -----------------------------------------------------------------
    # Build PostScript — different pipeline per map type
    # -----------------------------------------------------------------
    (
      cd "$GMT_USERDIR" || exit 1

      if [[ "$MAPTYPE" == "Countries" ]]; then
        # ---------------------------------------------------------------
        # Countries map
        # Day:   blue ocean, muted-green land, white borders + country borders
        # Night: black ocean, very dark land, dim borders
        # ---------------------------------------------------------------
        if [[ "$DN" == "D" ]]; then
          OCEAN="30/100/200"    # medium blue
          LAND="100/140/70"     # muted green
          BORDER_W="1.0p,white"
          CBORDER="0.4p,200/200/200"   # country borders
          NBORDER="0.8p,white"         # national borders (coastline weight)
        else
          OCEAN="0/0/0"
          LAND="15/25/10"
          BORDER_W="0.8p,50/50/50"
          CBORDER="0.3p,40/40/40"
          NBORDER="0.6p,60/60/60"
        fi

        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -G${LAND} -S${OCEAN} \
            -A500 \
            --MAP_FRAME_AXES=WSne \
            -P -K > "$PS"

        # Country political borders (borders level 1 = national)
        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -N1/${CBORDER} \
            -W${BORDER_W} \
            -A500 \
            --MAP_FRAME_AXES= \
            -O -K >> "$PS"

        gmt psxy -R -J -T -O >> "$PS"

      else
        # ---------------------------------------------------------------
        # Terrain / Relief map
        # Day:   hypsometric tint + hillshade
        # Night: dark hypsometric tint + subtle hillshade
        # ---------------------------------------------------------------
        if [[ "$DN" == "D" ]]; then
          CPT="$GMT_USERDIR/terrain_D.cpt"
          INTENSITY="-I${GMT_USERDIR}/hillshade.nc"
          COAST_W="0.5p,50/50/50"
          BORDER_C="0.3p,80/80/80"
        else
          CPT="$GMT_USERDIR/terrain_N.cpt"
          INTENSITY="-I${GMT_USERDIR}/hillshade.nc"
          COAST_W="0.5p,20/20/20"
          BORDER_C="0.2p,30/30/30"
        fi

        # Base: filled coast (ocean colour from CPT bottom)
        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -G128/128/128 -S128/128/128 \
            -A500 \
            --MAP_FRAME_AXES=WSne \
            -P -K > "$PS"

        # Terrain grid image (hypsometric + hillshade)
        GMT_USERDIR="$GMT_CONF" \
          gmt grdimage "$ETOPO_NC" \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -C${CPT} \
            ${INTENSITY} \
            -n+b \
            --MAP_FRAME_AXES= \
            -O -K >> "$PS"

        # Coastlines + country borders on top
        GMT_USERDIR="$GMT_CONF" \
          gmt pscoast \
            -R-180/180/-90/90 -JQ0/${RENDER_W}p \
            -W${COAST_W} \
            -N1/${BORDER_C} \
            -A500 \
            --MAP_FRAME_AXES= \
            -O -K >> "$PS"

        gmt psxy -R -J -T -O >> "$PS"
      fi

    ) || { echo "  GMT failed for ${MAPTYPE} ${DN} $SZ" >&2; continue; }

    render_ps_to_bmp \
      "$PS" "$PNG" "$PNG_FIXED" "$BMP" \
      "$RENDER_W" "$RENDER_H" "$W" "$H" "$SZ" \
      || continue

    echo "  -> Done: $BMP  (+${BMP}.z)"

  done   # sizes
done     # D/N
done     # MAPTYPE

echo ""
echo "All maps complete. Output in: $OUTDIR"
