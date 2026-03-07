#!/usr/bin/env python3
"""
gen_dxpeditions.py  –  Fetch, merge and write HamClock dxpeditions.txt

Sources:
  NG3K ADXO  – authoritative for dates, callsigns, entity names, and some URLs
  DXNews.com – contributes expedition-specific URLs matched by callsign
"""

import re
import sys
import time
import hashlib
import logging
import argparse
from datetime import datetime, timezone
from pathlib import Path
from dataclasses import dataclass
from typing import Optional

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
from lxml import html as lxml_html

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

OUT_FILE  = Path('/opt/hamclock-backend/htdocs/ham/HamClock/dxpeds/dxpeditions.txt')
LOCK_FILE = Path('/opt/hamclock-backend/tmp/gen_dxpeditions.lock')

NG3K_URL   = 'https://www.ng3k.com/Misc/adxo.html'
DXNEWS_IDX = 'https://dxnews.com/dxpeditions/'

PAST_DAYS   = 1    # keep if ended up to N days ago
FUTURE_DAYS = 180  # keep if starts within N days from now

# Max duration (days) for entries with no specific URL — filters resident stations
MAX_GENERIC_DURATION = 60

REQUEST_TIMEOUT = 20   # seconds per HTTP request
DXNEWS_DELAY    = 0.5  # seconds between DXNews page fetches

HEADERS = {
    'User-Agent': (
        'OHB-DXPeds/2.0 '
        '(+https://github.com/komacke/open-hamclock-backend)'
    )
}

