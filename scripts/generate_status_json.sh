#!/bin/bash
# generate_status_json.sh  (with integrated server load section)
# Generates a static status board HTML + JSON for HamClock data products & maps.
# Run via cron every 5–15 minutes, e.g.:
#   */5 * * * * /opt/hamclock-backend/generate_status_json.sh

# ── Config ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/status_settings.conf"

DATA_DIR="/opt/hamclock-backend/htdocs/ham/HamClock"
MAPS_DIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
SDO_DIR="/opt/hamclock-backend/htdocs/ham/HamClock/SDO"
OUTPUT="/opt/hamclock-backend/htdocs/ham/HamClock/status.html"
OUTPUT_JSON="${OUTPUT%.html}.json"
LOAD_LOG="/opt/hamclock-backend/htdocs/ham/HamClock/load_history.ndjson"
LOAD_MAX_LINES=288   # 288 × 5 min = 24 h
CALLSIGN="OHB"
VERSION=$(cat /opt/hamclock-backend/git.version | cut -b -12)
TZ_LABEL="UTC"

DATA_SUBDIRS=(
    Bz NOAASpaceWX ONTA aurora contests cty drap dst
    dxpeds esats geomag solar-flux solar-wind ssn worldwx xray
)

# ── Threshold helpers (unchanged) ────────────────────────────────────────────
get_thresholds() {
    local category="$1" filename="$2"
    case "$filename" in
        rank_coeffs.txt|rank2_coeffs.txt|solar-flux-history-1945-2025.txt) echo "STATIC"; return ;;
        map-[DN]-*-Clouds.*)         echo "$THRESH_CLOUDS";       return ;;
        map-[DN]-*-Countries.*|map-[DN]-*-Terrain*|Terrain*) echo "STATIC"; return ;;
        map-[DN]-*-Wx-mB.*|map-[DN]-*-Wx-in.*) echo "$THRESH_WX_MAP"; return ;;
        solarflux-history*)          echo "$THRESH_SOLAR_HISTORY"; return ;;
    esac
    case "$category" in
        Bz|ONTA|worldwx)                       echo "$THRESH_BZ_ONTA_WX" ;;
        drap|solar-wind)                       echo "$THRESH_DRAP_WIND"  ;;
        xray)                                  echo "$THRESH_XRAY"       ;;
        aurora)                                echo "$THRESH_AURORA"     ;;
        NOAASpaceWX|dst|geomag|solar-flux|SDO) echo "$THRESH_SDO_SPACE"  ;;
        ssn)                                   echo "$THRESH_SSN"        ;;
        esats)                                 echo "$THRESH_ESATS"      ;;
        contests)                              echo "$THRESH_CONTESTS"   ;;
        cty|dxpeds)                            echo "$THRESH_CTY_DX"     ;;
        map)                                   echo "$THRESH_MAP"        ;;
        *)                                     echo "$THRESH_DEFAULT"    ;;
    esac
}

classify_age() {
    local age_sec="$1" thresholds="$2"
    [ "$thresholds" = "STATIC" ] && echo "static STATIC" && return
    read -r t_fresh t_recent t_aged <<< "$thresholds"
    if   [ "$age_sec" -lt "$t_fresh"  ]; then echo "ok FRESH"
    elif [ "$age_sec" -lt "$t_recent" ]; then echo "warn RECENT"
    elif [ "$age_sec" -lt "$t_aged"   ]; then echo "aged AGED"
    else                                      echo "stale STALE"
    fi
}

NOW=$(date -u "+%Y-%m-%d %H:%M:%S")
NOW_EPOCH=$(date -u +%s)

# ── HTML row builder (unchanged) ─────────────────────────────────────────────
emit_file_row() {
    local filepath="$1" label="$2"
    local filename; filename=$(basename "$filepath")
    [ "$filename" = "ignore" ] && return
    local mod_epoch; mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null)
    local mod_human; mod_human=$(date -u -d "@$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null \
                               || date -u -r "$mod_epoch" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    local age_sec=$(( NOW_EPOCH - mod_epoch ))
    local age_min=$(( age_sec / 60 ))
    local age_h=$(( age_sec / 3600 ))
    local thresholds; thresholds=$(get_thresholds "$label" "$filename")
    local class_text; class_text=$(classify_age "$age_sec" "$thresholds")
    local status_class status_text
    status_class=$(awk '{print $1}' <<< "$class_text")
    status_text=$(awk '{print $2}'  <<< "$class_text")
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
}

