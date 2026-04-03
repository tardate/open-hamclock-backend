#!/bin/bash
# generate_status.sh
# Generates a static status board HTML for HamClock data products & maps.
# Run via cron every 5 minutes, e.g.:
#   */5 * * * * /opt/hamclock-backend/generate_status.sh

# ── Config ──────────────────────────────────────────────────────────────────
DATA_DIR="/opt/hamclock-backend/htdocs/ham/HamClock"
MAPS_DIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
OUTPUT="/opt/hamclock-backend/htdocs/ham/HamClock/status.html"
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
        echo "      <td class='age'><span class='badge ${status_class}'>${status_text}</span> ${age_str}</td>"
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
  <link href="https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Orbitron:wght@400;700;900&display=swap" rel="stylesheet">
  <style>
	/* ============================================================
	   OHB HamClock Status Board — Stylesheet
	   Fonts: IBM Plex Sans + IBM Plex Mono (Google Fonts)
	   Add this to your <head>:
		 <link rel="preconnect" href="https://fonts.googleapis.com">
		 <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">
	   ============================================================ */

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

	header {
	  border-bottom: 1px solid var(--border);
	  padding: 24px 32px 20px;
	  display: flex; align-items: flex-start; justify-content: space-between; gap: 16px;
	  background: var(--panel);
	}
	.header-left { display: flex; flex-direction: column; gap: 5px; }
	.callsign {
	  font-family: 'IBM Plex Sans', sans-serif; font-weight: 600;
	  font-size: clamp(1.5rem, 4vw, 2.2rem); letter-spacing: 0.04em;
	  color: var(--accent);
	  line-height: 1.1;
	}
	.subtitle { font-size: 0.73rem; letter-spacing: 0.08em; color: var(--muted); text-transform: uppercase; }
	.header-right { text-align: right; display: flex; flex-direction: column; gap: 4px; align-items: flex-end; }
	.clock-label { font-size: 0.68rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; }
	.clock {
	  font-family: 'IBM Plex Mono', monospace; font-size: clamp(0.85rem, 2vw, 1.05rem);
	  color: var(--accent2); letter-spacing: 0.03em; font-weight: 500;
	}

	.summary { display: flex; border-bottom: 1px solid var(--border); background: var(--panel); }
	.summary-item {
	  flex: 1; padding: 14px 24px; border-right: 1px solid var(--border);
	  display: flex; flex-direction: column; gap: 3px;
	}
	.summary-item:last-child { border-right: none; }
	.summary-label { font-size: 0.65rem; letter-spacing: 0.07em; color: var(--muted); text-transform: uppercase; }
	.summary-value { font-family: 'IBM Plex Mono', monospace; font-size: 1.35rem; font-weight: 500; color: var(--accent); }

	.section { padding: 28px 32px; border-bottom: 1px solid var(--border); }
	.section-header { display: flex; align-items: center; gap: 12px; margin-bottom: 16px; }
	.section-icon {
	  width: 4px; height: 20px; background: var(--accent);
	  border-radius: 2px; flex-shrink: 0; opacity: 0.7;
	}
	.maps-icon { background: var(--accent2); }
	.section-title {
	  font-family: 'IBM Plex Sans', sans-serif; font-size: 0.8rem; font-weight: 600;
	  letter-spacing: 0.08em; color: var(--text); text-transform: uppercase;
	}
	.section-path { font-family: 'IBM Plex Mono', monospace; font-size: 0.65rem; color: var(--dim); margin-left: auto; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }

	table { width: 100%; border-collapse: collapse; font-size: 0.84rem; }
	thead tr { border-bottom: 1px solid var(--border); }
	th { font-size: 0.67rem; letter-spacing: 0.07em; color: var(--muted); text-transform: uppercase; text-align: left; padding: 8px 12px; font-weight: 500; }
	tbody tr { border-bottom: 1px solid rgba(200,193,185,0.4); transition: background 0.12s; }
	tbody tr:hover { background: rgba(61,107,153,0.04); }

	tr.subdir-header { background: rgba(61,107,153,0.05); border-top: 1px solid var(--border); border-bottom: none; }
	tr.subdir-header:hover { background: rgba(61,107,153,0.05); }
	tr.subdir-header td { padding: 7px 12px; }
	.subdir-label { font-family: 'IBM Plex Mono', monospace; font-size: 0.75rem; font-weight: 500; letter-spacing: 0.03em; color: var(--accent); }
	.subdir-missing { font-size: 0.67rem; color: var(--stale); margin-left: 10px; }

	tr.divider td { padding: 0; height: 4px; background: transparent; border: none; }

	td { padding: 9px 12px; vertical-align: middle; }
	td.name { font-family: 'IBM Plex Mono', monospace; color: var(--text); max-width: 280px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
	td.category { color: var(--muted); font-size: 0.75rem; }
	td.timestamp { font-family: 'IBM Plex Mono', monospace; color: var(--dim); white-space: nowrap; font-size: 0.8rem; }
	td.age { white-space: nowrap; display: flex; align-items: center; gap: 8px; }
	td.missing { color: var(--stale); font-size: 0.78rem; padding: 10px 20px; }
	td.empty { color: var(--muted); font-size: 0.78rem; padding: 9px 20px; font-style: italic; }

	.badge { display: inline-block; padding: 2px 9px; border-radius: 3px; font-size: 0.65rem; font-family: 'IBM Plex Sans', sans-serif; font-weight: 600; letter-spacing: 0.04em; }
	.badge.ok    { background: #e8f4ee; color: var(--ok);    border: 1px solid #b8d8c5; }
	.badge.warn  { background: #f7f0de; color: var(--warn);  border: 1px solid #dfc882; }
	.badge.aged  { background: #f7ede0; color: var(--aged);  border: 1px solid #ddb882; }
	.badge.stale { background: #f5e8e8; color: var(--stale); border: 1px solid #d8a8a8; }

	footer { padding: 14px 32px; display: flex; justify-content: space-between; align-items: center; border-top: 1px solid var(--border); background: var(--panel); }
	.footer-note { font-size: 0.67rem; color: var(--muted); }
	.refresh-indicator { font-size: 0.67rem; color: var(--dim); display: flex; align-items: center; gap: 6px; }
	.pulse { width: 7px; height: 7px; border-radius: 50%; background: var(--accent2); opacity: 0.75; animation: pulse 2.5s ease-in-out infinite; }
	@keyframes pulse { 0%, 100% { opacity: 0.75; transform: scale(1); } 50% { opacity: 0.3; transform: scale(0.7); } }

	.legend { display: flex; gap: 20px; padding: 11px 32px; background: #f0ede8; border-bottom: 1px solid var(--border); flex-wrap: wrap; align-items: center; }
	.legend-item { display: flex; align-items: center; gap: 6px; font-size: 0.67rem; color: var(--muted); }

	@media (max-width: 700px) {
	  header { flex-direction: column; }
	  .header-right { align-items: flex-start; }
	  .section { padding: 20px 16px; }
	  footer { flex-direction: column; gap: 8px; text-align: center; }
	  .section-path { display: none; }
	  td.category { display: none; }
	  .summary-item { padding: 10px 14px; }
	  .summary-value { font-size: 1.1rem; }
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
    <div class="clock-label" style="margin-top:6px">Auto-refreshes every 5 min</div>
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
    <span class="summary-value" style="font-size:0.85rem;padding-top:4px">${NOW}</span>
  </div>
</div>

<div class="legend">
  <span style="font-size:0.62rem;color:var(--muted);letter-spacing:0.12em;margin-right:4px">STATUS:</span>
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
    <span class="section-path">${DATA_DIR}/{Bz,NOAASpaceWX,ONTA,RSS,SDO,aurora,contests,cty,drap,dst,dxpeds,esats,geomag,solar-flux,solar-wind,ssn,voacap,worldwx,xray}</span>
  </div>
  <table>
    <thead>
      <tr>
        <th>Filename</th>
        <th>Category</th>
        <th>Last Modified (UTC)</th>
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
        <th>Category</th>
        <th>Last Modified (UTC)</th>
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
