#!/usr/bin/env perl
# filter_amsat_active.pl
# Filters the Celestrak TLE file to satellites defined in the ALIAS map
# (i.e., those shown on HamClock's satellite map), and writes esats.txt
# with friendly AMSAT names.
#
# No longer fetches AMSAT status page — includes all mapped satellites
# regardless of reported activity.
#

use strict;
use warnings;

my $TLE_IN    = $ENV{ESATS_TLE_CACHE} // "/opt/hamclock-backend/tle/tles.txt";
my $TLE_OUT   = $ENV{ESATS_OUT}       // "/opt/hamclock-backend/htdocs/ham/HamClock/esats/esats.txt";

# AMSAT name => { tle => Celestrak name, out => friendly output name }
# Keys are uppercased. Only needed when AMSAT and Celestrak names differ.
# 'out' is what gets written to esats.txt.
# Entries with empty 'tle' are skipped (not in Celestrak feeds).
my %ALIAS = (
    'AO-10'             => { tle => 'PHASE 3B (AO-10)',       out => 'AO-10'   },
    'AO-123'            => { tle => 'ASRTU-1 (AO-123)',       out => 'AO-123'  },
    'AO-27'             => { tle => 'EYESAT A (AO-27)',       out => 'AO-27'   },
    'AO-73'             => { tle => 'FUNCUBE-1 (AO-73)',       out => 'AO-73'   },
    'AO-7'              => { tle => 'OSCAR 7 (AO-7)',          out => 'AO-7'    },
    'AO-7[A]'           => { tle => 'OSCAR 7 (AO-7)',          out => 'AO-7'    },
    'AO-7[B]'           => { tle => 'OSCAR 7 (AO-7)',          out => 'AO-7'    },
    'AO-85'             => { tle => 'FOX-1A (AO-85)',          out => 'AO-85'   },
    'AO-91'             => { tle => 'RADFXSAT (FOX-1B)',       out => 'AO-91'   },
    'AO-95'             => { tle => 'FOX-1CLIFF (AO-95)',      out => 'AO-95'   },
    'BOTAN APRS'        => { tle => 'BOTAN',                   out => 'BOTAN'   },
    'CATSAT'            => { tle => 'CATSAT',                  out => 'CATSAT'  },
    'ISS'               => { tle => 'ISS (ZARYA)',             out => 'ISS'     },
    'ISS-DATA'          => { tle => 'ISS (ZARYA)',             out => 'ISS'     },
    'ISS-FM'            => { tle => 'ISS (ZARYA)',             out => 'ISS'     },
    'ISS APRS'          => { tle => 'ISS (ZARYA)',             out => 'ISS'     },
    'ISS FM'            => { tle => 'ISS (ZARYA)',             out => 'ISS'     },
    'JO-97'             => { tle => 'JY1SAT (JO-97)',          out => 'JO-97'   },
    'QMR-KWT-2 (RS95S)' => { tle => 'QMR-KWT-2 (RS95S)',      out => 'RS95S'   },
    'QMR-KWT-2_(RS95S)' => { tle => 'QMR-KWT-2 (RS95S)',      out => 'RS95S'   },
    'QO-100 NB'         => { tle => '',                        out => ''        },
    'QO-100_NB'         => { tle => '',                        out => ''        },
    'RS-44'             => { tle => 'RS-44 & BREEZE-KM R/B',  out => 'RS-44'   },
    'RS95S'             => { tle => 'QMR-KWT-2 (RS95S)',       out => 'RS95S'   },
    'RS95S SSTV'        => { tle => 'QMR-KWT-2 (RS95S)',       out => 'RS95S'   },
    'RS18S SSTV'        => { tle => '',                        out => ''        },  # not in Celestrak feeds
    'SO-125'            => { tle => 'HADES-ICM',               out => 'SO-125'  },
    'SO-50'             => { tle => 'SAUDISAT 1C (SO-50)',     out => 'SO-50'   },
    'SONATE-2 APRS'     => { tle => 'SONATE-2',                out => 'SONATE-2'},
    'SONATE-2'          => { tle => 'SONATE-2',                out => 'SONATE-2'},
);

# Build lookup: uppercased Celestrak TLE name => friendly output name
# Skip entries with empty tle (not in Celestrak)
my %want;
for my $key (keys %ALIAS) {
    my $entry = $ALIAS{$key};
    next unless $entry->{tle} && $entry->{tle} ne '';
    $want{uc($entry->{tle})} = $entry->{out};
}

my $mapped = scalar keys %want;
print STDERR "Satellites in map (ALIAS entries with TLEs): $mapped\n";

# --- Read and filter TLE file, writing friendly names ---
open my $in, "<", $TLE_IN or die "Cannot open TLE file $TLE_IN: $!\n";
my @lines = <$in>;
close $in;
chomp @lines;

open my $out, ">", $TLE_OUT or die "Cannot write $TLE_OUT: $!\n";

my $i          = 0;
my $written    = 0;
my %seen_norad;

while ($i < @lines) {
    my $name = $lines[$i];
    $name =~ s/\r$//;
    $name =~ s/^\s+|\s+$//g;

    if ($name eq '' || $name =~ /^[12]\s/) { $i++; next; }

    my $l1 = $lines[$i+1] // '';
    my $l2 = $lines[$i+2] // '';
    $l1 =~ s/\r$//;
    $l2 =~ s/\r$//;

    if ($l1 =~ /^1\s/ && $l2 =~ /^2\s/) {
        my ($norad) = $l1 =~ /^1\s+(\d+)/;
        my $key = uc($name);
        $key =~ s/^\s+|\s+$//g;

        if (exists $want{$key} && !$seen_norad{$norad}) {
            my $out_name = $want{$key};
            print $out "$out_name\n$l1\n$l2\n";
            $seen_norad{$norad} = 1;
            $written++;
        }
        $i += 3;
    } else {
        $i++;
    }
}

close $out;
print STDERR "Wrote $written blocks to $TLE_OUT (from $mapped mapped TLE keys)\n";