build_rows() {
    local dir="$1" label="$2"
    if [ ! -d "$dir" ]; then
        echo "    <tr><td colspan='4' class='missing'>⚠ Directory not found: ${dir}</td></tr>"
        return
    fi
    local found=0
    while IFS= read -r -d '' filepath; do
        found=1; emit_file_row "$filepath" "$label"
    done < <(find "$dir" -maxdepth 1 -type f -print0 2>/dev/null | sort -z)
    [ "$found" -eq 0 ] && echo "    <tr><td colspan='4' class='empty'>— no files in ${label}/ —</td></tr>"
}

build_data_rows() {
    local first=1
    for subdir in "${DATA_SUBDIRS[@]}"; do
        local dir="${DATA_DIR}/${subdir}"
        [ "$first" -eq 1 ] && first=0 || echo "    <tr class='divider'><td colspan='4'></td></tr>"
        echo "    <tr class='subdir-header'>"
        echo "      <td colspan='4'>"
        echo "        <span class='subdir-label'>${subdir}/</span>"
        [ ! -d "$dir" ] && echo "        <span class='subdir-missing'>directory not found</span>"
        echo "      </td>"
        echo "    </tr>"
        build_rows "$dir" "$subdir"
    done
}

# ── File counters ─────────────────────────────────────────────────────────────
count_data_files() {
    local total=0
    for subdir in "${DATA_SUBDIRS[@]}"; do
        local n; n=$(find "${DATA_DIR}/${subdir}" -maxdepth 1 -type f 2>/dev/null | wc -l)
        total=$(( total + n ))
    done
    echo "$total"
}

# ── NEW: collect one load sample and append to ndjson ────────────────────────
collect_load_sample() {
    # CPU: 1-second /proc/stat diff
    local cpu_pct=0
    if [ -r /proc/stat ]; then
        local line1 line2
        read -r line1 < /proc/stat; sleep 1; read -r line2 < /proc/stat
        local -a a=($line1) b=($line2)
        local tot1=$(( a[1]+a[2]+a[3]+a[4]+a[5]+a[6]+a[7]+a[8] ))
        local tot2=$(( b[1]+b[2]+b[3]+b[4]+b[5]+b[6]+b[7]+b[8] ))
        local dtot=$(( tot2 - tot1 ))
        local dile=$(( b[4] - a[4] ))
        [ "$dtot" -gt 0 ] && cpu_pct=$(( 100 * (dtot - dile) / dtot ))
    fi

    local load1=0 load5=0 load15=0
    [ -r /proc/loadavg ] && read -r load1 load5 load15 _ < /proc/loadavg

    local mem_total=1 mem_avail=0
    if [ -r /proc/meminfo ]; then
        mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
        mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
    fi
    local mem_used=$(( mem_total - mem_avail ))
    local mem_pct=$(( 100 * mem_used / mem_total ))
    local mem_used_mib=$(( mem_used  / 1024 ))
    local mem_total_mib=$(( mem_total / 1024 ))

    local uptime_sec=0
    [ -r /proc/uptime ] && uptime_sec=$(awk '{printf "%d", $1}' /proc/uptime)

    local disk_mib=0
    disk_mib=$(du -sm /opt/hamclock-backend/htdocs 2>/dev/null | awk '{print $1}') || disk_mib=0

    printf '{"ts":"%s","epoch":%d,"cpu_pct":%d,"load1":%s,"load5":%s,"load15":%s,"mem_used_mib":%d,"mem_total_mib":%d,"mem_pct":%d,"uptime_sec":%d,"disk_mib":%d}\n' \
        "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$NOW_EPOCH" "$cpu_pct" \
        "$load1" "$load5" "$load15" \
        "$mem_used_mib" "$mem_total_mib" "$mem_pct" \
        "$uptime_sec" "$disk_mib" \
        >> "$LOAD_LOG"

    # trim to 24 h
    local lines; lines=$(wc -l < "$LOAD_LOG" 2>/dev/null || echo 0)
    if [ "$lines" -gt "$LOAD_MAX_LINES" ]; then
        tail -n "$LOAD_MAX_LINES" "$LOAD_LOG" > "${LOAD_LOG}.tmp" \
            && mv "${LOAD_LOG}.tmp" "$LOAD_LOG"
    fi
}

