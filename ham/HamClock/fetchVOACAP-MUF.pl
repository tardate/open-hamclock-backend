#!/usr/bin/perl
#
# fetchVOACAPArea.pl - HamClock VOACAP DE/DX REL proxy to voacap-service
#
# Replaces the original VOACAP-calling implementation with a thin HTTP proxy
# that forwards all query parameters to the voacap-service container and
# streams the response back to HamClock unchanged.
#
# The voacap-service handles all VOACAP execution, concurrency, and output
# formatting. This script is a drop-in replacement — HamClock sees identical
# wire protocol output.
#
# Query parameters (all required, passed through verbatim):
# YEAR, MONTH, RXLAT, RXLNG, TXLAT, TXLNG, PATH, POW, MODE, TOA
# SSN (optional - if omitted, voacap-service uses ssn-31.txt or estimates)
#
# Configuration (environment variables):
# VOACAP_SERVICE_URL Base URL of the voacap-service
# Default: http://voacap-service:8080
#
# Author: Open HamClock Backend (OHB) project
# License: AGPLv3

use strict;
use warnings;
use LWP::UserAgent;

# —————————————————————————
# Configuration
# —————————————————————————

my $SERVICE_URL = $ENV{VOACAP_SERVICE_URL} || 'http://voacap-service:8080';
my $ENDPOINT = "$SERVICE_URL/fetchVOACAP-MUF.pl";
my $TIMEOUT = 300; 

# —————————————————————————
# Pass query string through verbatim
# —————————————————————————

my $qs = $ENV{QUERY_STRING} || $ARGV[0] || '';

my $ua = LWP::UserAgent->new(timeout => $TIMEOUT);
my $url = $qs ? "$ENDPOINT?$qs" : $ENDPOINT;
my $res = $ua->get($url);

if ($res->is_success) {
    binmode(STDOUT);

    # 1. Print the status first
    print "Status: " . $res->code . " " . $res->message . "\r\n";

    # 2. Get all headers as one big string block
    my $header_block = $res->headers->as_string("\r\n");

    # 3. HARDCODED FIX: 
    # Find the Title-Cased version Perl created and force the lowercase 'l'
    $header_block =~ s/X-2Z-Lengths/X-2Z-lengths/g;

    # 4. Filter out headers that might break the proxy/client connection
    foreach my $line (split(/\r\n/, $header_block)) {
        next if $line =~ /^(Transfer-Encoding|Connection|Content-Length|Client-)/i;
        print "$line\r\n";
    }

    # 5. End headers and print body
    print "\r\n";
    print $res->content;
} else {
    print "Status: " . $res->code . "\r\n";
    print "Content-Type: text/plain\r\n\r\n";
    print "Error: " . $res->status_line;
}

exit 0;

