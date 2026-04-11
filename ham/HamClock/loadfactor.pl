#!/usr/bin/perl
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
#  loadfactor.pl
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
use strict;
use warnings;

# ---- CONFIGURE THIS ----
my $cores = 16;
# ------------------------

my $load = get_load_average();

printf "%.2f %d\n", $load, $cores;

sub get_load_average {
    if (-r '/proc/loadavg') {
        open my $fh, '<', '/proc/loadavg' or die "Cannot read /proc/loadavg: $!";
        my $line = <$fh>;
        close $fh;
        my ($one_min) = split /\s+/, $line;
        return $one_min + 0;
    }

    # macOS / BSD fallback
    my $out = `sysctl -n vm.loadavg 2>/dev/null`;
    if ($out =~ /\{\s*([\d.]+)/) {
        return $1 + 0;
    }

    # uptime fallback
    my $uptime = `uptime 2>/dev/null`;
    if ($uptime =~ /load averages?:\s*([\d.]+)/i) {
        return $1 + 0;
    }

    die "Cannot determine load average\n";
}
