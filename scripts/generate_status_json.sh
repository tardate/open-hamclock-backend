#!/bin/bash
# generate_status.sh
# Generates a static status board HTML for HamClock data products & maps.
# Run via cron every 5 minutes, e.g.:
#   */5 * * * * /opt/hamclock-backend/generate_status.sh

# ── Config ──────────────────────────────────────────────────────────────────
DATA_DIR="/opt/hamclock-backend/htdocs/ham/HamClock"
MAPS_DIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
OUTPUT="/opt/hamclock-backend/htdocs/ham/HamClock/status.html"
OUTPUT_JSON="${OUTPUT%.html}.json"
CALLSIGN="OHB"          # your station callsign
VERSION=$(cat /opt/hamclock-backend/git.version | cut -b -12)
TZ_LABEL="UTC"          # display timezone label

# Named data product subdirectories to enumerate (order preserved in output)
DATA_SUBDIRS=(
    Bz
    NOAASpaceWX
    ONTA
    RSS
    SDO
    aurora
    contests
    cty
    drap
    dst
    dxpeds
    esats
    geomag
    solar-flux
    solar-wind
    ssn
    worldwx
    xray
)
# ─────────────────────────────────────────────────────────────────────────────

NOW=$(date -u "+%Y-%m-%d %H:%M:%S")
NOW_EPOCH=$(date -u +%s)

# Emit HTML rows for every file in a given directory.
# Args: $1=directory  $2=category-label
build_rows() {
    local dir="$1"
    local label="$2"

    if [ ! -d "$dir" ]; then
        echo "    <tr><td colspan='4' class='missing'>⚠ Directory not found: ${dir}</td></tr>"
        return
    fi

    local found=0
    while IFS= read -r -d '' filepath; do
        local filename
        filename=$(basename "$filepath")
        [ $filename == ignore ] && continue
        found=1
        local mod_epoch
        mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null)
        local mod_human
        mod_human=$(date -u -d "@$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                 || date -u -r "$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        local age_sec=$(( NOW_EPOCH - mod_epoch ))
        local age_min=$(( age_sec / 60 ))
        local age_h=$(( age_sec / 3600 ))

        local status_class status_text
        if   [ "$age_sec" -lt 300 ];   then status_class="ok";    status_text="FRESH"
        elif [ "$age_sec" -lt 1800 ];  then status_class="warn";  status_text="RECENT"
        elif [ "$age_sec" -lt 86400 ]; then status_class="aged";  status_text="AGED"
        else                                status_class="stale"; status_text="STALE"
        fi

        local age_str
        if   [ "$age_h"   -ge 48 ]; then age_str="$(( age_h / 24 ))d ago"
        elif [ "$age_h"   -ge 1  ]; then age_str="${age_h}h ago"
        elif [ "$age_min" -ge 1  ]; then age_str="${age_min}m ago"
        else                             age_str="${age_sec}s ago"
        fi

        echo "    <tr>"
        echo "      <td class='name'>${filename}</td>"
        echo "      <td class='category'>${label}</td>"
        echo "      <td class='timestamp'>${mod_human} UTC</td>"
        echo "      <td class='age'><span class='badge ${status_class}'>${status_text}</span><span class='age-str'> ${age_str}</span></td>"
        echo "    </tr>"
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)

    if [ "$found" -eq 0 ]; then
        echo "    <tr><td colspan='4' class='empty'>— no files in ${label}/ —</td></tr>"
    fi
}

# Iterate each named data subdir, emit a subdir-header row then its files.
build_data_rows() {
    local first=1
    for subdir in "${DATA_SUBDIRS[@]}"; do
        local dir="${DATA_DIR}/${subdir}"

        if [ "$first" -eq 1 ]; then first=0; else
            echo "    <tr class='divider'><td colspan='4'></td></tr>"
        fi

        echo "    <tr class='subdir-header'>"
        echo "      <td colspan='4'>"
        echo "        <span class='subdir-label'>${subdir}/</span>"
        if [ ! -d "$dir" ]; then
            echo "        <span class='subdir-missing'>directory not found</span>"
        fi
        echo "      </td>"
        echo "    </tr>"

        build_rows "$dir" "$subdir"
    done
}

# Count files across all named data subdirs
count_data_files() {
    local total=0
    for subdir in "${DATA_SUBDIRS[@]}"; do
        local n
        n=$(find "${DATA_DIR}/${subdir}" -maxdepth 1 -type f 2>/dev/null | wc -l)
        total=$(( total + n ))
    done
    echo "$total"
}