# ── NEW: read ndjson and emit inline <script> data + chart HTML ──────────────
build_load_section() {
    # Bail gracefully if no data yet
    if [ ! -s "$LOAD_LOG" ]; then
        cat << 'NO_DATA'
<div class="load-section load-nodata">
  <p>No load data yet — run collect_load.sh at least once.</p>
</div>
NO_DATA
        return
    fi

    # Read last 288 lines, build JS arrays (awk does the heavy lifting)
    local js_arrays
    js_arrays=$(tail -n 288 "$LOAD_LOG" | awk '
        BEGIN { FS=","; n=0 }
        {
            # pull each field value robustly
            ts=""; cpu=0; load1=0; mem_pct=0
            for (i=1;i<=NF;i++) {
                if ($i ~ /"ts"/)      { split($i,a,":"); ts=a[2]":"a[3]; gsub(/["{]/,"",ts) }
                if ($i ~ /"cpu_pct"/) { split($i,a,":"); cpu=a[2]+0 }
                if ($i ~ /"load1"/)   { split($i,a,":"); load1=a[2]+0 }
                if ($i ~ /"mem_pct"/) { split($i,a,":"); mem_pct=a[2]+0 }
            }
            # label: HH:MM from ISO timestamp
            lbl = substr(ts, 12, 5)
            labels[n]=lbl; cpus[n]=cpu; loads[n]=load1; mems[n]=mem_pct
            n++
        }
        END {
            printf "const LBL=["
            for(i=0;i<n;i++) printf "%s\"%s\"", (i?",":""), labels[i]
            printf "];\n"
            printf "const CPU=["
            for(i=0;i<n;i++) printf "%s%d", (i?",":""), cpus[i]
            printf "];\n"
            printf "const LOAD1=["
            for(i=0;i<n;i++) printf "%s%.2f", (i?",":""), loads[i]
            printf "];\n"
            printf "const MEM=["
            for(i=0;i<n;i++) printf "%s%d", (i?",":""), mems[i]
            printf "];\n"
        }
    ')

    # Latest row for stat cards
    local last_row; last_row=$(tail -n1 "$LOAD_LOG")
    local cpu_now load1_now load5_now load15_now mem_pct_now mem_used_now mem_total_now uptime_now disk_now
    cpu_now=$(echo    "$last_row" | grep -oP '"cpu_pct":\K[0-9]+')
    load1_now=$(echo  "$last_row" | grep -oP '"load1":\K[0-9.]+')
    load5_now=$(echo  "$last_row" | grep -oP '"load5":\K[0-9.]+')
    load15_now=$(echo "$last_row" | grep -oP '"load15":\K[0-9.]+')
    mem_pct_now=$(echo    "$last_row" | grep -oP '"mem_pct":\K[0-9]+')
    mem_used_now=$(echo   "$last_row" | grep -oP '"mem_used_mib":\K[0-9]+')
    mem_total_now=$(echo  "$last_row" | grep -oP '"mem_total_mib":\K[0-9]+')
    uptime_now=$(echo "$last_row" | grep -oP '"uptime_sec":\K[0-9]+')
    disk_now=$(echo   "$last_row" | grep -oP '"disk_mib":\K[0-9]+')

    # Uptime → human
    local up_d=$(( uptime_now / 86400 ))
    local up_h=$(( (uptime_now % 86400) / 3600 ))
    local up_m=$(( (uptime_now % 3600)  / 60 ))
    local uptime_str="${up_d}d ${up_h}h ${up_m}m"
    [ "$up_d" -eq 0 ] && uptime_str="${up_h}h ${up_m}m"

    cat << LOAD_HTML
<div class="load-section">
  <div class="load-header">
    <div class="section-icon"></div>
    <span class="section-title">Server load</span>
    <span class="section-path">$(hostname) · last 24 h</span>
  </div>

  <div class="load-stats">
    <div class="load-stat">
      <span class="load-stat-label">CPU</span>
      <span class="load-stat-value">${cpu_now}%</span>
    </div>
    <div class="load-stat">
      <span class="load-stat-label">Load avg</span>
      <span class="load-stat-value">${load1_now}</span>
      <span class="load-stat-sub">${load1_now} / ${load5_now} / ${load15_now}</span>
    </div>
    <div class="load-stat">
      <span class="load-stat-label">Memory</span>
      <span class="load-stat-value">${mem_pct_now}%</span>
      <span class="load-stat-sub">${mem_used_now} / ${mem_total_now} MiB</span>
    </div>
    <div class="load-stat">
      <span class="load-stat-label">Uptime</span>
      <span class="load-stat-value">${uptime_str}</span>
    </div>
    <div class="load-stat">
      <span class="load-stat-label">Disk (htdocs)</span>
      <span class="load-stat-value">${disk_now} MiB</span>
    </div>
  </div>

  <div class="load-charts">
    <div class="load-chart-wrap">
      <div class="load-chart-label">CPU %</div>
      <div style="position:relative;height:90px;"><canvas id="lc-cpu" role="img" aria-label="CPU usage last 24h">CPU history.</canvas></div>
    </div>
    <div class="load-chart-wrap">
      <div class="load-chart-label">Load (1 min)</div>
      <div style="position:relative;height:90px;"><canvas id="lc-load" role="img" aria-label="Load average last 24h">Load history.</canvas></div>
    </div>
    <div class="load-chart-wrap">
      <div class="load-chart-label">Memory %</div>
      <div style="position:relative;height:90px;"><canvas id="lc-mem" role="img" aria-label="Memory usage last 24h">Memory history.</canvas></div>
    </div>
  </div>
</div>

<script src="https://cdnjs.cloudflare.com/ajax/libs/Chart.js/4.4.1/chart.umd.js"></script>
<script>
(function(){
${js_arrays}
const GRID='rgba(0,0,0,0.06)', TICK='#9a9590';
function spark(id, data, color, yMax) {
  new Chart(document.getElementById(id), {
    type:'line',
    data:{ labels:LBL, datasets:[{ data:data, borderColor:color,
           backgroundColor:color+'22', borderWidth:1.5,
           pointRadius:0, fill:true, tension:0.3 }] },
    options:{ responsive:true, maintainAspectRatio:false,
      plugins:{ legend:{display:false}, tooltip:{
        callbacks:{ label: ctx => ' '+ctx.parsed.y.toFixed(1) }
      }},
      scales:{
        x:{ ticks:{ color:TICK, font:{size:9,family:'IBM Plex Mono'},
                    maxTicksLimit:6, maxRotation:0 }, grid:{color:GRID} },
        y:{ min:0, max:yMax||undefined,
            ticks:{ color:TICK, font:{size:9,family:'IBM Plex Mono'},
                    maxTicksLimit:4, callback:v=>v.toFixed(0) },
            grid:{color:GRID} }
      }
    }
  });
}
spark('lc-cpu',  CPU,   '#3d6b99', 100);
spark('lc-load', LOAD1, '#b87a10');
spark('lc-mem',  MEM,   '#3a7a56', 100);
})();
</script>
LOAD_HTML
}

# ── JSON builder (unchanged) ─────────────────────────────────────────────────
build_json_entries() {
    local dir="$1" label="$2"
    local -n _first_entry="$3"
    [ ! -d "$dir" ] && return
    while IFS= read -r -d '' filepath; do
        local filename; filename=$(basename "$filepath")
        [ "$filename" = "ignore" ] && continue
        local mod_epoch; mod_epoch=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null)
        local mod_human; mod_human=$(date -u -d "@$mod_epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                                  || date -u -r "$mod_epoch"  "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
        local age_sec=$(( NOW_EPOCH - mod_epoch ))
        local thresholds; thresholds=$(get_thresholds "$label" "$filename")
        local class_text; class_text=$(classify_age "$age_sec" "$thresholds")
        local status_text; status_text=$(awk '{print $2}' <<< "$class_text")
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

build_json() {
    local first_entry=1
    {
        printf '{\n'
        printf '  "generated_utc": "%s",\n'      "$NOW"
        printf '  "callsign": "%s",\n'           "$CALLSIGN"
        printf '  "version": "%s",\n'            "$VERSION"
        printf '  "summary": {\n'
        printf '    "data_product_files": %d,\n' "$DATA_COUNT"
        printf '    "sdo_files": %d,\n'          "$SDO_COUNT"
        printf '    "map_files": %d,\n'          "$MAPS_COUNT"
        printf '    "total_files": %d\n'         "$(( DATA_COUNT + SDO_COUNT + MAPS_COUNT ))"
        printf '  },\n'
        printf '  "files": [\n'
        for subdir in "${DATA_SUBDIRS[@]}"; do
            build_json_entries "${DATA_DIR}/${subdir}" "$subdir" first_entry
        done
        build_json_entries "$SDO_DIR"  "SDO" first_entry
        build_json_entries "$MAPS_DIR" "map" first_entry
        printf '\n  ]\n'
        printf '}\n'
    } > "$OUTPUT_JSON"
}

# ── Counts ────────────────────────────────────────────────────────────────────
DATA_COUNT=$(count_data_files)
SDO_COUNT=$(find "$SDO_DIR"  -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
MAPS_COUNT=$(find "$MAPS_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')

# ── Collect load sample (adds ~1 s for CPU measurement) ──────────────────────
collect_load_sample

# ── Write HTML ────────────────────────────────────────────────────────────────
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
      --accent3:  #7a5a99;
      --dim:      #9a9590;
      --text:     #2e2b27;
      --muted:    #7a756e;
      --ok:       #2e7a50;
      --warn:     #8a6200;
      --aged:     #8a4e00;
      --stale:    #9e2020;
      --static:   #3d6b99;
    }
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg); color: var(--text);
      font-family: 'IBM Plex Sans', sans-serif; font-size: 14px; line-height: 1.6;
    }
    header {
      border-bottom: 1px solid var(--border); padding: 20px 24px 16px;
      display: flex; align-items: flex-start; justify-content: space-between;
      gap: 12px; background: var(--panel); flex-wrap: wrap;
    }
    .header-left { display: flex; flex-direction: column; gap: 4px; min-width: 0; }
    .callsign {
      font-family: 'IBM Plex Sans', sans-serif; font-weight: 600;
      font-size: clamp(1.3rem, 5vw, 2.2rem); letter-spacing: 0.04em;
      color: var(--accent); line-height: 1.1;
    }
    .subtitle { font-size: 0.7rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; }
    .header-right {
      text-align: right; display: flex; flex-direction: column;
      gap: 3px; align-items: flex-end; flex-shrink: 0;
    }
    .clock-label { font-size: 0.65rem; letter-spacing: 0.05em; color: var(--muted); text-transform: uppercase; }
    .clock { font-family: 'IBM Plex Mono', monospace; font-size: clamp(0.78rem, 2.5vw, 1.0rem); color: var(--accent2); font-weight: 500; }

    .summary {
      display: grid; grid-template-columns: repeat(2, 1fr);
      border-bottom: 1px solid var(--border); background: var(--panel);
    }
    .summary-item {
      padding: 12px 20px; border-right: 1px solid var(--border); border-bottom: 1px solid var(--border);
      display: flex; flex-direction: column; gap: 2px;
    }
    .summary-item:nth-child(2n)        { border-right: none; }
    .summary-item:nth-last-child(-n+2) { border-bottom: none; }
    .summary-label { font-size: 0.62rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; }
    .summary-value { font-family: 'IBM Plex Mono', monospace; font-size: 1.25rem; font-weight: 500; color: var(--accent); }

    /* ── Load section ── */
    .load-section {
      border-bottom: 1px solid var(--border);
      background: var(--panel);
      padding: 16px 24px 20px;
    }
    .load-nodata { color: var(--muted); font-size: 0.8rem; padding: 14px 24px; }
    .load-header {
      display: flex; align-items: center; gap: 10px; margin-bottom: 14px;
    }
    .load-stats {
      display: grid; grid-template-columns: repeat(5, 1fr);
      gap: 0; border: 1px solid var(--border); border-radius: 4px;
      overflow: hidden; margin-bottom: 14px;
    }
    .load-stat {
      padding: 10px 14px; border-right: 1px solid var(--border);
      display: flex; flex-direction: column; gap: 2px;
    }
    .load-stat:last-child { border-right: none; }
    .load-stat-label { font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.06em; color: var(--muted); }
    .load-stat-value { font-family: 'IBM Plex Mono', monospace; font-size: 1.1rem; font-weight: 500; color: var(--accent); }
    .load-stat-sub   { font-size: 0.6rem; color: var(--dim); margin-top: 1px; font-family: 'IBM Plex Mono', monospace; }
    .load-charts {
      display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px;
    }
    .load-chart-wrap {
      border: 1px solid var(--border); border-radius: 4px; padding: 10px 12px;
    }
    .load-chart-label {
      font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.06em;
      color: var(--muted); margin-bottom: 6px;
    }

    /* ── Legend ── */
    .legend {
      display: flex; gap: 12px; padding: 10px 24px;
      background: #f0ede8; border-bottom: 1px solid var(--border);
      flex-wrap: wrap; align-items: center;
    }
    .legend-item { display: flex; align-items: center; gap: 5px; font-size: 0.65rem; color: var(--muted); }

    /* ── Sections ── */
    .section { padding: 20px 24px; border-bottom: 1px solid var(--border); }
    .section-header { display: flex; align-items: center; gap: 10px; margin-bottom: 14px; }
    .section-icon { width: 4px; height: 18px; background: var(--accent); border-radius: 2px; flex-shrink: 0; opacity: 0.7; }
    .maps-icon  { background: var(--accent2); }
    .sdo-icon   { background: var(--accent3); }
    .section-title { font-size: 0.78rem; font-weight: 600; letter-spacing: 0.07em; color: var(--text); text-transform: uppercase; }
    .section-path { font-family: 'IBM Plex Mono', monospace; font-size: 0.62rem; color: var(--dim); margin-left: auto; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; max-width: 40vw; }

    table { width: 100%; border-collapse: collapse; font-size: 0.83rem; }
    thead tr { border-bottom: 1px solid var(--border); }
    th { font-size: 0.64rem; letter-spacing: 0.06em; color: var(--muted); text-transform: uppercase; text-align: left; padding: 7px 10px; font-weight: 500; }
    tbody tr { border-bottom: 1px solid rgba(200,193,185,0.4); transition: background 0.12s; }
    tbody tr:hover { background: rgba(61,107,153,0.04); }
    tr.subdir-header { background: rgba(61,107,153,0.05); border-top: 1px solid var(--border); border-bottom: none; }
    tr.subdir-header:hover { background: rgba(61,107,153,0.05); }
    tr.subdir-header td { padding: 6px 10px; }
    .subdir-label { font-family: 'IBM Plex Mono', monospace; font-size: 0.73rem; font-weight: 500; color: var(--accent); }
    .subdir-missing { font-size: 0.65rem; color: var(--stale); margin-left: 8px; }
    tr.divider td { padding: 0; height: 4px; background: transparent; border: none; }
    td { padding: 8px 10px; vertical-align: middle; }
    td.name { font-family: 'IBM Plex Mono', monospace; color: var(--text); word-break: break-all; }
    td.category { color: var(--muted); font-size: 0.73rem; white-space: nowrap; }
    td.timestamp { font-family: 'IBM Plex Mono', monospace; color: var(--dim); white-space: nowrap; font-size: 0.78rem; }
    td.age { white-space: nowrap; }
    .age-str { color: var(--dim); font-size: 0.78rem; }
    td.missing { color: var(--stale); font-size: 0.76rem; padding: 10px; }
    td.empty   { color: var(--muted); font-size: 0.76rem; padding: 8px 10px; font-style: italic; }

    .badge { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 0.63rem; font-weight: 600; letter-spacing: 0.03em; vertical-align: middle; }
    .badge.ok     { background: #e8f4ee; color: var(--ok);     border: 1px solid #b8d8c5; }
    .badge.warn   { background: #f7f0de; color: var(--warn);   border: 1px solid #dfc882; }
    .badge.aged   { background: #f7ede0; color: var(--aged);   border: 1px solid #ddb882; }
    .badge.stale  { background: #f5e8e8; color: var(--stale);  border: 1px solid #d8a8a8; }
    .badge.static { background: #eeeeee; color: #7a7a7a;       border: 1px solid #d1d1d1; }

    footer { padding: 12px 24px; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 8px; border-top: 1px solid var(--border); background: var(--panel); }
    .footer-note { font-size: 0.65rem; color: var(--muted); }
    .refresh-indicator { font-size: 0.65rem; color: var(--dim); display: flex; align-items: center; gap: 5px; }
    .pulse { width: 7px; height: 7px; border-radius: 50%; background: var(--accent2); opacity: 0.75; animation: pulse 2.5s ease-in-out infinite; }
    @keyframes pulse { 0%,100%{opacity:.75;transform:scale(1)} 50%{opacity:.3;transform:scale(.7)} }

    @media (max-width: 600px) {
      header, .section, .load-section { padding: 14px 16px; }
      .legend { padding: 9px 16px; }
      .load-stats  { grid-template-columns: repeat(2, 1fr); }
      .load-stat:nth-child(2) { border-right: none; }
      .load-charts { grid-template-columns: 1fr; }
      .section-path { display: none; }
      th.col-category, td.category, th.col-timestamp, td.timestamp { display: none; }
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
    <span class="summary-label">SDO Files</span>
    <span class="summary-value">${SDO_COUNT}</span>
  </div>
  <div class="summary-item">
    <span class="summary-label">Map Files</span>
    <span class="summary-value">${MAPS_COUNT}</span>
  </div>
  <div class="summary-item">
    <span class="summary-label">Last Board Update</span>
    <span class="summary-value" style="font-size:0.82rem;padding-top:3px">${NOW}</span>
  </div>
</div>

HTML_HEAD

# ── Inject load section here (between summary and legend) ────────────────────
build_load_section

cat << HTML_LEGEND
<div class="legend">
  <span style="font-size:0.63rem;color:var(--muted);margin-right:2px">STATUS:</span>
  <div class="legend-item"><span class="badge ok">FRESH</span> within normal update window</div>
  <div class="legend-item"><span class="badge warn">RECENT</span> slightly overdue</div>
  <div class="legend-item"><span class="badge aged">AGED</span> significantly overdue</div>
  <div class="legend-item"><span class="badge stale">STALE</span> may need attention</div>
  <div class="legend-item"><span class="badge static">STATIC</span> intentionally fixed</div>
</div>

<div class="section">
  <div class="section-header">
    <div class="section-icon"></div>
    <span class="section-title">Data Products</span>
    <span class="section-path">${DATA_DIR}/{Bz,NOAASpaceWX,ONTA,...}</span>
  </div>
  <table>
    <thead><tr><th>Filename</th><th class="col-category">Category</th><th class="col-timestamp">Last Modified (UTC)</th><th>Status</th></tr></thead>
    <tbody>
HTML_LEGEND

build_data_rows

cat << HTML_SDO
    </tbody>
  </table>
</div>

<div class="section">
  <div class="section-header">
    <div class="section-icon sdo-icon"></div>
    <span class="section-title">SDO</span>
    <span class="section-path">${SDO_DIR}</span>
  </div>
  <table>
    <thead><tr><th>Filename</th><th class="col-category">Category</th><th class="col-timestamp">Last Modified (UTC)</th><th>Status</th></tr></thead>
    <tbody>
HTML_SDO

build_rows "$SDO_DIR" "SDO"

cat << HTML_MAPS
    </tbody>
  </table>
</div>

<div class="section">
  <div class="section-header">
    <div class="section-icon maps-icon"></div>
    <span class="section-title">Maps</span>
    <span class="section-path">${MAPS_DIR}</span>
  </div>
  <table>
    <thead><tr><th>Filename</th><th class="col-category">Category</th><th class="col-timestamp">Last Modified (UTC)</th><th>Status</th></tr></thead>
    <tbody>
HTML_MAPS

build_rows "$MAPS_DIR" "map"

cat << HTML_FOOT
    </tbody>
  </table>
</div>

<footer>
  <div class="footer-note">73 · ${CALLSIGN} · Generated by generate_status_json.sh / ${VERSION}</div>
  <div class="refresh-indicator"><div class="pulse"></div>Auto-refresh active · every 5 minutes</div>
</footer>

</body>
</html>
HTML_FOOT

} > "$OUTPUT"

echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] Status board written to ${OUTPUT}"
build_json
echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] JSON status written  to ${OUTPUT_JSON}"