# DXNews site-navigation slugs that are never expedition pages
DXNEWS_SKIP_SLUGS = {
    'dxpeditions', 'category', 'tag', 'author', 'page', 'contact', 'about',
    'announcements', 'articles', 'calendar', 'contesting', 'dxnews', 'forum',
    'funded', 'iota', 'popular', 'ru', 'sendarticle', 'sitemap',
    'support-dxnews', 'supporters', 'dxinformation', 'search',
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
    datefmt='%H:%M:%S',
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# HTTP session with retries
# ---------------------------------------------------------------------------

def make_session() -> requests.Session:
    session = requests.Session()
    retry = Retry(
        total=3,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=['GET'],
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount('http://', adapter)
    session.mount('https://', adapter)
    session.headers.update(HEADERS)
    return session

# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

@dataclass
class Expedition:
    start: int   # Unix timestamp, 00:00:00 UTC
    end:   int   # Unix timestamp, 23:59:59 UTC
    loc:   str
    call:  str
    url:   str

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

MONTH_ABBR = {
    'jan': 0, 'feb': 1, 'mar': 2, 'apr': 3, 'may': 4,  'jun': 5,
    'jul': 6, 'aug': 7, 'sep': 8, 'oct': 9, 'nov': 10, 'dec': 11,
}

def to_epoch_start(y: int, m: int, d: int) -> int:
    return int(datetime(y, m + 1, d,  0,  0,  0, tzinfo=timezone.utc).timestamp())

def to_epoch_end(y: int, m: int, d: int) -> int:
    return int(datetime(y, m + 1, d, 23, 59, 59, tzinfo=timezone.utc).timestamp())

def in_window(start: int, end: int, now: int) -> bool:
    return (end   >= now - PAST_DAYS   * 86400 and
            start <= now + FUTURE_DAYS * 86400)

def _url_quality(url: str) -> int:
    """Higher = better. Expedition-specific > DXNews article > NG3K generic."""
    if re.search(r'ng3k\.com/Misc/adxo', url, re.I):
        return 0
    if re.search(r'dxnews\.com/', url, re.I):
        return 1
    return 2

def _extract_call(text: str) -> Optional[str]:
    """
    Extract the best callsign-like token from text.
    Handles real calls (DU6, KH2, HC1MD/2, 6Y, 3B8G) and
    pure-alpha entity prefixes (FG, FM, ZC4).
    """
    call_m = (
        re.search(r'\b([A-Z]{0,3}[0-9][A-Z0-9]*(?:/[A-Z0-9P]+)?)\b', text) or
        re.search(r'\b([A-Z]{2,4})\b', text)
    )
    if not call_m or len(call_m.group(1)) < 2:
        return None
    return call_m.group(1)

# ---------------------------------------------------------------------------
# NG3K scraper  (authoritative source)
# ---------------------------------------------------------------------------

def parse_ng3k_date(s: str) -> Optional[tuple[int, int, int]]:
    """Parse '2026 Feb21' → (2026, 1, 21)  [month 0-based]"""
    s = re.sub(r'NEW\s*\([^)]*\)', '', s, flags=re.I).strip()
    m = re.match(r'^(\d{4})\s+([A-Za-z]{3})(\d{1,2})$', s)
    if not m:
        return None
    yr  = int(m.group(1))
    mon = m.group(2).lower()[:3]
    day = int(m.group(3))
    return (yr, MONTH_ABBR[mon], day) if mon in MONTH_ABBR else None

def scrape_ng3k(session: requests.Session, now: int) -> list[Expedition]:
    log.info('Fetching NG3K: %s', NG3K_URL)
    try:
        resp = session.get(NG3K_URL, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error('NG3K fetch failed: %s', exc)
        return []

    tree    = lxml_html.fromstring(resp.content)
    records: list[Expedition] = []
    skipped = 0

    for tr in tree.xpath('//tr'):
        tds = tr.xpath('td')
        if len(tds) < 7:
            continue

        def cell_text(td):
            raw = td.text_content()
            raw = re.sub(r'NEW\s*\([^)]*\)', '', raw, flags=re.I)
            raw = re.sub(r'\[\[.*?\]\]', '', raw)
            return re.sub(r'\s+', ' ', raw).strip()

        # ---- Dates ----
        sd = parse_ng3k_date(cell_text(tds[0]))
        ed = parse_ng3k_date(cell_text(tds[1]))
        if not sd or not ed:
            skipped += 1
            continue

        start_ts = to_epoch_start(*sd)
        end_ts   = to_epoch_end(*ed)

        if not in_window(start_ts, end_ts, now):
            continue

        # ---- Location ----
        loc = cell_text(tds[2]).replace('&amp;', '&').replace(' & ', ' and ').strip()
        if not loc:
            skipped += 1
            continue

        # ---- Callsign + URL ----
        call_td  = tds[3]
        call_url = NG3K_URL

        for a in call_td.xpath('.//a'):
            href = (a.get('href') or '').strip()
            if href and not re.search(r'dxwatch|dxsd1|ng3k\.com', href, re.I):
                if href.startswith('/'):
                    href = 'https://www.ng3k.com' + href
                call_url = href
                break

        call_text    = cell_text(call_td)
        real_call_m  = re.search(r'\b([A-Z]{0,3}[0-9][A-Z0-9]*(?:/[A-Z0-9P]+)?)\b', call_text)
        alpha_call_m = re.search(r'\b([A-Z]{2,4})\b', call_text)
        call_m       = real_call_m or alpha_call_m

        if not call_m or len(call_m.group(1)) < 2:
            skipped += 1
            continue
        call = call_m.group(1)

        is_bare_alpha  = bool(alpha_call_m and not real_call_m)
        is_generic_url = (call_url == NG3K_URL)
        duration_days  = (end_ts - start_ts) / 86400

        # Pure-alpha entity codes (FG, FM, FS, etc.) with no specific URL are
        # collected but we only keep the shortest-duration entry per call (the
        # dedicated expedition vs long-running holiday op). Collect all here;
        # filtering happens after the loop.

        # Long-duration real-call entries with no specific URL are resident/club
        # stations (e.g. JD1 Minami Torishima resident), not expeditions — drop.
        if not is_bare_alpha and is_generic_url and duration_days > MAX_GENERIC_DURATION:
            log.debug('NG3K skip %s — %.0fd, no specific URL', call, duration_days)
            continue

        records.append(Expedition(
            start=start_ts, end=end_ts, loc=loc, call=call, url=call_url,
        ))

    # For bare-alpha calls with no specific URL, keep only the shortest-duration
    # entry (the dedicated expedition), drop long holiday-op / "entity active" entries.
    alpha_generic = {
        r.call for r in records
        if r.url == NG3K_URL
        and not re.search(r'[0-9]', r.call)  # is bare-alpha
    }
    for call in alpha_generic:
        same = [r for r in records if r.call == call and r.url == NG3K_URL]
        if len(same) > 1:
            # Keep the shortest duration only
            shortest = min(same, key=lambda r: r.end - r.start)
            for r in same:
                if r is not shortest:
                    log.debug('NG3K drop long bare-alpha %s (%.0fd)', call,
                              (r.end - r.start) / 86400)
                    records.remove(r)

    log.info('NG3K: %d records parsed, %d skipped', len(records), skipped)
    return records

# ---------------------------------------------------------------------------
# DXNews URL lookup  (contributes better URLs matched by callsign)
# ---------------------------------------------------------------------------

def fetch_dxnews_url_map(session: requests.Session) -> dict[str, str]:
    """
    Scrape DXNews expedition pages and return {CALLSIGN: url}.
    DXNews dates are unreliable (prose-format, sometimes absent) so we only
    use DXNews to find better expedition-specific URLs, not for dates.
    """
    log.info('Fetching DXNews index: %s', DXNEWS_IDX)
    try:
        resp = session.get(DXNEWS_IDX, timeout=REQUEST_TIMEOUT)
        resp.raise_for_status()
    except requests.RequestException as exc:
        log.error('DXNews index fetch failed: %s', exc)
        return {}

    urls = sorted(set(re.findall(
        r'https://dxnews\.com/[a-z0-9_\-]+/', resp.text, re.I,
    )))
    urls = [u for u in urls
            if u.rstrip('/').split('/')[-1] not in DXNEWS_SKIP_SLUGS]

    log.info('DXNews: %d candidate URLs', len(urls))
    url_map: dict[str, str] = {}
    skipped = 0

    for url in urls:
        time.sleep(DXNEWS_DELAY)
        try:
            r = session.get(url, timeout=REQUEST_TIMEOUT)
            if not r.ok:
                skipped += 1
                continue
        except requests.RequestException:
            skipped += 1
            continue

        tree = lxml_html.fromstring(r.content)
        h1s  = tree.xpath('//h1')
        if not h1s:
            skipped += 1
            continue

        h1_text = re.sub(r'\s+', ' ', h1s[0].text_content()).strip()
        call    = _extract_call(h1_text)

        if not call or call in ('RSGB', 'ARRL', 'IOTA', 'DX', 'HOME'):
            log.debug('DXNews skip %s — bad call from H1: %r', url, h1_text)
            skipped += 1
            continue

        url_map[call.upper()] = url
        log.debug('DXNews mapped %s → %s', call, url)

    log.info('DXNews: mapped %d calls, skipped %d pages', len(url_map), skipped)
    return url_map

# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------

def merge(ng3k: list[Expedition], dxnews_urls: dict[str, str]) -> list[Expedition]:
    """
    Merge NG3K records with DXNews URL map.
    - NG3K is authoritative for all fields.
    - DXNews upgrades URLs when a better match exists for the callsign.
    - Near-duplicates (same call, timestamps within 24h) are collapsed.
    """
    # Apply DXNews URL upgrades
    for exp in ng3k:
        dx_url = dxnews_urls.get(exp.call.upper())
        if dx_url and _url_quality(dx_url) > _url_quality(exp.url):
            exp.url = dx_url

    def best_url(a: str, b: str) -> str:
        return b if _url_quality(b) > _url_quality(a) else a

    merged: dict[tuple, Expedition] = {}

    for exp in ng3k:
        key = (exp.call, exp.start, exp.end)

        # Collapse near-duplicates: same call, timestamps within 24h
        collapsed = False
        for existing in merged.values():
            if existing.call == exp.call:
                if (abs(existing.start - exp.start) <= 86400 and
                        abs(existing.end   - exp.end)   <= 86400):
                    existing.url = best_url(existing.url, exp.url)
                    collapsed = True
                    break
        if collapsed:
            continue

        if key not in merged:
            merged[key] = exp
        else:
            merged[key].url = best_url(merged[key].url, exp.url)

    result = sorted(merged.values(), key=lambda e: (e.start, e.call))
    log.info('Merged: %d unique expeditions', len(result))
    return result

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

HEADER = """\
2
DXNews
https://dxnews.com
NG3K
https://www.ng3k.com/Misc/adxo.html
"""

def build_output(records: list[Expedition]) -> str:
    lines = [HEADER.rstrip('\n')]
    for r in records:
        lines.append(f'{r.start},{r.end},{r.loc},{r.call},{r.url}')
    return '\n'.join(lines) + '\n'

def write_if_changed(content: str, path: Path) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    new_hash = hashlib.sha256(content.encode()).hexdigest()
    if path.exists():
        if hashlib.sha256(path.read_text().encode()).hexdigest() == new_hash:
            log.info('Output unchanged, skipping write.')
            return False
    tmp = path.with_suffix('.tmp')
    tmp.write_text(content)
    tmp.replace(path)
    log.info('Wrote %d bytes to %s', len(content), path)
    return True

# ---------------------------------------------------------------------------
# Lock file
# ---------------------------------------------------------------------------

def acquire_lock() -> bool:
    if LOCK_FILE.exists():
        age = time.time() - LOCK_FILE.stat().st_mtime
        if age < 3600:
            log.warning('Lock file exists (age %.0fs), exiting.', age)
            return False
        log.warning('Stale lock file (age %.0fs), removing.', age)
    LOCK_FILE.write_text(str(time.time()))
    return True

def release_lock():
    LOCK_FILE.unlink(missing_ok=True)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description='Generate HamClock dxpeditions.txt')
    parser.add_argument('--ng3k-only',   action='store_true', help='Skip DXNews (faster)')
    parser.add_argument('--dxnews-only', action='store_true', help='Skip NG3K')
    parser.add_argument('--out',  type=Path, default=OUT_FILE, help='Output path')
    parser.add_argument('--dry-run', action='store_true', help='Print, do not write')
    parser.add_argument('--debug',   action='store_true')
    args = parser.parse_args()

    if args.debug:
        logging.getLogger().setLevel(logging.DEBUG)

    if not acquire_lock():
        sys.exit(1)

    try:
        now     = int(time.time())
        session = make_session()

        ng3k_records = scrape_ng3k(session, now)     if not args.dxnews_only else []
        dxnews_urls  = fetch_dxnews_url_map(session) if not args.ng3k_only   else {}

        records = merge(ng3k_records, dxnews_urls)

        if not records:
            log.error('No records — aborting to preserve existing file.')
            sys.exit(1)

        content = build_output(records)

        if args.dry_run:
            print(content)
        else:
            write_if_changed(content, args.out)

    finally:
        release_lock()

if __name__ == '__main__':
    main()
