#!/usr/bin/perl
# fetchPSKReporter.pl — HamClock backend PSKReporter proxy
#
# Queries a local SQLite database maintained by psk_reporter_cache.py
# (runs every 15 minutes via cron).  No outbound HTTP requests are made here.
#
# Install deps on Debian/Ubuntu/Raspberry Pi OS:
#   sudo apt-get install libdbi-perl libdbd-sqlite3-perl
#
# CGI parameters:
#   bygrid   — filter by sender grid prefix   (e.g. EL97 or EL97ab)
#   ofgrid   — filter by receiver grid prefix (e.g. EL97 or EL97ab)
#   maxage   — return spots newer than this many seconds (default 900, max 86400)
#
# Output format (one spot per line):
#   flowStartSeconds,senderLocator,senderCallsign,receiverLocator,receiverCallsign,mode,frequency,sNR

use strict;
use warnings;
use CGI;
use DBI;

# ── Configuration ─────────────────────────────────────────────────────────────

my $DB_FILE      = "/opt/hamclock-backend/tmp/psk-cache/spots.db";
my $MAX_CACHE_AGE = 1800;   # warn if DB mtime is older than 30 min

# ── CGI Setup ─────────────────────────────────────────────────────────────────

my $q = CGI->new;

my $bygrid = uc($q->param('bygrid') // '');
my $ofgrid = uc($q->param('ofgrid') // '');

my $maxage = $q->param('maxage');
$maxage = 900 if (!defined $maxage || $maxage eq '');
$maxage =~ s/\D//g;
$maxage = int($maxage || 900);
$maxage = 60    if $maxage < 60;
$maxage = 86400 if $maxage > 86400;

print $q->header(-type => 'text/plain; charset=ISO-8859-1');

if (!$bygrid && !$ofgrid) {
    print "Error: bygrid and/or ofgrid parameter is required.\n";
    exit;
}

sub valid_grid {
    my ($g) = @_;
    return 0 if !defined $g || $g eq '';
    return ($g =~ /^[A-R]{2}[0-9]{2}([A-X]{2})?$/) ? 1 : 0;
}

if ($bygrid && !valid_grid($bygrid)) {
    print "Error: invalid bygrid locator.\n";
    exit;
}
if ($ofgrid && !valid_grid($ofgrid)) {
    print "Error: invalid ofgrid locator.\n";
    exit;
}

# ── DB Sanity Check ───────────────────────────────────────────────────────────

unless (-f $DB_FILE) {
    print STDERR "PSK db not found: $DB_FILE\n";
    print "Error: spot cache unavailable — please try again shortly.\n";
    exit;
}

my $db_age = time() - (stat($DB_FILE))[9];
if ($db_age > $MAX_CACHE_AGE) {
    print STDERR sprintf("PSK db is stale (%d s old)\n", $db_age);
    # Still serve stale data rather than returning nothing
}

# ── Build Query ───────────────────────────────────────────────────────────────

my $cutoff = time() - $maxage;

# Use SQLite's LIKE with a prefix pattern for grid matching.
# Indexed on r_grid and s_grid so these are fast even at 288k rows.
#
# bygrid matches sender grid (s_grid)
# ofgrid matches receiver grid (r_grid)
#
# Both can be specified simultaneously (AND logic).

my $sql = "SELECT t, s_grid, s_call, r_grid, r_call, mode, freq, snr
           FROM spots
           WHERE t >= ?";

my @bind = ($cutoff);

if ($bygrid) {
    $sql .= " AND s_grid LIKE ?";
    push @bind, $bygrid . '%';
}

if ($ofgrid) {
    $sql .= " AND r_grid LIKE ?";
    push @bind, $ofgrid . '%';
}

$sql .= " ORDER BY t DESC";

# ── Execute ───────────────────────────────────────────────────────────────────

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$DB_FILE",
    '', '',
    {
        RaiseError       => 1,
        PrintError       => 0,
        sqlite_open_flags => 1,   # SQLITE_OPEN_READONLY — never block writers
    }
) or do {
    print STDERR "PSK db connect failed: $DBI::errstr\n";
    print "Error: database unavailable.\n";
    exit;
};

# WAL mode allows us to read while the updater is writing
$dbh->do("PRAGMA journal_mode=WAL");

my $sth = $dbh->prepare($sql);
$sth->execute(@bind);

while (my @row = $sth->fetchrow_array) {
    printf "%d,%s,%s,%s,%s,%s,%d,%d\n", @row;
}

$sth->finish;
$dbh->disconnect;

exit;