# Emit JSON entry objects for every file in a given directory.
# Args: $1=directory  $2=category-label  $3=ref to first-entry flag (0/1)
build_json_entries() {
    local dir="$1"
    local label="$2"
    local -n _first_entry="$3"   # nameref so caller's flag is updated

    [ ! -d "$dir" ] && return

    while IFS= read -r -d '' filepath; do
        local filename
        filename=$(basename "$filepath")
        [ "$filename" == ignore ] && continue

        local mod_epoch
        mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null)
        local mod_human
        mod_human=$(date -u -d "@$mod_epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                 || date -u -r "$mod_epoch"   "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
        local age_sec=$(( NOW_EPOCH - mod_epoch ))

        local status_text
        if   [ "$age_sec" -lt 300 ];   then status_text="FRESH"
        elif [ "$age_sec" -lt 1800 ];  then status_text="RECENT"
        elif [ "$age_sec" -lt 86400 ]; then status_text="AGED"
        else                                status_text="STALE"
        fi

        # Escape filename for JSON (handle backslash and double-quote)
        local safe_name safe_label
        safe_name=$(printf '%s' "$filename" | sed 's/\\/\\\\/g; s/"/\\"/g')
        safe_label=$(printf '%s' "$label"   | sed 's/\\/\\\\/g; s/"/\\"/g')

        [ "$_first_entry" -eq 0 ] && printf ',\n'
        _first_entry=0
        printf '    {\n'
        printf '      "filename": "%s",\n'      "$safe_name"
        printf '      "category": "%s",\n'      "$safe_label"
        printf '      "modified_utc": "%s",\n'  "$mod_human"
        printf '      "age_seconds": %d,\n'     "$age_sec"
        printf '      "status": "%s"\n'         "$status_text"
        printf '    }'
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
}

# Build the complete JSON document and write it to OUTPUT_JSON
build_json() {
    local first_entry=1

    {
        printf '{\n'
        printf '  "generated_utc": "%s",\n'      "$NOW"
        printf '  "callsign": "%s",\n'           "$CALLSIGN"
        printf '  "version": "%s",\n'            "$VERSION"
        printf '  "summary": {\n'
        printf '    "data_product_files": %d,\n' "$DATA_COUNT"
        printf '    "map_files": %d,\n'          "$MAPS_COUNT"
        printf '    "total_files": %d\n'         "$(( DATA_COUNT + MAPS_COUNT ))"
        printf '  },\n'
        printf '  "files": [\n'

        for subdir in "${DATA_SUBDIRS[@]}"; do
            build_json_entries "${DATA_DIR}/${subdir}" "$subdir" first_entry
        done
        build_json_entries "$MAPS_DIR" "map" first_entry

        printf '\n  ]\n'
        printf '}\n'
    } > "$OUTPUT_JSON"
}

