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
#  gen-contest-calendar.sh
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

URL="https://contestcalendar.com/weeklycontcustom.php"
OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/contests"

mkdir -p "$OUTDIR"

OUT311="$OUTDIR/contests311.txt"   # epoch format (existing)
OUT3="$OUTDIR/contests3.txt"       # human-readable dates
OUT="$OUTDIR/contests.txt"         # names only

# Headers
echo "WA7BNM Weekend Contests" > "$OUT311"
echo "WA7BNM Weekend Contests" > "$OUT3"
echo "WA7BNM Weekend Contests" > "$OUT"

curl -s "$URL" | tr -d '\r' | awk '
  /^BEGIN:VEVENT/ {printf "EVENT|"}
  /^DTSTART:/ {split($0, a, ":"); printf "%s|", a[2]}
  /^DTEND:/   {split($0, a, ":"); printf "%s|", a[2]}
  /^SUMMARY:/ {printf "%s|", substr($0, 9)}
  /^URL:/     {printf "%s\n", substr($0, 5)}
' | while IFS="|" read -r marker start_raw end_raw title url; do

    [[ -z "$start_raw" ]] && continue

    title=$(echo "$title" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    Y=${start_raw:0:4};  M=${start_raw:4:2};  D=${start_raw:6:2}
    H=${start_raw:9:2};  Min=${start_raw:11:2}; S=${start_raw:13:2}

    Y2=${end_raw:0:4};   M2=${end_raw:4:2};   D2=${end_raw:6:2}
    H2=${end_raw:9:2};   Min2=${end_raw:11:2}; S2=${end_raw:13:2}

    start_epoch=$(date -u -d "$Y-$M-$D $H:$Min:$S" +%s 2>/dev/null)
    end_epoch=$(date -u -d "$Y2-$M2-$D2 $H2:$Min2:$S2" +%s 2>/dev/null)
    dow=$(date -u -d "$Y-$M-$D $H:$Min:$S" +%w 2>/dev/null)

    if [[ "$dow" == "0" || "$dow" == "6" ]]; then

        # contests311.txt — epoch format (unchanged)
        printf "%s %s %s\n" "$start_epoch" "$end_epoch" "$title" >> "$OUT311"
        printf "%s\n" "$url" >> "$OUT311"

        # Format start
        start_hm=$(date -u -d "@$start_epoch" +"%H%M")
        start_day=$(date -u -d "@$start_epoch" +"%Y%m%d")
        start_fmt=$(date -u -d "@$start_epoch" +"%H%M %b %-d")

        # Format end — treat 2359 as 2400
        end_hm=$(date -u -d "@$end_epoch" +"%H%M")
        end_day=$(date -u -d "@$end_epoch" +"%Y%m%d")
        end_day_fmt=$(date -u -d "@$end_epoch" +"%b %-d")
        [[ "$end_hm" == "2359" ]] && end_hm="2400"
        end_fmt="$end_hm $end_day_fmt"

        # contests3.txt
        if [[ "$start_day" == "$end_day" ]]; then
            day_fmt=$(date -u -d "@$start_epoch" +"%b %-d")
            printf "%s\n%s-%s %s\n" "$title" "$start_hm" "$end_hm" "$day_fmt" >> "$OUT3"
        else
            printf "%s\n%s - %s\n" "$title" "$start_fmt" "$end_fmt" >> "$OUT3"
        fi

        # contests.txt — title only
        printf "%s\n" "$title" >> "$OUT"
    fi
done
