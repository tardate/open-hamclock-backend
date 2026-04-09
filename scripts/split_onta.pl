#!/usr/bin/env perl
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
#  split_onta.pl
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
# split_onta.pl -- splits onta.txt into pota-activators.txt,
#                  sota-activators.txt, wwff-activators.txt

use strict;
use warnings;
use POSIX qw(strftime);
use File::Copy qw(move);
use File::Path qw(make_path);

my $ONTA   = '/opt/hamclock-backend/htdocs/ham/HamClock/ONTA/onta.txt';
my $OUTDIR = '/opt/hamclock-backend/htdocs/ham/HamClock';

my %files = (
    POTA => "$OUTDIR/POTA/pota-activators.txt",
    SOTA => "$OUTDIR/SOTA/sota-activators.txt",
    WWFF => "$OUTDIR/WWFF/wwff-activators.txt",
);

my %headers = (
    POTA => "#call,Hz,iso-utc,mode,grid,lat,lng,park-id\n",
    SOTA => "#call,Hz,iso-utc,mode,grid,lat,lng,summit-code\n",
    WWFF => "#call,Hz,iso-utc,mode,grid,lat,lng,wwff-ref\n",
);

my %rows = ( POTA => [], SOTA => [], WWFF => [] );

# Create output subdirs if they don't exist
for my $org (keys %files) {
    make_path("$OUTDIR/$org") unless -d "$OUTDIR/$org";
}

open my $in, '<', $ONTA or die "Cannot read $ONTA: $!\n";

while (<$in>) {
    next if /^#/;
    chomp;
    my ($call, $hz, $epoch, $mode, $grid, $lat, $lng, $park, $org) =
        split /,/, $_, 9;
    next unless defined $org && exists $rows{$org};

    my $iso = strftime('%Y-%m-%dT%H:%M:%S', gmtime($epoch));

    push @{ $rows{$org} },
        join(',', $call, $hz, $iso, $mode, $grid, $lat, $lng, $park) . "\n";
}

close $in;

for my $org (keys %files) {
    my $tmp = $files{$org} . '.tmp';
    open my $fh, '>', $tmp or die "Cannot write $tmp: $!\n";
    print $fh $headers{$org};
    print $fh $_ for @{ $rows{$org} };
    close $fh;
    move $tmp, $files{$org} or die "move failed: $tmp -> $files{$org}: $!\n";
    printf "%s: %d spots\n", $org, scalar @{ $rows{$org} };
}