DATA_COUNT=$(count_data_files)
MAPS_COUNT=$(find "$MAPS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

# ── Write HTML ───────────────────────────────────────────────────────────────
{
cat << HTML_HEAD
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="refresh" content="300">
  <title>${CALLSIGN} · Data Product Status</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg:       #f7f5f2;
      --panel:    #fdfcfa;
      --border:   #e0dbd4;
      --accent:   #3d6b99;
      --accent2:  #3a7a56;
      --dim:      #9a9590;
      --text:     #2e2b27;
      --muted:    #7a756e;
      --ok:       #2e7a50;
      --warn:     #8a6200;
      --aged:     #8a4e00;
      --stale:    #9e2020;
    }

    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      background: var(--bg);
      color: var(--text);
      font-family: 'IBM Plex Sans', sans-serif;
      font-size: 14px;
      line-height: 1.6;
      min-height: 100vh;
      overflow-x: hidden;
    }

    /* ── Header ── */
    header {
      border-bottom: 1px solid var(--border);
      padding: 20px 24px 16px;
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 12px;
      background: var(--panel);
      flex-wrap: wrap;
    }
    .header-left { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
    .callsign {
      font-family: 'IBM Plex Sans', sans-serif;
      font-weight: 600;
      font-size: clamp(1.3rem, 5vw, 2.2rem);
      letter-spacing: 0.04em;
      color: var(--accent);
      line-height: 1.1;
    }
    .subtitle { font-size: 0.7rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; }
    .header-right {
      text-align: right;
      display: flex;
      flex-direction: column;
      gap: 3px;
      align-items: flex-end;
      flex-shrink: 0;
    }
    .clock-label { font-size: 0.65rem; letter-spacing: 0.05em; color: var(--muted); text-transform: uppercase; }
    .clock {
      font-family: 'IBM Plex Mono', monospace;
      font-size: clamp(0.78rem, 2.5vw, 1.0rem);
      color: var(--accent2);
      letter-spacing: 0.02em;
      font-weight: 500;
    }

    /* ── Summary bar: 2-up grid so it wraps nicely on mobile ── */
    .summary {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      border-bottom: 1px solid var(--border);
      background: var(--panel);
    }
    .summary-item {
      padding: 12px 20px;
      border-right: 1px solid var(--border);
      border-bottom: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      gap: 2px;
    }
    /* right column has no right border */
    .summary-item:nth-child(2n) { border-right: none; }
    /* bottom row has no bottom border */
    .summary-item:nth-last-child(-n+2) { border-bottom: none; }
    .summary-label { font-size: 0.62rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; }
    .summary-value { font-family: 'IBM Plex Mono', monospace; font-size: 1.25rem; font-weight: 500; color: var(--accent); }

    /* ── Legend ── */
    .legend {
      display: flex;
      gap: 12px;
      padding: 10px 24px;
      background: #f0ede8;
      border-bottom: 1px solid var(--border);
      flex-wrap: wrap;
      align-items: center;
    }
    .legend-item { display: flex; align-items: center; gap: 5px; font-size: 0.65rem; color: var(--muted); }

    /* ── Sections ── */
    .section { padding: 20px 24px; border-bottom: 1px solid var(--border); }
    .section-header { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
    .section-icon {
      width: 4px; height: 18px; background: var(--accent);
      border-radius: 2px; flex-shrink: 0; opacity: 0.7;
    }
    .maps-icon { background: var(--accent2); }
    .section-title {
      font-family: 'IBM Plex Sans', sans-serif; font-size: 0.78rem; font-weight: 600;
      letter-spacing: 0.07em; color: var(--text); text-transform: uppercase;
    }
    .section-path {
      font-family: 'IBM Plex Mono', monospace;
      font-size: 0.62rem;
      color: var(--dim);
      margin-left: auto;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
      max-width: 40vw;
    }

    /* ── Table ── */
    table { width: 100%; border-collapse: collapse; font-size: 0.83rem; }
    thead tr { border-bottom: 1px solid var(--border); }
    th {
      font-size: 0.64rem; letter-spacing: 0.06em; color: var(--muted);
      text-transform: uppercase; text-align: left; padding: 7px 10px; font-weight: 500;
    }
    tbody tr { border-bottom: 1px solid rgba(200,193,185,0.4); transition: background 0.12s; }
    tbody tr:hover { background: rgba(61,107,153,0.04); }

    tr.subdir-header { background: rgba(61,107,153,0.05); border-top: 1px solid var(--border); border-bottom: none; }
    tr.subdir-header:hover { background: rgba(61,107,153,0.05); }
    tr.subdir-header td { padding: 6px 10px; }
    .subdir-label {
      font-family: 'IBM Plex Mono', monospace; font-size: 0.73rem;
      font-weight: 500; letter-spacing: 0.02em; color: var(--accent);
    }
    .subdir-missing { font-size: 0.65rem; color: var(--stale); margin-left: 8px; }
    tr.divider td { padding: 0; height: 4px; background: transparent; border: none; }

    td { padding: 8px 10px; vertical-align: middle; }
    td.name {
      font-family: 'IBM Plex Mono', monospace;
      color: var(--text);
      word-break: break-all;   /* long filenames wrap rather than overflow */
      min-width: 0;
    }
    td.category { color: var(--muted); font-size: 0.73rem; white-space: nowrap; }
    td.timestamp { font-family: 'IBM Plex Mono', monospace; color: var(--dim); white-space: nowrap; font-size: 0.78rem; }
    td.age { white-space: nowrap; }
    .age-str { color: var(--dim); font-size: 0.78rem; }

    td.missing { color: var(--stale); font-size: 0.76rem; padding: 10px; }
    td.empty   { color: var(--muted); font-size: 0.76rem; padding: 8px 10px; font-style: italic; }

    /* ── Badges ── */
    .badge {
      display: inline-block; padding: 2px 8px; border-radius: 3px;
      font-size: 0.63rem; font-family: 'IBM Plex Sans', sans-serif;
      font-weight: 600; letter-spacing: 0.03em; vertical-align: middle;
    }
    .badge.ok    { background: #e8f4ee; color: var(--ok);    border: 1px solid #b8d8c5; }
    .badge.warn  { background: #f7f0de; color: var(--warn);  border: 1px solid #dfc882; }
    .badge.aged  { background: #f7ede0; color: var(--aged);  border: 1px solid #ddb882; }
    .badge.stale { background: #f5e8e8; color: var(--stale); border: 1px solid #d8a8a8; }

    /* ── Footer ── */
    footer {
      padding: 12px 24px;
      display: flex; justify-content: space-between; align-items: center;
      flex-wrap: wrap; gap: 8px;
      border-top: 1px solid var(--border);
      background: var(--panel);
    }
    .footer-note { font-size: 0.65rem; color: var(--muted); }
    .refresh-indicator { font-size: 0.65rem; color: var(--dim); display: flex; align-items: center; gap: 5px; }
    .pulse {
      width: 7px; height: 7px; border-radius: 50%;
      background: var(--accent2); opacity: 0.75;
      animation: pulse 2.5s ease-in-out infinite; flex-shrink: 0;
    }
    @keyframes pulse {
      0%, 100% { opacity: 0.75; transform: scale(1); }
      50%       { opacity: 0.3;  transform: scale(0.7); }
    }

    /* ── Mobile (≤ 600px): hide timestamp + category columns ── */
    @media (max-width: 600px) {
      header   { padding: 14px 16px 12px; }
      .section { padding: 14px 16px; }
      .legend  { padding: 9px 16px; gap: 8px; }
      footer   { padding: 10px 16px; }

      .summary-item { padding: 10px 14px; }
      .summary-value { font-size: 1.05rem; }

      .section-path { display: none; }

      /* drop the two least-important columns to keep the table readable */
      th.col-category,  td.category  { display: none; }
      th.col-timestamp, td.timestamp { display: none; }

      td.age { white-space: normal; }
      th, td { padding: 6px 8px; }
    }

    /* ── Very small screens (≤ 380px): single-column summary ── */
    @media (max-width: 380px) {
      .callsign { font-size: 1.15rem; }
      .clock    { font-size: 0.72rem; }
      .summary  { grid-template-columns: 1fr; }
      .summary-item:nth-child(2n)        { border-right: none; }
      .summary-item:nth-last-child(-n+2) { border-bottom: 1px solid var(--border); }
      .summary-item:last-child           { border-bottom: none; }
    }
  </style>
</head>
<body>

<header>
  <div class="header-left">
    <div class="callsign">${CALLSIGN}</div>
    <div class="subtitle">Data Product Status Board / ${VERSION}</div>
  </div>
  <div class="header-right">
    <div class="clock-label">Page generated</div>
    <div class="clock">${NOW} ${TZ_LABEL}</div>
    <div class="clock-label" style="margin-top:4px">Auto-refreshes every 5 min</div>
  </div>
</header>

<div class="summary">
  <div class="summary-item">
    <span class="summary-label">Data Product Files</span>
    <span class="summary-value">${DATA_COUNT}</span>
  </div>
  <div class="summary-item">
    <span class="summary-label">Map Files</span>
    <span class="summary-value">${MAPS_COUNT}</span>
  </div>
  <div class="summary-item">
    <span class="summary-label">Total Files</span>
    <span class="summary-value">$(( DATA_COUNT + MAPS_COUNT ))</span>
  </div>
  <div class="summary-item">
    <span class="summary-label">Last Board Update</span>
    <span class="summary-value" style="font-size:0.82rem;padding-top:3px">${NOW}</span>
  </div>
</div>

<div class="legend">
  <span style="font-size:0.63rem;color:var(--muted);margin-right:2px">STATUS:</span>
  <div class="legend-item"><span class="badge ok">FRESH</span> &lt; 5 min</div>
  <div class="legend-item"><span class="badge warn">RECENT</span> 5 – 30 min</div>
  <div class="legend-item"><span class="badge aged">AGED</span> 30 min – 24 h</div>
  <div class="legend-item"><span class="badge stale">STALE</span> &gt; 24 h</div>
</div>

<!-- Data Products -->
<div class="section">
  <div class="section-header">
    <div class="section-icon"></div>
    <span class="section-title">Data Products</span>
    <span class="section-path">${DATA_DIR}/{Bz,NOAASpaceWX,ONTA,RSS,SDO,aurora,contests,cty,drap,dst,dxpeds,esats,geomag,solar-flux,solar-wind,ssn,worldwx,xray}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Filename</th>
        <th class="col-category">Category</th>
        <th class="col-timestamp">Last Modified (UTC)</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
HTML_HEAD

build_data_rows

cat << HTML_MAPS
    </tbody>
  </table>
</div>

<!-- Maps -->
<div class="section">
  <div class="section-header">
    <div class="section-icon maps-icon"></div>
    <span class="section-title">Maps</span>
    <span class="section-path">${MAPS_DIR}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Filename</th>
        <th class="col-category">Category</th>
        <th class="col-timestamp">Last Modified (UTC)</th>
        <th>Status</th>
      </tr>
    </thead>
    <tbody>
HTML_MAPS

build_rows "$MAPS_DIR" "map"

cat << HTML_FOOT
    </tbody>
  </table>
</div>

<footer>
  <div class="footer-note">73 · ${CALLSIGN} · Generated by generate_status.sh / ${VERSION}</div>
  <div class="refresh-indicator">
    <div class="pulse"></div>
    Auto-refresh active · every 5 minutes
  </div>
</footer>

</body>
</html>
HTML_FOOT

} > "$OUTPUT"

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Status board written to ${OUTPUT}"

build_json
echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] JSON status written  to ${OUTPUT_JSON}"
